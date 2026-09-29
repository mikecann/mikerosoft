import AppKit
import AVFoundation
import CoreImage
import VideoToolbox
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Proxies and mattes from a project's own analysis cache, read only.
final class CacheAssets: RenderAssets, @unchecked Sendable {
    var proxies: [String: URL] = [:]
    var mattes: [String: URL] = [:]

    init(project: Project, cache: URL) {
        let bySource = Dictionary(project.media.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        for kind in ["proxy", "matte"] {
            let folder = cache.appendingPathComponent(kind)
            var newest: [String: Int] = [:]
            for entry in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                guard let data = try? Data(contentsOf: entry.appendingPathComponent("entry.json")),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let source = json["source"] as? String, let id = bySource[source],
                      let file = (json["files"] as? [String])?.first else { continue }
                let version = json["algorithmVersion"] as? Int ?? 0
                guard version >= newest[id] ?? 0 else { continue }
                newest[id] = version
                if kind == "proxy" { proxies[id] = entry.appendingPathComponent(file) } else { mattes[id] = entry.appendingPathComponent(file) }
            }
        }
    }

    func proxyURL(for item: MediaItem) -> URL? { proxies[item.id] }
    func matteURL(for item: MediaItem) -> URL? { mattes[item.id] }
    func isolatedVoiceURL(for item: MediaItem) -> URL? { nil }
    func loudness(for item: MediaItem) -> Loudness? { nil }
}

/// Levels on Mike's demo project, read only: the player on proxies and on
/// originals, paused stills, export and the camera file itself. Opt in with
/// TANDEM_REAL_MEDIA=1 (release, -enable-testing).
final class RealColourTests: XCTestCase {
    let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/tandem-render/colour")
    let demo = URL(fileURLWithPath: NSString(string: "~/dev/me/tandem-research/demo/decision-models-v14/decision-models-v14.tandem").expandingTildeInPath)

    /// What the viewer's player shows at `seconds`: the compositor's own
    /// buffers, as the app's `AVPlayerItemVideoOutput` gets them.
    func playerFrame(_ context: RenderContext, at seconds: Double) async throws -> CVPixelBuffer {
        let built = try await CompositionBuilder.build(context)
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if output.hasNewPixelBuffer(forItemTime: target), let pixels = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) {
                return pixels
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("the player showed nothing at \(seconds)")
    }

    /// A media file's own decoded frame at `seconds`, in its native format.
    func originalFrame(_ url: URL, at seconds: Double, format: OSType? = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: format.map { [kCVPixelBufferPixelFormatTypeKey as String: $0] } ?? [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(output)
        reader.startReading()
        guard let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("no frame in \(url.lastPathComponent) at \(seconds)")
        }
        reader.cancelReading()
        return pixels
    }

    func testMeasureDemoPaths() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_REAL_MEDIA"] == "1", "set TANDEM_REAL_MEDIA=1 to run")
        guard FileManager.default.fileExists(atPath: demo.path) else { throw XCTSkip("no demo project") }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let (project, _) = try ProjectFile.load(from: demo)
        let folder = ProjectFolder(projectFile: demo)
        let assets = CacheAssets(project: project, cache: demo.deletingLastPathComponent().appendingPathComponent(".tandem/cache"))
        print("COLOUR proxies \(assets.proxies.count), mattes \(assets.mattes.count)")
        var bare = project
        for i in bare.media.indices { bare.media[i].look = [] }

        let camera = project.media.first { $0.path.hasSuffix("2026-09-24_105434-camera.mov") }!
        for (label, p) in [("with looks", project), ("no looks", bare)] {
            for seconds in [35.0, 52.0] {
                let proxied = RenderContext(project: p, folder: folder, useProxies: true, assets: assets)
                let originals = RenderContext(project: p, folder: folder, useProxies: false, assets: assets)
                let playerProxy = try await playerFrame(proxied, at: seconds)
                let playerOriginal = try await playerFrame(originals, at: seconds)
                let still = try await FrameRenderer(context: originals).image(at: Time(seconds: seconds))
                let a = Levels(playerProxy), b = Levels(playerOriginal), c = Levels(still)
                print("COLOUR \(label) \(seconds) player/proxy    \(Levels.describe(playerProxy))\n       \(a.summary)")
                print("COLOUR \(label) \(seconds) player/original \(Levels.describe(playerOriginal))\n       \(b.summary)")
                print("COLOUR \(label) \(seconds) still           \(still.width)x\(still.height) bpc \(still.bitsPerComponent) space \(still.colorSpace?.name as String? ?? "-")\n       \(c.summary)")
                let ab = a.difference(c), bc = b.difference(c)
                print(String(format: "COLOUR \(label) \(seconds) player/proxy - still: mean %.2f luma %+.2f; player/original - still: mean %.2f luma %+.2f", ab.mean, ab.luma, bc.mean, bc.luma))
            }
        }
        let originals = RenderContext(project: project, folder: folder, useProxies: false, assets: assets)
        // The export path: one second from 35 s, decoded again.
        let exported = scratch.appendingPathComponent("demo-35s.mp4")
        try? FileManager.default.removeItem(at: exported)
        let preset = ExportPreset(name: "range", codec: .hevc, videoBitrate: 80_000_000, range: TimeRange(start: Time(seconds: 35), duration: Time(seconds: 1)))
        _ = try await ExportPipeline(context: originals, preset: preset, output: exported, progress: { _ in }).run()
        let exportFrame = try await originalFrame(exported, at: 0, format: nil)
        let exportStill = try await FrameRenderer(context: originals).image(at: Time(seconds: 35))
        let e = Levels(exportFrame), st = Levels(exportStill)
        let ed = e.difference(st)
        let space = (CVBufferCopyAttachment(exportFrame, kCVImageBufferCGColorSpaceKey, nil) as! CGColorSpace?).map { "\($0)" } ?? "none"
        print("COLOUR export 35.0 \(Levels.describe(exportFrame)) attached \(space)\n       \(e.summary)")
        print(String(format: "COLOUR export - still: mean %.2f luma %+.2f", ed.mean, ed.luma))
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1508, height: 848), CGSize(width: 3840, height: 2160)] {
            let still = try await FrameRenderer(context: originals).image(at: Time(seconds: 35), maxSize: size)
            print("COLOUR still maxSize \(size): \(still.width)x\(still.height) bpc \(still.bitsPerComponent) info \(still.bitmapInfo.rawValue) space \(still.colorSpace?.name as String? ?? "\(String(describing: still.colorSpace))")\n       \(Levels(still).summary)")
        }
        // The camera file itself at 35 s on the timeline (source 151.65 s).
        let original = try await originalFrame(URL(fileURLWithPath: camera.path), at: 151.65)
        print("COLOUR camera original \(Levels.describe(original))\n       \(Levels(original).summary)")
        // Skin, where a matrix mix-up shows (the face at 35 s), without the
        // camera's look: the file, the still now, and the still with the
        // composition tagged BT.709 as it used to be.
        let plain = RenderContext(project: bare, folder: folder, useProxies: false, assets: assets)
        let built = try await CompositionBuilder.build(plain)
        let old = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
        old.customVideoCompositorClass = TandemRGBCompositor.self
        old.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        old.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        old.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = old
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let before = Levels(try await generator.image(at: CMTime(seconds: 35, preferredTimescale: 600)).image)
        let now = Levels(try await FrameRenderer(context: plain).image(at: Time(seconds: 35)))
        let face = (0.40, 0.30, 0.50, 0.48)
        for (name, levels) in [("camera file", Levels(original)), ("still now", now), ("still before", before)] {
            let m = levels.mean(face.0, face.1, face.2, face.3)
            print(String(format: "COLOUR face %@: %.1f/%.1f/%.1f", name, m[0], m[1], m[2]))
        }
        if let proxy = assets.proxies[camera.id] {
            let frame = try await originalFrame(proxy, at: 151.65)
            print("COLOUR camera proxy    \(Levels.describe(frame))\n       \(Levels(frame).summary)")
        }
    }
}


/// The viewer's two layers side by side in a real window, captured from the
/// screen: the proxy player on the left, the paused still on the right.
/// Opt in with TANDEM_REAL_MEDIA=1 and TANDEM_SCREEN=1 (it shows a window).
final class ColourOnScreenTests: XCTestCase {
    let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/tandem-render/colour")
    let demo = URL(fileURLWithPath: NSString(string: "~/dev/me/tandem-research/demo/decision-models-v14/decision-models-v14.tandem").expandingTildeInPath)

    func capture(_ windowNumber: Int, _ name: String) -> CGImage? {
        let png = scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: png)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(windowNumber)", png.path]
        try? task.run()
        task.waitUntilExit()
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Luma of 8x8 blocks of the left and right halves, and their mean
    /// signed difference (left minus right) with the mean absolute one.
    func halves(_ image: CGImage) -> (signed: Double, absolute: Double, left: Double, right: Double) {
        let bitmap = Bitmap(image)
        let half = bitmap.width / 2
        let top = bitmap.height - half * 9 / 16
        var signed = 0.0, absolute = 0.0, left = 0.0, right = 0.0, n = 0.0
        for by in stride(from: top + 8, to: bitmap.height - 8, by: 8) {
            for bx in stride(from: 8, to: half - 8, by: 8) {
                var a = 0.0, b = 0.0
                for y in by..<(by + 8) { for x in bx..<(bx + 8) { a += bitmap.luma(x, y); b += bitmap.luma(x + half, y) } }
                a /= 64; b /= 64
                signed += a - b; absolute += abs(a - b); left += a; right += b; n += 1
            }
        }
        return (signed / n, absolute / n, left / n, right / n)
    }

    /// The window and what's in it, touched only on the main actor.
    final class Stage: @unchecked Sendable {
        var window: NSWindow!
        var player: AVPlayer!
        var playerLayer: AVPlayerLayer!
        var players: [AVPlayer] = []
        var layers: [AVPlayerLayer] = []
    }

    static let patches: [(Double, Double, Double)] = [
        (0, 0, 0), (16, 16, 16), (32, 32, 32), (64, 64, 64), (96, 96, 96), (128, 128, 128),
        (160, 160, 160), (192, 192, 192), (224, 224, 224), (255, 255, 255), (200, 150, 120), (40, 90, 160)
    ]

    /// A project showing an image of vertical colour patches for 5 s.
    func patchProject(width: Int, height: Int) throws -> (Project, ProjectFolder) {
        let folder = scratch.appendingPathComponent("patch-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("patches.png")
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let patches = Self.patches
        for (i, p) in patches.enumerated() {
            context.setFillColor(red: p.0 / 255, green: p.1 / 255, blue: p.2 / 255, alpha: 1)
            context.fill(CGRect(x: i * width / patches.count, y: 0, width: width / patches.count + 1, height: height))
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let image = MediaItem(id: "med_patches", path: url.path, kind: .image, role: .image, width: width, height: height, hasVideo: false)
        let clip = Clip(id: "clip_patches", content: .media(mediaID: "med_patches"), start: .zero, duration: Time(seconds: 5))
        let project = Project(name: "Patches", settings: ProjectSettings(width: width, height: height, frameRate: .fps25),
                              media: [image], videoTracks: [Track(kind: .video, name: "V1", clips: [clip])], audioTracks: [])
        return (project, ProjectFolder(root: folder))
    }

    /// Patch values as captured: the player (left) and still (right) halves
    /// of each row, rows top first.
    func testPatchesOnScreen() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_SCREEN"] == "1", "set TANDEM_SCREEN=1")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let (project, folder) = try patchProject(width: 3840, height: 2160)
        let full = RenderContext(project: project, folder: folder)
        var small = full
        small.sizeOverride = CGSize(width: 960, height: 540)
        let rows = [("4K player", full), ("960 player", small)]
        var made: [BuiltComposition] = []
        for (_, context) in rows { made.append(try await CompositionBuilder.build(context)) }
        let builts = made
        let still = try await FrameRenderer(context: full).image(at: Time(seconds: 1), maxSize: CGSize(width: 960, height: 540))
        let stage = Stage()
        await MainActor.run {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 960, height: 270 * rows.count), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Tandem patch check"
            let view = NSView(frame: window.contentView!.bounds)
            view.wantsLayer = true
            window.contentView = view
            for (index, built) in builts.enumerated() {
                let y = CGFloat((rows.count - 1 - index) * 270)
                let player = AVPlayer(playerItem: built.makePlayerItem())
                player.isMuted = true
                let layer = AVPlayerLayer(player: player)
                layer.frame = CGRect(x: 0, y: y, width: 480, height: 270)
                layer.videoGravity = .resizeAspect
                view.layer!.addSublayer(layer)
                let stillLayer = CALayer()
                stillLayer.frame = CGRect(x: 480, y: y, width: 480, height: 270)
                stillLayer.contentsGravity = .resizeAspect
                stillLayer.contents = still
                view.layer!.addSublayer(stillLayer)
                stage.layers.append(layer)
                stage.players.append(player)
            }
            window.orderFrontRegardless()
            stage.window = window
        }
        for player in stage.players { await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        for _ in 0..<100 {
            if await MainActor.run(body: { stage.layers.allSatisfy(\.isReadyForDisplay) }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        let number = await MainActor.run { stage.window.windowNumber }
        guard let shot = capture(number, "screen-patches.png") else { throw XCTSkip("no capture") }
        let bitmap = Bitmap(shot)
        let scale = Double(bitmap.width) / 960
        var report = ["SCREEN patches (capture \(shot.colorSpace?.name as String? ?? "-"))"]
        for (index, (name, _)) in rows.enumerated() {
            let rowTop = Double(bitmap.height) - Double((rows.count - index) * 270) * scale
            let y = Int(rowTop + 135 * scale)
            for (side, offset) in [(name, 0.0), ("still", 480.0)] {
                var line = side.padding(toLength: 12, withPad: " ", startingAt: 0)
                for p in 0..<Self.patches.count {
                    let x = Int((offset + (Double(p) + 0.5) * 480 / Double(Self.patches.count)) * scale)
                    let v = bitmap[x, y]
                    line += String(format: " %3d/%3d/%3d", v[0], v[1], v[2])
                }
                report.append(line)
            }
        }
        await MainActor.run { stage.window.orderOut(nil) }
        print(report.joined(separator: "\n"))
    }

    func testPlayerAndStillOnScreen() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_REAL_MEDIA"] == "1" && ProcessInfo.processInfo.environment["TANDEM_SCREEN"] == "1", "set TANDEM_REAL_MEDIA=1 TANDEM_SCREEN=1")
        guard FileManager.default.fileExists(atPath: demo.path) else { throw XCTSkip("no demo project") }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let seconds = Double(ProcessInfo.processInfo.environment["TANDEM_AT"] ?? "35") ?? 35
        let (project, _) = try ProjectFile.load(from: demo)
        let folder = ProjectFolder(projectFile: demo)
        let assets = CacheAssets(project: project, cache: demo.deletingLastPathComponent().appendingPathComponent(".tandem/cache"))
        let proxied = RenderContext(project: project, folder: folder, useProxies: true, assets: assets)
        let originals = RenderContext(project: project, folder: folder, useProxies: false, assets: assets)
        let built = try await CompositionBuilder.build(proxied)
        let still = try await FrameRenderer(context: originals).image(at: Time(seconds: seconds), maxSize: CGSize(width: 960, height: 540))

        let stage = Stage()
        await MainActor.run {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 960, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Tandem colour check"
            let view = NSView(frame: window.contentView!.bounds)
            view.wantsLayer = true
            window.contentView = view
            let player = AVPlayer(playerItem: built.makePlayerItem())
            player.isMuted = true
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
            playerLayer.videoGravity = .resizeAspect
            view.layer!.addSublayer(playerLayer)
            let stillLayer = CALayer()
            stillLayer.frame = CGRect(x: 480, y: 0, width: 480, height: 270)
            stillLayer.contentsGravity = .resizeAspect
            stillLayer.contents = still
            view.layer!.addSublayer(stillLayer)
            window.orderFrontRegardless()
            stage.window = window
            stage.player = player
            stage.playerLayer = playerLayer
        }
        await stage.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        for _ in 0..<150 {
            if await MainActor.run(body: { stage.playerLayer.isReadyForDisplay }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let number = await MainActor.run { stage.window.windowNumber }
        var lines: [String] = []
        let ready = await MainActor.run { stage.playerLayer.isReadyForDisplay }
        lines.append("ready \(ready) status \(stage.player.currentItem!.status.rawValue) time \(stage.player.currentTime().seconds)")
        if let paused = capture(number, "screen-paused.png") {
            let h = halves(paused)
            lines.append(String(format: "paused:  player %.2f still %.2f  player - still %+.2f (abs %.2f)", h.left, h.right, h.signed, h.absolute))
        }
        await MainActor.run { stage.player.play() }
        try await Task.sleep(nanoseconds: 600_000_000)
        if let playing = capture(number, "screen-playing.png") {
            let h = halves(playing)
            lines.append(String(format: "playing: player %.2f still %.2f  player - still %+.2f (abs %.2f)", h.left, h.right, h.signed, h.absolute))
        }
        await MainActor.run {
            stage.player.pause()
            stage.window.orderOut(nil)
        }
        print("SCREEN at \(seconds) s\n" + lines.joined(separator: "\n"))
    }
}


/// How much a still part of the camera shot flickers from frame to frame:
/// the original, the proxy the app plays, and the same frames encoded as
/// proxies at other qualities. Opt in with TANDEM_REAL_MEDIA=1.
final class ProxyNoiseTests: XCTestCase {
    let demo = URL(fileURLWithPath: NSString(string: "~/dev/me/tandem-research/demo/decision-models-v14/decision-models-v14.tandem").expandingTildeInPath)

    func frames(_ url: URL, from seconds: Double, count: Int, scaleTo size: CGSize? = nil) async throws -> (frames: [CVPixelBuffer], fps: Float) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let fps = try await track.load(.nominalFrameRate)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(seconds: 10, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        reader.add(output)
        reader.startReading()
        var transfer: VTPixelTransferSession?
        if size != nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        var result: [CVPixelBuffer] = []
        while result.count < count, let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            if let size, let transfer {
                var scaled: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                    [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()] as CFDictionary, &scaled)
                CVBufferPropagateAttachments(pixels, scaled!)
                VTPixelTransferSessionTransferImage(transfer, from: pixels, to: scaled!)
                result.append(scaled!)
            } else {
                result.append(pixels)
            }
        }
        reader.cancelReading()
        return (result, fps)
    }

    /// Encodes the frames the way `ProxyJob` does (hardware HEVC, speed
    /// over quality, every frame a keyframe unless asked otherwise) and
    /// decodes them again.
    func proxyRoundTrip(_ frames: [CVPixelBuffer], quality: Double, fps: Float, keyFrameInterval: Int = 1) throws -> (frames: [CVPixelBuffer], bytes: Int) {
        let width = CVPixelBufferGetWidth(frames[0]), height = CVPixelBufferGetHeight(frames[0])
        var session: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                                   encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        let encoder = try XCTUnwrap(session)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        final class Box: @unchecked Sendable { var samples: [CMSampleBuffer] = []; var decoded: [CVPixelBuffer] = [] }
        let box = Box()
        let lock = NSLock()
        for (i, frame) in frames.enumerated() {
            VTCompressionSessionEncodeFrame(encoder, imageBuffer: frame, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps.rounded())),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
                if let sample { lock.withLock { box.samples.append(sample) } }
            }
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(encoder)
        let samples = lock.withLock { box.samples }
        let bytes = samples.reduce(0) { $0 + CMSampleBufferGetTotalSampleSize($1) }
        var decoderOut: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: nil, formatDescription: CMSampleBufferGetFormatDescription(samples[0])!, decoderSpecification: nil,
                                     imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary,
                                     outputCallback: nil, decompressionSessionOut: &decoderOut)
        let decoder = try XCTUnwrap(decoderOut)
        for sample in samples {
            VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, image, _, _ in
                if let image { lock.withLock { box.decoded.append(image) } }
            }
            VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        }
        VTDecompressionSessionInvalidate(decoder)
        return (lock.withLock { box.decoded }, bytes)
    }

    /// Mean temporal standard deviation of luma in a region given as
    /// fractions (x0, y0, x1, y1), per pixel and per 8x8 block mean, with
    /// the region's mean luma.
    func noise(_ frames: [CVPixelBuffer], region: (Double, Double, Double, Double)) -> (pixel: Double, block: Double, mean: Double) {
        let width = CVPixelBufferGetWidth(frames[0]), height = CVPixelBufferGetHeight(frames[0])
        let x0 = Int(region.0 * Double(width)) / 8 * 8, x1 = Int(region.2 * Double(width)) / 8 * 8
        let y0 = Int(region.1 * Double(height)) / 8 * 8, y1 = Int(region.3 * Double(height)) / 8 * 8
        let w = x1 - x0, h = y1 - y0
        var sum = [Double](repeating: 0, count: w * h), sum2 = sum
        let bw = w / 8, bh = h / 8
        var bsum = [Double](repeating: 0, count: bw * bh), bsum2 = bsum
        for frame in frames {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
            var blocks = [Double](repeating: 0, count: bw * bh)
            for y in 0..<h {
                for x in 0..<w {
                    let v = Double(base[(y0 + y) * row + x0 + x])
                    sum[y * w + x] += v
                    sum2[y * w + x] += v * v
                    blocks[(y / 8) * bw + x / 8] += v / 64
                }
            }
            for i in 0..<blocks.count { bsum[i] += blocks[i]; bsum2[i] += blocks[i] * blocks[i] }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        let n = Double(frames.count)
        func sd(_ s: Double, _ s2: Double) -> Double { (max(0, s2 / n - (s / n) * (s / n))).squareRoot() }
        let pixel = (0..<(w * h)).reduce(0.0) { $0 + sd(sum[$1], sum2[$1]) } / Double(w * h)
        let block = (0..<(bw * bh)).reduce(0.0) { $0 + sd(bsum[$1], bsum2[$1]) } / Double(bw * bh)
        let mean = sum.reduce(0, +) / n / Double(w * h)
        return (pixel, block, mean)
    }

    /// A picture of the flicker: for each version, a crop of one frame and
    /// the change to the next frame, amplified 16 times.
    func flickerSheet(_ versions: [(String, [CVPixelBuffer])], crop: CGRect, to url: URL) {
        let w = Int(crop.width), h = Int(crop.height)
        let context = CGContext(data: nil, width: w * 2, height: h * versions.count, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let out = context.data!.assumingMemoryBound(to: UInt8.self)
        let outRow = context.bytesPerRow
        for (index, (_, frames)) in versions.enumerated() {
            let a = frames[10], b = frames[11]
            CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
            let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
            let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
            let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
            for y in 0..<h {
                for x in 0..<w {
                    let sx = Int(crop.minX) + x, sy = Int(crop.minY) + y
                    let va = Int(pa[sy * ra + sx]), vb = Int(pb[sy * rb + sx])
                    let row = (index * h + y) * outRow
                    out[row + x] = UInt8(va)
                    out[row + w + x] = UInt8(max(0, min(255, 128 + (vb - va) * 16)))
                }
            }
            CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }

    /// TANDEM_MEDIA picks the file by name ending (the camera by default,
    /// or main-screen.mov) and TANDEM_AT the source time.
    func testProxyFlicker() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_REAL_MEDIA"] == "1", "set TANDEM_REAL_MEDIA=1 to run")
        guard FileManager.default.fileExists(atPath: demo.path) else { throw XCTSkip("no demo project") }
        let (project, _) = try ProjectFile.load(from: demo)
        let assets = CacheAssets(project: project, cache: demo.deletingLastPathComponent().appendingPathComponent(".tandem/cache"))
        let suffix = ProcessInfo.processInfo.environment["TANDEM_MEDIA"] ?? "2026-09-24_105434-camera.mov"
        let item = try XCTUnwrap(project.media.first { $0.path.hasSuffix(suffix) })
        let start = Double(ProcessInfo.processInfo.environment["TANDEM_AT"] ?? "150") ?? 150
        let count = 30
        let isCamera = suffix.hasSuffix("camera.mov")
        let regions: [(String, (Double, Double, Double, Double))] = isCamera
            ? [("wall", (0.0, 0.05, 0.12, 0.5)), ("couch", (0.0, 0.53, 0.12, 0.66))]
            : [("top half", (0.0, 0.0, 1.0, 0.5)), ("bottom left", (0.0, 0.5, 0.5, 1.0))]
        let (original, fps) = try await frames(URL(fileURLWithPath: item.path), from: start, count: count, scaleTo: CGSize(width: 1920, height: 1080))
        var lines = ["NOISE \(suffix) at \(start) s, \(count) frames, 1080p: temporal sd of luma per pixel / per 8x8 block"]
        func line(_ name: String, _ frames: [CVPixelBuffer], _ extra: String = "") {
            var text = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            for (label, region) in regions {
                let n = noise(frames, region: region)
                text += String(format: "  %@ %.2f / %.2f", label, n.pixel, n.block)
            }
            lines.append(text + extra)
        }
        line("original", original)
        var sheet: [(String, [CVPixelBuffer])] = [("original", original)]
        if let proxy = assets.proxies[item.id] {
            line("proxy on disk", try await frames(proxy, from: start, count: count).frames)
        }
        // Encoded as ProxyJob does, at other qualities, and with P-frames
        // (a keyframe every 15) for comparison: much cleaner and smaller,
        // but proxies stay all-intra for scrubbing and playing backwards.
        for (quality, keyFrameInterval) in [(0.45, 1), (0.55, 1), (0.6, 1), (0.65, 1), (0.75, 1), (0.55, 15)] {
            let trip = try proxyRoundTrip(original, quality: quality, fps: fps, keyFrameInterval: keyFrameInterval)
            let perMinute = Double(trip.bytes) / Double(count) * Double(fps) * 60 / 1_000_000
            let name = keyFrameInterval == 1 ? String(format: "proxy q %.2f", quality) : String(format: "q %.2f gop %d", quality, keyFrameInterval)
            line(name, trip.frames, String(format: "  %.0f MB/min", perMinute))
            if keyFrameInterval == 1, quality < 0.7 { sheet.append((name, trip.frames)) }
        }
        // The compositor's own output on both paths: it adds no flicker.
        if isCamera, let clip = project.videoTracks.flatMap(\.clips).first(where: {
            $0.mediaID == item.id && $0.sourceStart.seconds <= start && $0.sourceStart.seconds + $0.duration.seconds > start + 1.2 && $0.video?.cutout == nil
        }) {
            let at = clip.start.seconds + (start - clip.sourceStart.seconds)
            for proxies in [false, true] {
                var context = RenderContext(project: project, folder: ProjectFolder(projectFile: demo), useProxies: proxies, assets: assets)
                context.sizeOverride = CGSize(width: 1920, height: 1080)
                let built = try await CompositionBuilder.build(context)
                let reader = try AVAssetReader(asset: built.composition)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: at, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600))
                let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: nil)
                output.videoComposition = built.videoComposition
                reader.add(output)
                reader.startReading()
                var composed: [CVPixelBuffer] = []
                while composed.count < count, let sample = output.copyNextSampleBuffer() {
                    if let pixels = CMSampleBufferGetImageBuffer(sample) { composed.append(pixels) }
                }
                reader.cancelReading()
                line(proxies ? "composed proxy" : "composed orig", composed, "  (video range, with the look)")
            }
        }
        let crop = isCamera ? CGRect(x: 0, y: 300, width: 400, height: 420) : CGRect(x: 100, y: 60, width: 640, height: 300)
        flickerSheet(sheet, crop: crop, to: URL(fileURLWithPath: "/private/tmp/claude-501/tandem-render/colour/flicker-\(isCamera ? "camera" : "screen").png"))
        print(lines.joined(separator: "\n"))
    }
}
