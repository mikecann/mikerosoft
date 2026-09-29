import AVFoundation
import CoreImage
import QuartzCore
import XCTest
import TandemCore
@testable import TandemMedia
@testable import TandemRender

/// Proxies have a keyframe only every `proxyKeyFrameInterval` frames, with
/// P-frames between. The viewer's exact seeks still show the frame for
/// their time: jumps, arrow-key steps both ways across keyframes, and
/// playing forwards and backwards from a paused frame. The source spells
/// each frame's index in stripes; the timeline runs at 25 fps over 30 fps
/// footage, like Mike's projects.
final class ProxyExactFrameTests: XCTestCase {
    let whole = CGRect(x: 0, y: 0, width: 320, height: 90)

    struct Rig {
        var player: AVPlayer
        var output: AVPlayerItemVideoOutput
        var keyframes: Int
    }

    /// 8 s of footage proxied with today's settings, in a player set up as
    /// the viewer's are.
    func rig(_ media: TestMedia) async throws -> Rig {
        let source = try await media.movie("source.mov", seconds: 8, draw: { index, context in
            TestMedia.drawIndex(index, context)
            // Motion, so the P-frames carry something.
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: CGFloat(index * 3 % 300), y: 120, width: 20, height: 20))
        })
        let folder = media.folder.appendingPathComponent("proxy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ProxyJob.run(source: source, settings: .standard, into: folder, context: JobContext(id: "proxy", kind: .proxy, scheduler: nil))
        let proxy = folder.appendingPathComponent(ProxyJob.file)
        let track = try await AVURLAsset(url: proxy).loadTracks(withMediaType: .video)[0]
        let cursor = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        var keyframes = 0
        repeat { if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { keyframes += 1 } } while cursor.stepInDecodeOrder(byCount: 1) == 1

        let item = media.item("med_src", "source.mov", seconds: 8)
        let clip = Clip(id: "clip_src", content: .media(mediaID: "med_src"), start: .zero, duration: t(8))
        let project = Project(name: "Exact", settings: ProjectSettings(width: 320, height: 180, frameRate: .fps25),
                              media: [item], videoTracks: [Track(kind: .video, name: "V1", clips: [clip])], audioTracks: [])
        let assets = FakeAssets()
        assets.proxies["med_src"] = proxy
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder, useProxies: true, assets: assets))
        let playerItem = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        playerItem.add(output)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        return Rig(player: player, output: output, keyframes: keyframes)
    }

    func index(of pixels: CVPixelBuffer) -> Int {
        TestMedia.readIndex(Bitmap(CIImage(cvPixelBuffer: pixels), size: CGSize(width: 320, height: 180)), in: whole)
    }

    /// The source frame showing at timeline frame `k` (25 fps over 30 fps):
    /// the last one at or before it.
    func expected(_ k: Int) -> Int { k * 6 / 5 }

    /// What a paused player shows after an exact seek to timeline frame `k`.
    func shown(_ rig: Rig, at k: Int) async throws -> Int {
        let target = CMTime(value: CMTimeValue(k), timescale: 25)
        await rig.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if rig.output.hasNewPixelBuffer(forItemTime: target), let pixels = rig.output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) {
                return index(of: pixels)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("nothing shown at frame \(k)")
        return -1
    }

    func testSeeksAndArrowKeysLandOnTheExactFrame() async throws {
        let media = try TestMedia()
        let rig = try await rig(media)
        let interval = AnalysisSettings.standard.proxyKeyFrameInterval
        XCTAssertEqual(rig.keyframes, (240 + interval - 1) / interval, "a keyframe every \(interval) frames")
        // Source keyframes are frames 0, 15, 30...: timeline frames 12 and
        // 13 straddle source frame 15, 24 and 25 source frame 30.
        var wrong: [String] = []
        for k in [0, 12, 13, 24, 25, 26, 90, 6, 99, 100, 101, 150, 3, 49, 50, 51, 199, 37, 38] {
            let got = try await shown(rig, at: k)
            if got != expected(k) { wrong.append("jump to \(k): source frame \(got), not \(expected(k))") }
        }
        // Arrow keys: forwards across three keyframes, then back.
        for k in Array(10...40) + Array((2...39).reversed()) {
            let got = try await shown(rig, at: k)
            if got != expected(k) { wrong.append("step to \(k): source frame \(got), not \(expected(k))") }
        }
        XCTAssertEqual(wrong, [])
    }

    /// Plays for a second from a paused frame, returning each frame shown
    /// with its time.
    func play(_ rig: Rig, from k: Int, rate: Float) async throws -> [(seconds: Double, index: Int)] {
        _ = try await shown(rig, at: k)
        rig.player.rate = rate
        var frames: [(Double, Int)] = []
        let started = Date()
        while Date().timeIntervalSince(started) < 1 {
            let now = rig.output.itemTime(forHostTime: CACurrentMediaTime())
            var display = CMTime.invalid
            if rig.output.hasNewPixelBuffer(forItemTime: now), let pixels = rig.output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &display) {
                frames.append((display.seconds, index(of: pixels)))
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        rig.player.pause()
        return frames
    }

    func testPlayingFromAPausedFrameShowsEachFrameAtItsTime() async throws {
        let media = try TestMedia()
        let rig = try await rig(media)
        // Both paused frames sit in the middle of a GOP.
        for (from, rate) in [(58, Float(1)), (150, -1)] {
            let frames = try await play(rig, from: from, rate: rate)
            XCTAssertGreaterThan(frames.count, 10, "frames shown playing at \(rate)x")
            // Forwards a frame shows from its time; backwards, up to it. So
            // where a source frame starts exactly on a timeline frame (every
            // 0.2 s here), playing backwards shows the one before, as it
            // does from all-intra proxies.
            let wrong = frames.filter { seconds, index in
                index != (rate > 0 ? Int((seconds * 30 + 1e-6).rounded(.down)) : Int((seconds * 30 - 1e-6).rounded(.up)) - 1)
            }
            XCTAssertEqual(wrong.map { "\($0.seconds) s: source frame \($0.index)" }, [], "playing at \(rate)x")
            let start = expected(from)
            let first = frames.first?.index ?? -1
            let near = rate > 0 ? start...(start + 3) : (start - 3)...start
            XCTAssertTrue(near.contains(first), "playing at \(rate)x from source frame \(start) started at \(first)")
        }
    }
}

/// How much one still area of a picture changes over a run of frames:
/// the mean absolute change of its 8x8 block means (luma levels) from each
/// frame to the next, split into changes into keyframes (the tick) and
/// into other frames, and the standard deviation of the block means over
/// the run.
final class StillArea {
    let x0: Int, y0: Int, w: Int, h: Int
    private var sums: [Double], squares: [Double]
    private var previous: [Double]?
    private var keyChanges: [Double] = []
    private var otherChanges: [Double] = []
    private var frames = 0

    /// `region` is (x0, y0, x1, y1) as fractions of the frame.
    init(_ region: (Double, Double, Double, Double), width: Int, height: Int) {
        x0 = Int(region.0 * Double(width)) / 8 * 8
        y0 = Int(region.1 * Double(height)) / 8 * 8
        w = Int(region.2 * Double(width)) / 8 * 8 - x0
        h = Int(region.3 * Double(height)) / 8 * 8 - y0
        sums = [Double](repeating: 0, count: (w / 8) * (h / 8))
        squares = sums
    }

    func add(_ frame: CVPixelBuffer, keyframe: Bool) {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        let across = w / 8
        var blocks = [Double](repeating: 0, count: sums.count)
        for y in 0..<h {
            let line = base + (y0 + y) * row + x0
            for x in 0..<w { blocks[(y / 8) * across + x / 8] += Double(line[x]) / 64 }
        }
        for i in blocks.indices {
            sums[i] += blocks[i]
            squares[i] += blocks[i] * blocks[i]
        }
        if let previous {
            let change = zip(blocks, previous).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(blocks.count)
            if keyframe { keyChanges.append(change) } else { otherChanges.append(change) }
        }
        previous = blocks
        frames += 1
    }

    static func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    /// Mean change from one frame to the next.
    var crawl: Double { Self.mean(keyChanges + otherChanges) }
    /// Mean change into a keyframe (0 when there were none, or all were).
    var tick: Double { otherChanges.isEmpty ? 0 : Self.mean(keyChanges) }
    var deviation: Double {
        let n = Double(frames)
        return Self.mean(sums.indices.map { (max(0, squares[$0] / n - (sums[$0] / n) * (sums[$0] / n))).squareRoot() })
    }
}

/// Today's proxies against the all-intra ones they replaced (quality 0.6,
/// proxy version 2), on a minute of Mike's camera and of his screen
/// recording: how much a still wall and still screen text change from frame
/// to frame against the original, the tick at each keyframe, size, encode
/// speed, and how long the viewer takes to show an exact frame. Opt in with
/// TANDEM_REAL_MEDIA=1 (release, -enable-testing); skipped when the footage
/// isn't on this Mac. Reads the decision-models folder, never writing
/// there; proxies go to /private/tmp/claude-501/tandem-render/proxy.
final class ProxyRealMediaTests: XCTestCase {
    static let footage = URL(fileURLWithPath: NSString(string: "~/dev/convex/convex-videos/decision-models").expandingTildeInPath)
    static let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/tandem-render/proxy")

    struct Footage {
        var source: URL
        /// The minute proxied, and the still stretch measured in it.
        var from: Double
        var window: Double
        var regions: [(String, (Double, Double, Double, Double))]
    }

    /// The camera's wall beside Mike, and the screen's sidebar and code
    /// boxes while only the pointer moves.
    let camera = Footage(source: ProxyRealMediaTests.footage.appendingPathComponent("source/main vid/2026-09-24_105434-camera.mov"), from: 120, window: 150, regions: [("wall", (0.0, 0.05, 0.12, 0.5))])
    let screen = Footage(source: ProxyRealMediaTests.footage.appendingPathComponent("edit/main-screen.mov"), from: 1020, window: 1030, regions: [("sidebar", (0.0, 0.3, 0.19, 1.0)), ("text", (0.3, 0.6, 0.9, 1.0))])

    /// 150 frames of a file from `start` (movie time), scaled to fit 1080p
    /// as `ProxyJob` scales them, measured in each region. Keyframes come
    /// from the file's sample table.
    func measure(_ url: URL, from start: Double, regions: [(String, (Double, Double, Double, Double))]) async throws -> [String: StillArea] {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        let segments = try await track.load(.segments)
        let mapping = try XCTUnwrap(segments.first { !$0.isEmpty }?.timeMapping)
        let offset = mapping.target.start - mapping.source.start
        var keyframes = Set<Int64>()
        let cursor = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        repeat {
            let sync = cursor.currentSampleSyncInfo
            if sync.sampleIsFullSync.boolValue || sync.sampleIsPartialSync.boolValue {
                keyframes.insert(CMTimeConvertScale(cursor.presentationTimeStamp + offset, timescale: 90_000, method: .roundHalfAwayFromZero).value)
            }
        } while cursor.stepInDecodeOrder(byCount: 1) == 1

        let reader = try await VideoFrameReader(url: url, timeRange: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: 60, preferredTimescale: 600)))
        defer { reader.cancel() }
        let size = fittedSize(width: Int(reader.size.width), height: Int(reader.size.height), maxWidth: 1920, maxHeight: 1080)
        let scaler = try PixelScaler(width: size.width, height: size.height, pixelFormat: reader.pixelFormat)
        let areas = Dictionary(uniqueKeysWithValues: regions.map { ($0.0, StillArea($0.1, width: size.width, height: size.height)) })
        for _ in 0..<150 {
            guard let frame = try reader.next() else { break }
            let scaled = try scaler.scale(frame.buffer)
            let key = keyframes.contains(CMTimeConvertScale(frame.time, timescale: 90_000, method: .roundHalfAwayFromZero).value)
            for area in areas.values { area.add(scaled, keyframe: key) }
        }
        return areas
    }

    struct Built {
        var url: URL
        var megabytesPerMinute: Double
        var secondsPerMinute: Double
    }

    func proxy(_ footage: Footage, _ settings: AnalysisSettings, name: String) async throws -> Built {
        let folder = Self.scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = CACurrentMediaTime()
        try await ProxyJob.run(source: footage.source, settings: settings, into: folder, context: JobContext(id: name, kind: .proxy, scheduler: nil),
                               timeRange: CMTimeRange(start: CMTime(seconds: footage.from, preferredTimescale: 600), duration: CMTime(seconds: 60, preferredTimescale: 600)))
        let seconds = CACurrentMediaTime() - started
        let url = folder.appendingPathComponent(ProxyJob.file)
        let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).doubleValue
        return Built(url: url, megabytesPerMinute: bytes / 1e6, secondsPerMinute: seconds)
    }

    /// The screen minute with the camera minute over it as a picture in
    /// picture, at 25 fps, built from the given proxies as the viewer
    /// builds it (1080p). Times until a paused player shows the exact frame
    /// after a seek to 120 random frames, and after stepping back a frame.
    func seekTimes(cameraProxy: URL, screenProxy: URL, cameraItem: MediaItem, screenItem: MediaItem) async throws -> (random: [Double], back: [Double]) {
        let screenClip = Clip(content: .media(mediaID: screenItem.id), start: .zero, duration: t(60), sourceStart: t(screen.from))
        let cameraClip = Clip(content: .media(mediaID: cameraItem.id), start: .zero, duration: t(60), sourceStart: t(camera.from),
                              video: VideoProperties(transform: Transform(position: Point(x: 0.78, y: 0.74), scale: 0.4)))
        let project = Project(name: "Seeks", settings: ProjectSettings(width: 3840, height: 2160, frameRate: .fps25), media: [screenItem, cameraItem],
                              videoTracks: [Track(kind: .video, name: "Screen", clips: [screenClip]), Track(kind: .video, name: "Camera", clips: [cameraClip])],
                              audioTracks: [])
        let assets = FakeAssets()
        assets.proxies = [screenItem.id: screenProxy, cameraItem.id: cameraProxy]
        var context = RenderContext(project: project, folder: ProjectFolder(root: Self.footage), useProxies: true, assets: assets)
        context.sizeOverride = CGSize(width: 1920, height: 1080)
        let built = try await CompositionBuilder.build(context)
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        defer { player.replaceCurrentItem(with: nil) }

        func timed(_ frame: Int) async -> Double? {
            let target = CMTime(value: CMTimeValue(frame), timescale: 25)
            let started = CACurrentMediaTime()
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            while CACurrentMediaTime() - started < 5 {
                if output.hasNewPixelBuffer(forItemTime: target), output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) != nil {
                    return CACurrentMediaTime() - started
                }
                try? await Task.sleep(nanoseconds: 250_000)
            }
            return nil
        }
        // The same frames every run.
        var state: UInt64 = 42
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 1_450) + 20
        }
        for _ in 0..<10 { _ = await timed(next()) }
        var random: [Double] = [], back: [Double] = []
        for _ in 0..<120 {
            let frame = next()
            if let seconds = await timed(frame) { random.append(seconds) } else { XCTFail("no frame at \(frame)") }
            if let seconds = await timed(frame - 1) { back.append(seconds) }
        }
        return (random, back)
    }

    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))]
    }

    func testTodaysProxiesAgainstAllIntra() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_REAL_MEDIA"] == "1", "set TANDEM_REAL_MEDIA=1 to run")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: camera.source.path) && FileManager.default.fileExists(atPath: screen.source.path), "decision-models footage isn't on this Mac")
        let today = AnalysisSettings.standard
        let allIntra = AnalysisSettings(proxyQuality: 0.6, proxyKeyFrameInterval: 1)
        var lines = ["PROXY a minute of camera and of screen; still areas over 150 frames: mean change a frame / at keyframes / sd of 8x8 block means"]

        let cameraOriginal = try await measure(camera.source, from: camera.window, regions: camera.regions)
        let screenOriginal = try await measure(screen.source, from: screen.window, regions: screen.regions)
        var results: [String: (camera: Built, screen: Built, cameraAreas: [String: StillArea], screenAreas: [String: StillArea])] = [:]
        for (name, settings) in [("all-intra", allIntra), ("today", today)] {
            let cameraProxy = try await proxy(camera, settings, name: "\(name)-camera")
            let screenProxy = try await proxy(screen, settings, name: "\(name)-screen")
            results[name] = (cameraProxy, screenProxy,
                             try await measure(cameraProxy.url, from: camera.window, regions: camera.regions),
                             try await measure(screenProxy.url, from: screen.window, regions: screen.regions))
        }
        func describe(_ label: String, _ areas: [String: StillArea], _ extra: String = "") -> String {
            label.padding(toLength: 24, withPad: " ", startingAt: 0) + areas.keys.sorted().map { key in
                String(format: "%@ %.3f / %.3f / %.2f", key, areas[key]!.crawl, areas[key]!.tick, areas[key]!.deviation)
            }.joined(separator: "   ") + extra
        }
        lines.append(describe("camera original", cameraOriginal))
        lines.append(describe("screen original", screenOriginal))
        for name in ["all-intra", "today"] {
            let r = results[name]!
            lines.append(describe("camera \(name)", r.cameraAreas, String(format: "   %.0f MB/min, built in %.1f s", r.camera.megabytesPerMinute, r.camera.secondsPerMinute)))
            lines.append(describe("screen \(name)", r.screenAreas, String(format: "   %.0f MB/min, built in %.1f s", r.screen.megabytesPerMinute, r.screen.secondsPerMinute)))
        }

        let cameraItem = try await MediaScanner.probe(camera.source, folder: ProjectFolder(root: Self.footage), id: "med_camera")
        let screenItem = try await MediaScanner.probe(screen.source, folder: ProjectFolder(root: Self.footage), id: "med_screen")
        var seeks: [String: (random: [Double], back: [Double])] = [:]
        for name in ["all-intra", "today", "all-intra", "today"] {
            let r = results[name]!
            let times = try await seekTimes(cameraProxy: r.camera.url, screenProxy: r.screen.url, cameraItem: cameraItem, screenItem: screenItem)
            seeks[name, default: ([], [])].random += times.random
            seeks[name, default: ([], [])].back += times.back
        }
        for name in ["all-intra", "today"] {
            let s = seeks[name]!
            lines.append(String(format: "seek %@: exact frame shown p50 %.1f p95 %.1f ms; a frame back p50 %.1f p95 %.1f ms", name,
                                percentile(s.random, 0.5) * 1000, percentile(s.random, 0.95) * 1000, percentile(s.back, 0.5) * 1000, percentile(s.back, 0.95) * 1000))
        }
        print(lines.joined(separator: "\n"))

        // Today's proxies leave still areas far stiller than all-intra did,
        // with a keyframe tick about the size of the camera's own.
        let wall = results["today"]!.cameraAreas["wall"]!, oldWall = results["all-intra"]!.cameraAreas["wall"]!, wallOriginal = cameraOriginal["wall"]!
        XCTAssertGreaterThan(oldWall.crawl, 2.5 * wallOriginal.crawl, "the all-intra crawl this is about")
        XCTAssertLessThan(wall.crawl, 0.6 * wallOriginal.crawl)
        XCTAssertLessThan(wall.tick, 1.4 * wallOriginal.tick)
        XCTAssertLessThan(wall.deviation, 1.2 * wallOriginal.deviation)
        for region in ["sidebar", "text"] {
            let area = results["today"]!.screenAreas[region]!
            XCTAssertLessThan(area.crawl, 0.25 * results["all-intra"]!.screenAreas[region]!.crawl, region)
            XCTAssertLessThan(area.tick, 1.5 * screenOriginal[region]!.tick, region)
        }
        // No bigger or slower to make.
        let now = results["today"]!, before = results["all-intra"]!
        XCTAssertLessThanOrEqual(now.camera.megabytesPerMinute, before.camera.megabytesPerMinute)
        XCTAssertLessThan(now.screen.megabytesPerMinute, 0.3 * before.screen.megabytesPerMinute)
        XCTAssertLessThan(now.camera.secondsPerMinute, 1.25 * before.camera.secondsPerMinute)
        // Exact seeks within 1.5 times all-intra's, or under 30 ms.
        let p95 = percentile(seeks["today"]!.random, 0.95), oldP95 = percentile(seeks["all-intra"]!.random, 0.95)
        XCTAssertLessThan(p95, max(1.5 * oldP95, 0.030), "p95 exact seek")
    }
}
