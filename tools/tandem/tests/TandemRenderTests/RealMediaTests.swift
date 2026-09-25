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

    func testDecisionModelsV14MinuteExport() async throws {
        let context = try v14()
        let out = scratch.appendingPathComponent("v14-minute-120s.mp4")
        let preset = ExportPreset(name: "YouTube 4K range", codec: .hevc, videoBitrate: 80_000_000, range: TimeRange(start: Time(seconds: 120), duration: Time(seconds: 60)))
        let result = try await Exporter(context: context, preset: preset, output: out).run()
        print(String(format: "REAL v14 60 s range export: %.1f s = %.2fx real time, %.2f LUFS, %.2f dBTP",
                     result.elapsed, 60 / result.elapsed, result.integratedLUFS ?? -99, result.truePeakDBTP ?? -99))
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
