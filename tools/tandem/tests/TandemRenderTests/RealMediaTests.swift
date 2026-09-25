import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Speed and look on Mike's real footage. Opt in with TANDEM_REAL_MEDIA=1,
/// ideally in release:
///
///     TANDEM_REAL_MEDIA=1 swift test -c release -Xswiftc -enable-testing \
///         --package-path tools/tandem --filter RealMediaTests
///
/// Reads ~/dev/convex/convex-videos/decision-models (never writes there) and
/// writes to /private/tmp/claude-501/tandem-render/bench.
final class RealMediaTests: XCTestCase {
    let footage = URL(fileURLWithPath: NSString(string: "~/dev/convex/convex-videos/decision-models").expandingTildeInPath)
    let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/tandem-render/bench")
    /// The spike's person matte covers 60 s of the camera from 1010 s.
    let spikeMatte = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-m5-mike/705e866f-2066-4049-984f-df768d5792c5/scratchpad/spikes/04-segmentation/out/matte_accurate_hevc.mov")
    let start = 1010.0

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_REAL_MEDIA"] == "1", "set TANDEM_REAL_MEDIA=1 to run")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    /// The spike matte starts at 0; the renderer wants mattes in the
    /// camera's media time, so wrap it in a movie that starts at 1010 s.
    func retimedMatte() async throws -> URL? {
        guard FileManager.default.fileExists(atPath: spikeMatte.path) else { return nil }
        let url = scratch.appendingPathComponent("matte-from-1010.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let asset = AVURLAsset(url: spikeMatte)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let composition = AVMutableComposition()
        let out = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try out.insertTimeRange(try await track.load(.timeRange), of: track, at: CMTime(seconds: start, preferredTimescale: 600))
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: url, as: .mov)
        return url
    }

    /// Screen on V1 with the camera as a 50% cutout PiP with Mike's grade
    /// and shadow, his voice from the camera, and a music bed.
    func decisionModelsMinute(seconds: Double = 60) -> Project {
        let edit = footage.appendingPathComponent("edit")
        let screen = MediaItem(id: "med_screen", path: edit.appendingPathComponent("main-screen.mov").path, kind: .video, role: .screen,
                               duration: Time(seconds: 1446), width: 3200, height: 1800, hasVideo: true, hasAudio: true, variableFrameRate: true)
        var camera = MediaItem(id: "med_camera", path: edit.appendingPathComponent("main-camera.mov").path, kind: .video, role: .camera,
                               duration: Time(seconds: 1446), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true)
        camera.look = [
            Effect(type: "colorAdjust", params: ["contrast": .number(30), "blackLevel": .number(-7)]),
            Effect(type: "hsl", params: ["redSaturation": .number(-8)]),
            Effect(type: "vignette", params: ["amount": .number(-30)]),
            Effect(type: "sharpen", params: ["amount": .number(3)])
        ]
        let music = MediaItem(id: "med_music", path: footage.appendingPathComponent("music/c1a.mp3").path, kind: .audio, role: .music,
                              duration: Time(seconds: 120), hasAudio: true)
        let length = Time(seconds: seconds)
        let pip = VideoProperties(
            transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5),
            cutout: Cutout(),
            effects: [Effect(type: "dropShadow")]
        )
        let screenClip = Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: .zero, duration: length, sourceStart: Time(seconds: start), linkGroup: "lnk_take")
        let cameraClip = Clip(id: "clip_camera", content: .media(mediaID: "med_camera"), start: .zero, duration: length, sourceStart: Time(seconds: start), linkGroup: "lnk_take", video: pip)
        let voice = Clip(id: "clip_voice", content: .media(mediaID: "med_camera"), start: .zero, duration: length, sourceStart: Time(seconds: start), linkGroup: "lnk_take")
        var bed = Clip(id: "clip_music", content: .media(mediaID: "med_music"), start: .zero, duration: length)
        bed.audio = AudioProperties(gainDB: -31, fadeOut: Time(seconds: 2))
        return Project(
            name: "Decision Models minute",
            settings: ProjectSettings(width: 3840, height: 2160, frameRate: .fps30),
            media: [screen, camera, music],
            videoTracks: [
                Track(kind: .video, name: "Screen", clips: [screenClip]),
                Track(kind: .video, name: "Camera", clips: [cameraClip])
            ],
            audioTracks: [
                Track(kind: .audio, name: "Voice", clips: [voice]),
                Track(kind: .audio, name: "Music", clips: [bed])
            ]
        )
    }

    func context(_ project: Project) async throws -> RenderContext {
        let assets = FakeAssets()
        if let matte = try await retimedMatte() { assets.mattes["med_camera"] = matte }
        return RenderContext(project: project, folder: ProjectFolder(root: footage), assets: assets)
    }

    // MARK: The imported v14 edit against Filmora's export

    let v14Project = URL(fileURLWithPath: NSString(string: "~/dev/me/tandem-research/imports/decision-models-v14/decision-models-v14.tandem").expandingTildeInPath)

    func v14() throws -> RenderContext {
        guard FileManager.default.fileExists(atPath: v14Project.path) else { throw XCTSkip("no imported v14 project") }
        // Read only: ProjectFile.load writes nothing.
        let (project, _) = try ProjectFile.load(from: v14Project)
        return RenderContext(project: project, folder: ProjectFolder(projectFile: v14Project))
    }

    /// Frames from Tandem and from Filmora's v14 export at the same times,
    /// saved side by side, with the mean difference per pixel.
    func testDecisionModelsV14AgainstFilmora() async throws {
        let context = try v14()
        let reference = footage.appendingPathComponent("Decision Models v14.mp4")
        let renderer = FrameRenderer(context: context)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: reference))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let size = CGSize(width: 960, height: 540)
        generator.maximumSize = size
        var report: [String] = []
        for seconds in [10.0, 36.0, 52.0, 120.0, 245.0, 330.0, 460.0, 610.0, 660.0] {
            let started = Date()
            let ours = try await renderer.image(at: Time(seconds: seconds), maxSize: size)
            let elapsed = Date().timeIntervalSince(started)
            let theirs = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let a = Bitmap(ours), b = Bitmap(theirs)
            var total = 0.0
            var count = 0
            for y in stride(from: 0, to: min(a.height, b.height), by: 2) {
                for x in stride(from: 0, to: min(a.width, b.width), by: 2) {
                    let p = a[x, y], q = b[x, y]
                    total += Double(abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2])) / 3
                    count += 1
                }
            }
            let difference = total / Double(max(count, 1))
            report.append(String(format: "%6.1f s  mean difference %5.1f / 255  (grab %.2f s)", seconds, difference, elapsed))
            try sideBySide(ours, theirs, name: String(format: "v14-%04.0f.png", seconds))
        }
        let warnings = try await renderer.warnings()
        print("REAL v14 vs Filmora:\n" + report.joined(separator: "\n") + "\nwarnings: \(warnings.prefix(8))")
    }

    /// Share of the screen area (the PiP corner left out, since Filmora's
    /// has a cutout) where 4x4 block averages differ by more than 30 levels:
    /// resampling and compression stay near 0, a black or stale frame
    /// differs over much of the screen.
    func blockDifference(_ ours: Bitmap, _ theirs: Bitmap) -> Double {
        var differing = 0, count = 0
        for by in stride(from: 0, to: 268, by: 4) {
            for bx in stride(from: 0, to: 480, by: 4) where !(bx > 280 && by > 140) {
                var a = 0.0, b = 0.0
                for y in by..<(by + 4) { for x in bx..<(bx + 4) { a += ours.luma(x, y); b += theirs.luma(x, y) } }
                count += 1
                if abs(a - b) / 16 > 30 { differing += 1 }
            }
        }
        return Double(differing) / Double(count) * 100
    }

    /// Frames AVFoundation couldn't seek to in the remuxed screen recording
    /// (open-GOP leading frames, long variable frame rate gaps, cuts that
    /// start on leading frames) against Filmora's export: grabbed the way
    /// `tandem frame` does, and range exports starting on them (which used
    /// to stall).
    func testV14HardFramesMatchFilmora() async throws {
        let context = try v14()
        let reference = footage.appendingPathComponent("Decision Models v14.mp4")
        let renderer = FrameRenderer(context: context)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: reference))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let size = CGSize(width: 480, height: 270)
        generator.maximumSize = size
        // Times on the 25 fps frame grid, so both sides show the same frame.
        let leading = [51.52, 88.08, 113.88, 154.68, 194.12, 288.44, 316.56, 356.64, 404.0, 405.24, 432.4]
        // In static stretches of 4 to 11 s with no frames.
        let gaps = [90.6, 104.04, 105.92, 165.56, 430.84]
        // First frames of the nine clips that start on leading frames.
        let cuts = [115.6, 303.76, 352.44, 369.96, 414.12, 420.12, 451.56, 465.44, 526.04]
        var worst = 0.0
        for (kind, times) in [("leading", leading), ("gap", gaps), ("cut", cuts)] {
            for seconds in times {
                let started = Date()
                let ours = Bitmap(try await renderer.image(at: Time(seconds: seconds), maxSize: size))
                let elapsed = Date().timeIntervalSince(started)
                let theirs = Bitmap(try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image)
                let share = blockDifference(ours, theirs)
                worst = max(worst, share)
                print(String(format: "REAL grab %@ %8.3f s: %4.1f%% differs from Filmora (%.2f s)", kind, seconds, share, elapsed))
            }
        }
        for seconds in [404.0] + cuts {
            let out = scratch.appendingPathComponent(String(format: "range-%.2f.mp4", seconds))
            let preset = ExportPreset(name: "range", width: 480, height: 270, codec: .h264, videoBitrate: 8_000_000, loudnessTarget: nil,
                                      range: TimeRange(start: Time(seconds: seconds), duration: Time(seconds: 0.12)))
            let started = Date()
            let exporter = Exporter(context: context, preset: preset, output: out)
            let watchdog = Task {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                XCTFail("the export from \(seconds) s stalled")
                exporter.cancel()
            }
            _ = try await exporter.run()
            watchdog.cancel()
            let exported = AVAssetImageGenerator(asset: AVURLAsset(url: out))
            exported.requestedTimeToleranceBefore = .zero
            exported.requestedTimeToleranceAfter = .zero
            // The first frame against Filmora; the next ones against our own
            // grabs. Filmora shows the nearest frame of variable frame rate
            // footage, and Tandem the last one at or before the time, so
            // mid-scroll they can be a frame apart.
            let first = Bitmap(try await exported.image(at: .zero).image)
            let filmora = blockDifference(first, Bitmap(try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image))
            var grabs = 0.0
            for offset in [0.0, 0.04, 0.08] {
                let frame = Bitmap(try await exported.image(at: CMTime(seconds: offset, preferredTimescale: 600)).image)
                let grab = Bitmap(try await renderer.image(at: Time(seconds: seconds + offset), maxSize: size))
                grabs = max(grabs, blockDifference(frame, grab))
            }
            worst = max(worst, filmora, grabs)
            print(String(format: "REAL range export from %8.3f s: first frame %4.1f%% off Filmora, frames %4.1f%% off our grabs (%.1f s)",
                         seconds, filmora, grabs, Date().timeIntervalSince(started)))
        }
        XCTAssertLessThan(worst, 3)
    }

    /// The app's paused player on originals at the same hard times: a seek
    /// with zero tolerance, compared with the grab.
    func testV14PausedPlayerOnOriginals() async throws {
        let context = try v14()
        let renderer = FrameRenderer(context: context)
        let built = try await CompositionBuilder.build(context)
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let size = CGSize(width: 480, height: 270)
        var worst = 0.0
        for seconds in [404.0, 51.52, 90.6, 115.6, 303.76, 414.12, 30.0] {
            let target = CMTime(seconds: seconds, preferredTimescale: 600)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            var pixels: CVPixelBuffer?
            let deadline = Date().addingTimeInterval(10)
            while pixels == nil && Date() < deadline {
                if output.hasNewPixelBuffer(forItemTime: target) {
                    pixels = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil)
                }
                if pixels == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            }
            let shown = try XCTUnwrap(pixels, "the player showed nothing at \(seconds)")
            let scaled = CIImage(cvPixelBuffer: shown).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(CVPixelBufferGetWidth(shown)), y: size.height / CGFloat(CVPixelBufferGetHeight(shown))))
            let share = blockDifference(Bitmap(scaled, size: size), Bitmap(try await renderer.image(at: Time(seconds: seconds), maxSize: size)))
            worst = max(worst, share)
            print(String(format: "REAL paused player at %8.3f s: %4.1f%% off the grab", seconds, share))
        }
        XCTAssertLessThan(worst, 3)
    }

    func testDecisionModelsV14MinuteExport() async throws {
        let context = try v14()
        let out = scratch.appendingPathComponent("v14-minute-120s.mp4")
        let preset = ExportPreset(name: "YouTube 4K range", codec: .hevc, videoBitrate: 80_000_000, range: TimeRange(start: Time(seconds: 120), duration: Time(seconds: 60)))
        let job = ExportPipeline(context: context, preset: preset, output: out, progress: { _ in })
        let result = try await job.run()
        print(String(format: "REAL v14 60 s range export: %.1f s = %.2fx real time, %.2f LUFS, %.2f dBTP",
                     result.elapsed, 60 / result.elapsed, result.integratedLUFS ?? -99, result.truePeakDBTP ?? -99))
        print("REAL phases: " + job.timings.map { String(format: "%@ %.1f s", $0.phase, $0.seconds) }.joined(separator: ", "))
        print("REAL frame recovery: \(FrameRecovery.shared.requests) frames, \(FrameRecovery.shared.readersOpened) readers")
        print("REAL loudness passes: " + job.loudnessPasses.map { String(format: "%+.2f dB%@ -> %.2f LUFS", $0.gainDB, $0.limited ? " limited" : "", $0.lufs) }.joined(separator: ", "))
        let length = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(length, 60, accuracy: 0.1)
    }

    func sideBySide(_ top: CGImage, _ bottom: CGImage, name: String) throws {
        let width = max(top.width, bottom.width)
        let context = CGContext(data: nil, width: width, height: top.height + bottom.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(top, in: CGRect(x: 0, y: bottom.height, width: top.width, height: top.height))
        context.draw(bottom, in: CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height))
        let url = scratch.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }

    func testFrameGrabOfTheComposite() async throws {
        let renderer = FrameRenderer(context: try await context(decisionModelsMinute()))
        let started = Date()
        let png = try await renderer.pngData(at: Time(seconds: 30))
        let elapsed = Date().timeIntervalSince(started)
        try png.write(to: scratch.appendingPathComponent("composite-30s.png"))
        let warnings = try await renderer.warnings()
        print("REAL frame grab at 30 s: \(String(format: "%.2f", elapsed)) s, warnings: \(warnings)")
        XCTAssertGreaterThan(png.count, 100_000)
    }

    func testSixtySecond4KExportSpeed() async throws {
        let project = decisionModelsMinute()
        let renderContext = try await context(project)
        for preset in [ExportPreset.youtube4K, ExportPreset(name: "4K 30 Mbps", codec: .hevc, videoBitrate: 30_000_000)] {
            let out = scratch.appendingPathComponent("decision-minute-\(preset.videoBitrate / 1_000_000)M.mp4")
            let result = try await Exporter(context: renderContext, preset: preset, output: out).run()
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            let realtime = 60 / result.elapsed
            print(String(format: "REAL export %@: %.1f s for 60 s = %.2fx real time, %.0f MB, %.2f LUFS, %.2f dBTP",
                         preset.name, result.elapsed, realtime, Double(size) / 1e6, result.integratedLUFS ?? -99, result.truePeakDBTP ?? -99))
            let length = try await AVURLAsset(url: out).load(.duration).seconds
            XCTAssertEqual(length, 60, accuracy: 0.1)
            XCTAssertEqual(try XCTUnwrap(result.integratedLUFS), -14, accuracy: 0.5)
            // The spike managed about 3.5x; don't regress badly.
            XCTAssertGreaterThan(realtime, 2.5)
        }
    }
}
