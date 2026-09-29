import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

/// Presentation times of every sample in a movie's first video track.
func videoSampleTimes(_ url: URL) async throws -> [CMTime] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let cursor = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder())
    var times: [CMTime] = []
    repeat { times.append(cursor.presentationTimeStamp) } while cursor.stepInDecodeOrder(byCount: 1) == 1
    return times.sorted { CMTimeCompare($0, $1) < 0 }
}

/// Average luma and chroma of a movie's first frame, 0...255, read as full range.
func firstFrameAverages(_ url: URL) async throws -> (luma: Double, chroma: Double) {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
    reader.add(output)
    reader.startReading()
    let sample = try XCTUnwrap(output.copyNextSampleBuffer())
    let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    var total = 0
    for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
        for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) { total += Int(base[y * stride + x]) }
    }
    let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    var chroma = 0
    for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
        for x in 0..<(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2) { chroma += Int(chromaBase[y * chromaStride + x]) }
    }
    return (
        Double(total) / Double(CVPixelBufferGetWidthOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0)),
        Double(chroma) / Double(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2 * CVPixelBufferGetHeightOfPlane(buffer, 1))
    )
}

final class AnalysisTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    /// Mattes fall back to Vision here unless a test gives RVM a model:
    /// tests never download it.
    func analysis() -> MediaAnalysis {
        let analysis = MediaAnalysis(folder: folder, encoderLock: EncoderLock())
        analysis.rvmStore = RVMModelStore(folder: folder.root.appendingPathComponent("no-models", isDirectory: true), fileName: "model.mlmodel",
                                          remote: URL(string: "https://example.invalid/model.mlmodel")!, sha256: String(repeating: "0", count: 64),
                                          fetch: { _ in throw URLError(.notConnectedToInternet) })
        return analysis
    }

    func item(_ path: String) async throws -> MediaItem {
        try await MediaScanner.probe(file(path), folder: folder)
    }

    func testDefaultKindsFollowRolesAndSizes() {
        let camera = MediaItem(path: "source/a-camera.mov", kind: .video, role: .camera, width: 3840, height: 2160, hasVideo: true, hasAudio: true)
        XCTAssertEqual(MediaAnalysis.defaultKinds(for: camera), [.thumbnails, .waveform, .loudness, .proxy, .transcript, .isolatedVoice, .matte])
        let screen = MediaItem(path: "source/a-screen.mov", kind: .video, role: .screen, width: 3200, height: 1800, hasVideo: true, hasAudio: false)
        XCTAssertEqual(MediaAnalysis.defaultKinds(for: screen), [.thumbnails, .proxy])
        let broll = MediaItem(path: "broll/b.mp4", kind: .video, role: .broll, width: 1920, height: 1080, hasVideo: true, hasAudio: true)
        XCTAssertEqual(MediaAnalysis.defaultKinds(for: broll), [.thumbnails, .waveform, .loudness])
        let portrait = MediaItem(path: "p.mov", kind: .video, role: .other, width: 1080, height: 1920, hasVideo: true)
        XCTAssertEqual(MediaAnalysis.defaultKinds(for: portrait), [.thumbnails])
        let music = MediaItem(path: "music/bed.mp3", kind: .audio, role: .music, hasAudio: true)
        XCTAssertEqual(MediaAnalysis.defaultKinds(for: music), [.waveform, .loudness])
        let image = MediaItem(path: "graphics/logo.png", kind: .image, role: .graphic, width: 100, height: 100, hasVideo: true)
        XCTAssertEqual(MediaAnalysis.defaultKinds(for: image), [.thumbnails])
    }

    func testRequestDefaultsQueuesTimelineMediaFirst() async throws {
        try SyntheticMedia.writeAudioFile(to: file("music/bed.wav"), segments: [(1, 0.2)])
        try await SyntheticMedia.writeMovie(to: file("source/t-camera.mov"), .init(duration: 0.5))
        let bed = try await item("music/bed.wav")
        let camera = try await item("source/t-camera.mov")
        let analysis = analysis()
        // Hold everything in the queue so its order can be read.
        var limits = JobScheduler.Limits.standard
        limits.total = 0
        analysis.scheduler.limits = limits
        analysis.requestDefaults(for: [bed, camera], usedOnTimeline: [camera.id])
        let queued = analysis.jobs.map { "\($0.mediaID == camera.id ? "camera" : "bed") \($0.kind.rawValue)" }
        XCTAssertEqual(queued, [
            "camera waveform", "camera loudness", "camera thumbnails", "camera transcript", "camera isolatedVoice", "camera matte",
            "bed waveform", "bed loudness"
        ])
        XCTAssertEqual(analysis.state(.matte, for: camera), .queued)
        analysis.cancelAll()
        XCTAssertEqual(analysis.state(.matte, for: camera), .missing)
    }

    func testFittedSizesKeepAspectAndNeverUpscale() {
        XCTAssertTrue(fittedSize(width: 3840, height: 2160, maxWidth: 1920, maxHeight: 1080) == (1920, 1080))
        XCTAssertTrue(fittedSize(width: 3200, height: 1800, maxWidth: 1920, maxHeight: 1080) == (1920, 1080))
        XCTAssertTrue(fittedSize(width: 2160, height: 3840, maxWidth: 1920, maxHeight: 1080) == (1080, 1920))
        XCTAssertTrue(fittedSize(width: 4096, height: 1716, maxWidth: 1920, maxHeight: 1080) == (1920, 804))
        XCTAssertTrue(fittedSize(width: 640, height: 360, maxWidth: 1920, maxHeight: 1080) == (640, 360))
    }

    func testSettingsOnlyChangeTheKindsThatUseThem() {
        var settings = AnalysisSettings()
        let before = AnalysisKind.allCases.map { settings.canonical(for: $0) }
        settings.transcriptLocale = "en-AU"
        let after = AnalysisKind.allCases.map { settings.canonical(for: $0) }
        let changed = AnalysisKind.allCases.indices.filter { before[$0] != after[$0] }.map { AnalysisKind.allCases[$0] }
        XCTAssertEqual(changed, [.transcript])
    }

    func testProxyKeyFollowsItsKeyframesAndQuality() {
        let standard = AnalysisSettings()
        XCTAssertEqual(standard.canonical(for: .proxy), "{\"box\":\"1920x1080\",\"keyframes\":\"15\",\"quality\":\"0.78\"}")
        var intra = standard
        intra.proxyKeyFrameInterval = 1
        XCTAssertNotEqual(intra.canonical(for: .proxy), standard.canonical(for: .proxy))
        let changed = AnalysisKind.allCases.filter { intra.canonical(for: $0) != standard.canonical(for: $0) }
        XCTAssertEqual(changed, [.proxy])
        // Version 3 rebuilds the all-intra proxies whatever their settings.
        XCTAssertEqual(AnalysisKind.proxy.algorithmVersion, 3)
    }

    func testWaveformHasAPeakEveryHundredthOfASecond() async throws {
        try SyntheticMedia.writeAudioFile(to: file("music/tone.wav"), segments: [(1, 0), (1, 0.5)])
        let tone = try await item("music/tone.wav")
        let analysis = analysis()
        XCTAssertNil(analysis.waveform(for: tone))
        let state = await analysis.waitFor(.waveform, for: tone)
        XCTAssertEqual(state, .ready)

        let waveform = try XCTUnwrap(analysis.waveform(for: tone))
        XCTAssertEqual(waveform.samplesPerSecond, 100)
        XCTAssertEqual(waveform.peaks.count, 200)
        XCTAssertEqual(waveform.peaks[0..<100].max() ?? 1, 0, accuracy: 0.001)
        for peak in waveform.peaks[101..<200] { XCTAssertEqual(peak, 0.5, accuracy: 0.01) }

        let entry = try XCTUnwrap(analysis.cache.lookup(kind: .waveform, key: try XCTUnwrap(analysis.cacheKey(.waveform, for: tone))))
        XCTAssertEqual(try Data(contentsOf: entry.appendingPathComponent(WaveformJob.peaksFile)).count, 800)
    }

    func testWaveformDoesNotDriftAtRatesWithFractionalBuckets() async throws {
        // 22.05 kHz is 220.5 samples per bucket; a click at 18 s must land
        // in bucket 1800.
        try SyntheticMedia.writeAudioFile(to: file("old.wav"), segments: [(18, 0), (0.02, 0.8), (1.98, 0)], sampleRate: 22_050, channels: 1)
        let old = try await item("old.wav")
        let analysis = analysis()
        await analysis.waitFor(.waveform, for: old)
        let peaks = try XCTUnwrap(analysis.waveform(for: old)).peaks
        XCTAssertEqual(peaks.count, 2000)
        XCTAssertEqual(peaks.firstIndex { $0 > 0.5 }, 1800)
        XCTAssertEqual(peaks.lastIndex { $0 > 0.5 }, 1801)
    }

    func testLoudnessOfTheEBUReferenceTone() async throws {
        let amplitude = pow(10, -23.0 / 20)
        try SyntheticMedia.writeAudioFile(to: file("ref.wav"), segments: [(4, amplitude)])
        let reference = try await item("ref.wav")
        let analysis = analysis()
        await analysis.waitFor(.loudness, for: reference)
        let loudness = try XCTUnwrap(analysis.loudness(for: reference))
        XCTAssertEqual(loudness.integratedLUFS, -23, accuracy: 0.1)
        XCTAssertEqual(loudness.truePeakDBTP, -23, accuracy: 0.3)
    }

    func testSilenceStoresMinusInfinity() async throws {
        try SyntheticMedia.writeAudioFile(to: file("silence.wav"), segments: [(1, 0)])
        let silence = try await item("silence.wav")
        let analysis = analysis()
        await analysis.waitFor(.loudness, for: silence)
        XCTAssertEqual(analysis.loudness(for: silence)?.integratedLUFS, -.infinity)
    }

    func testThumbnailStripForAMovie() async throws {
        try await SyntheticMedia.writeMovie(to: file("broll/clip.mov"), .init(width: 640, height: 360, duration: 5, audio: nil))
        let clip = try await item("broll/clip.mov")
        let analysis = analysis()
        await analysis.waitFor(.thumbnails, for: clip)
        let (strip, folder) = try XCTUnwrap(analysis.thumbnails(for: clip))
        XCTAssertEqual(strip.interval, 2)
        XCTAssertEqual(strip.files.count, 3)
        XCTAssertEqual(strip.width, 320)
        XCTAssertEqual(strip.height, 180)
        for name in strip.files {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 320)
            XCTAssertEqual(image.height, 180)
        }
    }

    func testThumbnailForAnImage() async throws {
        try SyntheticMedia.writePNG(to: file("graphics/card.png"), width: 640, height: 480, alpha: true)
        let card = try await item("graphics/card.png")
        let analysis = analysis()
        await analysis.waitFor(.thumbnails, for: card)
        let (strip, _) = try XCTUnwrap(analysis.thumbnails(for: card))
        XCTAssertEqual(strip.files.count, 1)
        XCTAssertEqual(strip.width, 320)
        XCTAssertEqual(strip.height, 240)
    }

    func testProxyIsSmallerWithRegularKeyframesAndKeepsEveryTimestamp() async throws {
        // A variable frame rate "screen recording" bigger than 1080p.
        var times: [Double] = []
        var t = 0.0
        for i in 0..<24 {
            times.append(t)
            t += i % 6 == 5 ? 0.9 : 1.0 / 30
        }
        try await SyntheticMedia.writeMovie(to: file("source/demo-screen.mov"), .init(width: 2400, height: 1350, frameTimes: times))
        let screen = try await item("source/demo-screen.mov")
        XCTAssertTrue(screen.variableFrameRate)
        let analysis = analysis()
        let state = await analysis.waitFor(.proxy, for: screen)
        XCTAssertEqual(state, .ready)

        let proxy = try XCTUnwrap(analysis.proxyURL(for: screen))
        let asset = AVURLAsset(url: proxy)
        let tracks = try await asset.load(.tracks)
        XCTAssertEqual(tracks.map(\.mediaType), [.video], "video only")
        let (size, formats) = try await tracks[0].load(.naturalSize, .formatDescriptions)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_HEVC, "plain HEVC: the screen has no alpha")

        let sourceTimes = try await videoSampleTimes(file("source/demo-screen.mov"))
        let proxyTimes = try await videoSampleTimes(proxy)
        XCTAssertEqual(proxyTimes.count, sourceTimes.count)
        for (a, b) in zip(sourceTimes, proxyTimes) { XCTAssertEqual(CMTimeCompare(a, b), 0, "\(a.seconds) vs \(b.seconds)") }

        // A keyframe every `proxyKeyFrameInterval` frames, P-frames between,
        // decoded in the order they're shown.
        let interval = AnalysisSettings.standard.proxyKeyFrameInterval
        XCTAssertGreaterThan(interval, 1)
        let cursor = try XCTUnwrap(tracks[0].makeSampleCursorAtFirstSampleInDecodeOrder())
        var keyframes: [Int] = []
        var decodeOrder: [CMTime] = []
        repeat {
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { keyframes.append(decodeOrder.count) }
            decodeOrder.append(cursor.presentationTimeStamp)
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        XCTAssertEqual(keyframes, Array(stride(from: 0, to: sourceTimes.count, by: interval)))
        XCTAssertEqual(decodeOrder, decodeOrder.sorted { CMTimeCompare($0, $1) < 0 }, "no frame reordering")

        let sourceEnd = try await AVURLAsset(url: file("source/demo-screen.mov")).loadTracks(withMediaType: .video)[0].load(.timeRange).end
        let proxyEnd = try await tracks[0].load(.timeRange).end
        XCTAssertEqual(proxyEnd.seconds, sourceEnd.seconds, accuracy: 0.001, "the last frame lasts as long as in the source")
    }

    /// Overlays and stickers bigger than 1080p get proxies too, and those
    /// keep the alpha, straight or premultiplied as the source has it, so
    /// the viewer shows the track below through them.
    func testProxyOfVideoWithAlphaKeepsTheAlpha() async throws {
        // ProRes 4444 from ffmpeg, straight alpha: the left third opaque,
        // the middle third at half alpha, the right third clear.
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        try ffmpeg.run([
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "color=c=white:s=2400x1350:d=1:r=30,format=rgba,geq=r='255':g='255':b='255':a='if(lt(X,W/3),255,if(lt(X,2*W/3),128,0))'",
            "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-alpha_bits", "16", file("overlays/leak.mov").path
        ])
        // HEVC with alpha from AVAssetWriter, premultiplied.
        try await SyntheticMedia.writeMovie(to: file("stickers/pop.mov"), .init(width: 2400, height: 1350, duration: 0.5, codec: .hevcWithAlpha, audio: nil))
        let analysis = analysis()
        let modes = ["overlays/leak.mov": kCMFormatDescriptionAlphaChannelMode_StraightAlpha, "stickers/pop.mov": kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha]
        for (path, mode) in modes.sorted(by: { $0.key < $1.key }) {
            let source = try await item(path)
            XCTAssertTrue(source.hasAlpha, path)
            let state = await analysis.waitFor(.proxy, for: source)
            XCTAssertEqual(state, .ready, path)
            let proxy = try XCTUnwrap(analysis.proxyURL(for: source))
            let track = try await AVURLAsset(url: proxy).loadTracks(withMediaType: .video)[0]
            let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
            XCTAssertEqual(size, CGSize(width: 1920, height: 1080), path)
            // HEVC with an alpha layer ("hvc1" with ContainsAlphaChannel).
            let format = try XCTUnwrap(formats.first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC, path)
            XCTAssertTrue(MediaProbe.containsAlpha(format), path)
            let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
            XCTAssertEqual(extensions[kCMFormatDescriptionExtension_AlphaChannelMode as String] as? String, mode as String, path)

            // Keyframes and P-frames as every proxy has them.
            let cursor = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder())
            var keyframes: [Int] = []
            var decodeOrder: [CMTime] = []
            repeat {
                if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { keyframes.append(decodeOrder.count) }
                decodeOrder.append(cursor.presentationTimeStamp)
            } while cursor.stepInDecodeOrder(byCount: 1) == 1
            let sourceTimes = try await videoSampleTimes(file(path))
            XCTAssertEqual(decodeOrder, sourceTimes, "every frame at its source time, no reordering, \(path)")
            XCTAssertEqual(keyframes, Array(stride(from: 0, to: sourceTimes.count, by: AnalysisSettings.standard.proxyKeyFrameInterval)), path)
        }

        let overlay = try await item("overlays/leak.mov")
        let leak = try XCTUnwrap(analysis.proxyURL(for: overlay))
        var alphas: [Int] = []
        for x in [320, 960, 1600] { alphas.append(try await firstFramePixel(leak, x: x, y: 540).alpha) }
        // HEVC's alpha layer brings opaque back as 251 to 253, the
        // original HEVC stickers' included.
        XCTAssertEqual(alphas[0], 255, accuracy: 4)
        XCTAssertEqual(alphas[1], 128, accuracy: 4)
        XCTAssertEqual(alphas[2], 0, accuracy: 2)
    }

    /// Proxies made before they kept alpha are rebuilt for video with
    /// alpha, whose key now says so. Every other proxy keeps its key, and
    /// the file it has.
    func testOnlyProxiesOfVideoWithAlphaChangeTheirKey() throws {
        let standard = AnalysisSettings.standard
        let screen = MediaItem(path: "source/a-screen.mov", kind: .video, role: .screen, width: 3200, height: 1800, hasVideo: true)
        let overlay = MediaItem(path: "overlays/leak.mov", kind: .video, role: .broll, width: 3840, height: 2160, hasVideo: true, hasAlpha: true)
        for kind in AnalysisKind.allCases {
            XCTAssertEqual(standard.canonical(for: kind, item: screen), standard.canonical(for: kind), "\(kind)")
            if kind != .proxy { XCTAssertEqual(standard.canonical(for: kind, item: overlay), standard.canonical(for: kind), "\(kind)") }
        }
        XCTAssertEqual(standard.canonical(for: .proxy, item: overlay), "{\"alpha\":\"1\",\"box\":\"1920x1080\",\"keyframes\":\"15\",\"quality\":\"0.78\"}")

        // Version 3 proxies as they were cached before, keyed without alpha.
        touch(screen.path, contents: "screen")
        touch(overlay.path, contents: "overlay")
        let analysis = analysis()
        for item in [screen, overlay] {
            let fingerprint = try XCTUnwrap(analysis.fingerprint(for: item))
            let settings = standard.canonical(for: .proxy)
            let pending = try analysis.cache.begin(kind: .proxy, key: AnalysisCache.key(fingerprint: fingerprint, kind: .proxy, algorithmVersion: 3, settings: settings))
            try Data([1]).write(to: pending.folder.appendingPathComponent(ProxyJob.file))
            try analysis.cache.commit(pending, fingerprint: fingerprint, algorithmVersion: 3, settings: settings, source: item.path)
        }
        XCTAssertEqual(analysis.state(.proxy, for: screen), .ready, "the screen's proxy stays")
        XCTAssertNotNil(analysis.proxyURL(for: screen))
        XCTAssertEqual(analysis.state(.proxy, for: overlay), .missing, "the overlay's proxy lost its alpha, so it's made again")
        XCTAssertNil(analysis.proxyURL(for: overlay))
    }

    func testMatteIsGreyscaleWithTheSourceFrameTimes() async throws {
        var times: [Double] = []
        var t = 0.0
        for i in 0..<12 {
            times.append(t)
            t += i % 4 == 3 ? 0.5 : 1.0 / 30
        }
        try await SyntheticMedia.writeMovie(to: file("source/take-camera.mov"), .init(width: 320, height: 180, frameTimes: times))
        let camera = try await item("source/take-camera.mov")
        let analysis = analysis()
        // Vision's mattes differ by cutout mode; RVM's don't.
        analysis.settings.matteModel = .vision
        let state = await analysis.waitFor(.matte, for: camera)
        XCTAssertEqual(state, .ready)

        let matte = try XCTUnwrap(analysis.matteURL(for: camera))
        let track = try await AVURLAsset(url: matte).loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 180))
        let sourceTimes = try await videoSampleTimes(file("source/take-camera.mov"))
        let matteTimes = try await videoSampleTimes(matte)
        XCTAssertEqual(matteTimes.count, sourceTimes.count)
        for (a, b) in zip(sourceTimes, matteTimes) { XCTAssertEqual(CMTimeCompare(a, b), 0) }
        // Vision's guess on flat colour is noise, so only the format is
        // checked here; the real footage tests look at a real person.
        let averages = try await firstFrameAverages(matte)
        XCTAssertEqual(averages.chroma, 128, accuracy: 2, "neutral chroma: a greyscale matte")
        XCTAssertNil(analysis.matteURL(for: camera, mode: .person), "a different mode is a different result")
        var personOnly = analysis.settings
        personOnly.matteMode = .person
        let personState = await analysis.waitFor(.matte, for: camera, settings: personOnly)
        XCTAssertEqual(personState, .ready)
        XCTAssertNotNil(analysis.matteURL(for: camera, mode: .person))
        XCTAssertNotEqual(analysis.matteURL(for: camera, mode: .person), analysis.matteURL(for: camera))
    }

    func testTheMatteFallsBackToVisionSayingSoAndRebuildsOnceWhenRVMArrives() async throws {
        try await SyntheticMedia.writeMovie(to: file("source/take-camera.mov"), .init(width: 320, height: 180, duration: 0.5))
        let camera = try await item("source/take-camera.mov")
        let analysis = analysis()
        let models = folder.root.appendingPathComponent("models", isDirectory: true)
        analysis.rvmStore = RVMModelStore(folder: models, fileName: "model.mlmodel", remote: URL(string: "https://example.invalid/model.mlmodel")!,
                                          sha256: String(repeating: "0", count: 64), fetch: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(analysis.settings.matteModel, .robustVideoMatting)
        let state = await analysis.waitFor(.matte, for: camera)
        XCTAssertEqual(state, .ready, "offline: a Vision matte rather than none")
        let status = try XCTUnwrap(analysis.jobs.first { $0.kind == .matte })
        XCTAssertTrue(status.message?.contains("Vision") ?? false, "not silently: \(status.message ?? "no message")")
        XCTAssertNotNil(analysis.matteURL(for: camera))
        XCTAssertNil(analysis.submit(.matte, for: camera), "nothing new to try yet")

        // The model turns up (here a file that won't load): one rebuild, and
        // the fallback keeps serving until it's done.
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("not a model".utf8).write(to: models.appendingPathComponent("model.mlmodel"))
        XCTAssertEqual(analysis.state(.matte, for: camera), .missing)
        XCTAssertNotNil(analysis.matteURL(for: camera))
        let rebuild = await analysis.waitFor(.matte, for: camera)
        XCTAssertEqual(rebuild, .ready)
        XCTAssertNil(analysis.submit(.matte, for: camera), "no rebuild loop while the model stays as it is")
    }

    func testRVMMattesATakeWhenItsModelIsHere() async throws {
        let model = RVMModelStore.standard.folder.appendingPathComponent(RVMModelStore.standard.fileName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path), "the RVM model isn't on this Mac (tests never download it)")
        try await SyntheticMedia.writeMovie(to: file("source/take-camera.mov"), .init(width: 320, height: 180, duration: 0.5))
        let camera = try await item("source/take-camera.mov")
        let analysis = analysis()
        analysis.rvmStore = .standard
        let state = await analysis.waitFor(.matte, for: camera)
        XCTAssertEqual(state, .ready)
        let matte = try XCTUnwrap(analysis.matteURL(for: camera))
        XCTAssertNil(MatteFallback.read(from: matte.deletingLastPathComponent()), "made by RVM")
        let matteTimes = try await videoSampleTimes(matte)
        let sourceTimes = try await videoSampleTimes(file("source/take-camera.mov"))
        XCTAssertEqual(matteTimes.count, sourceTimes.count)
        XCTAssertEqual(analysis.matteURL(for: camera, mode: .person), matte, "both cutout modes share one RVM matte")
    }

    func testIsolatedVoiceKeepsTheLengthAtFortyEightKilohertz() async throws {
        try SyntheticMedia.writeAudioFile(to: file("voice.wav"), segments: [(1.5, 0.3)], sampleRate: 48_000, channels: 2)
        try SyntheticMedia.writeAudioFile(to: file("phone.wav"), segments: [(1.5, 0.3)], sampleRate: 44_100, channels: 1)
        let analysis = analysis()
        for (path, channels) in [("voice.wav", 2), ("phone.wav", 1)] {
            let voice = try await item(path)
            let state = await analysis.waitFor(.isolatedVoice, for: voice)
            XCTAssertEqual(state, .ready)
            let url = try XCTUnwrap(analysis.isolatedVoiceURL(for: voice))
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
            XCTAssertEqual(Int(file.fileFormat.channelCount), channels)
            XCTAssertEqual(file.length, 72_000, path)
        }
    }

    func testIsolatedVoiceIsExactlyAsLongAsTheSourceAtAnyLength() async throws {
        // Lengths that end part way through a render, in mono (2,705 samples
        // of latency) and stereo (3,665).
        let analysis = analysis()
        for (index, frames) in [69_732, 49_391, 100_003].enumerated() {
            for channels in [1, 2] {
                let path = "len\(index)-\(channels).wav"
                try SyntheticMedia.writeAudioFile(to: file(path), segments: [(Double(frames) / 48_000, 0.3)], sampleRate: 48_000, channels: channels)
                let voice = try await item(path)
                let state = await analysis.waitFor(.isolatedVoice, for: voice)
                XCTAssertEqual(state, .ready)
                let result = try AVAudioFile(forReading: try XCTUnwrap(analysis.isolatedVoiceURL(for: voice)))
                XCTAssertEqual(result.length, AVAudioFramePosition(frames), path)
            }
        }
    }

    func testResultsSurviveARenameAndAreNotRedone() async throws {
        try SyntheticMedia.writeAudioFile(to: file("music/a.wav"), segments: [(1, 0.25)])
        var a = try await item("music/a.wav")
        let analysis = analysis()
        await analysis.waitFor(.waveform, for: a)
        XCTAssertNil(analysis.submit(.waveform, for: a), "cached, nothing to do")

        try FileManager.default.moveItem(at: file("music/a.wav"), to: file("music/renamed.wav"))
        let scanned = try await MediaScanner.scan(folder, known: [a])
        a = try XCTUnwrap(scanned.first)
        XCTAssertEqual(a.path, "music/renamed.wav")
        XCTAssertNotNil(analysis.waveform(for: a))

        // New content means a new result.
        try SyntheticMedia.writeAudioFile(to: file("music/renamed.wav"), segments: [(2, 0.25)])
        let changed = try await MediaScanner.scan(folder, known: [a])
        XCTAssertNil(analysis.waveform(for: try XCTUnwrap(changed.first)))
    }

    func testFingerprintIsComputedForItemsWithoutOne() async throws {
        try SyntheticMedia.writeAudioFile(to: file("sfx/ping.wav"), segments: [(0.5, 0.5)])
        var ping = try await item("sfx/ping.wav")
        ping.fingerprint = nil
        let analysis = analysis()
        await analysis.waitFor(.loudness, for: ping)
        XCTAssertNotNil(analysis.loudness(for: ping))
    }

    func testNotApplicableAndUnreadable() async throws {
        let analysis = analysis()
        let music = MediaItem(path: "music/missing.mp3", kind: .audio, role: .music, hasAudio: true)
        XCTAssertEqual(analysis.state(.matte, for: music), .notApplicable)
        XCTAssertEqual(analysis.state(.waveform, for: music), .unreadable)
        XCTAssertNil(analysis.submit(.waveform, for: music))
    }

    func testCancelAllStopsWorkAndLeavesNoHalfResults() async throws {
        try await SyntheticMedia.writeMovie(to: file("source/long-camera.mov"), .init(width: 320, height: 180, duration: 20, audio: nil))
        let camera = try await item("source/long-camera.mov")
        let analysis = analysis()
        let running = expectation(description: "matte running")
        running.assertForOverFulfill = false
        let token = analysis.observe { jobs in
            if jobs.contains(where: { $0.kind == .matte && $0.state == .running && $0.progress > 0 }) { running.fulfill() }
        }
        let id = try XCTUnwrap(analysis.submit(.matte, for: camera, priority: .interactive))
        await fulfillment(of: [running], timeout: 20)
        analysis.cancelAll()
        let final = await analysis.scheduler.wait(for: id)
        analysis.removeObserver(token)
        XCTAssertEqual(final?.state, .cancelled)
        XCTAssertEqual(analysis.state(.matte, for: camera), .missing)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: analysis.cache.root.appendingPathComponent("matte").path)) ?? []
        XCTAssertEqual(leftovers, [])
    }
}

final class TranscriptTests: TempFolderTestCase {
    func testSpokenWordsComeBackWithMediaTimes() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let url = file("source/said-camera.wav")
        let spoken = try await SyntheticMedia.writeSpeech("Convex keeps every word of the take in sync with the timeline.", to: url, leadIn: 1.5)
        try XCTSkipUnless(spoken, "no system voice to make test speech with")
        let folder = ProjectFolder(root: temp)
        let item = try await MediaScanner.probe(url, folder: folder)
        let analysis = MediaAnalysis(folder: folder, encoderLock: EncoderLock())
        let state = await analysis.waitFor(.transcript, for: item)
        XCTAssertEqual(state, .ready)

        let transcript = try XCTUnwrap(analysis.transcript(for: item))
        XCTAssertEqual(transcript.engine, "SpeechAnalyzer")
        XCTAssertEqual(transcript.language, "en-US")
        let words = transcript.words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        XCTAssertTrue(words.contains("every"), words.description)
        XCTAssertTrue(words.contains("timeline"), words.description)
        let first = try XCTUnwrap(transcript.words.first)
        XCTAssertEqual(first.start.seconds, 1.5, accuracy: 0.1, "the lead-in silence is in media time, not in the word")
        for (a, b) in zip(transcript.words, transcript.words.dropFirst()) {
            XCTAssertLessThanOrEqual(a.start, b.start)
            XCTAssertLessThanOrEqual(a.start, a.end)
        }
        XCTAssertLessThanOrEqual(transcript.words.last!.end.seconds, item.duration!.seconds + 0.05)
    }
}

final class EncodedMovieWriterTests: TempFolderTestCase {
    func testKeepsTimesAndDurationsAndSkipsARepeatedTime() async throws {
        let url = file("out.mov")
        let writer = try EncodedMovieWriter(url: url, settings: .init(width: 64, height: 64, timescale: 600))
        let times: [Int64] = [0, 20, 20, 50, 400]
        for (index, time) in times.enumerated() {
            let frame = try SyntheticMedia.makeFrame(width: 64, height: 64, index: index, pool: nil)
            try writer.append(frame, at: CMTime(value: time, timescale: 600))
        }
        try await writer.finish(endTime: CMTime(value: 430, timescale: 600))
        XCTAssertEqual(writer.framesDropped, 1)
        let written = try await videoSampleTimes(url).map(\.value)
        XCTAssertEqual(written, [0, 20, 50, 400])
        let range = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0].load(.timeRange)
        XCTAssertEqual(range.end, CMTime(value: 430, timescale: 600), "the last frame lasts until the end time")
    }
}

final class PCMFillTests: XCTestCase {
    let samples: [Float] = [0.5, -0.5, 0.25, -0.25, 1.5, -1.5]  // three stereo frames

    func testInterleavedAndPlanarInt16() throws {
        for interleaved in [true, false] {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: interleaved)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
            try samples.withUnsafeBufferPointer { try PCMFill.fill(buffer, from: $0.baseAddress!, frames: 3) }
            XCTAssertEqual(buffer.frameLength, 3)
            let data = buffer.int16ChannelData!
            let left = interleaved ? [data[0][0], data[0][2], data[0][4]] : [data[0][0], data[0][1], data[0][2]]
            let right = interleaved ? [data[0][1], data[0][3], data[0][5]] : [data[1][0], data[1][1], data[1][2]]
            XCTAssertEqual(left, [16_384, 8192, 32_767], "clipped at full scale")
            XCTAssertEqual(right, [-16_384, -8192, -32_768])
        }
    }

    func testPlanarFloat32() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        try samples.withUnsafeBufferPointer { try PCMFill.fill(buffer, from: $0.baseAddress!, frames: 3) }
        XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: 3)), [-0.5, -0.25, -1.5])
    }
}

final class SpeechEnvelopeTests: XCTestCase {
    func testWordEdgesMoveInToTheVoice() {
        // 1 s quiet, 1 s voice, 1 s quiet, 1 s voice at 16 kHz.
        let rate = 16_000.0
        var samples: [Float] = []
        for second in 0..<4 {
            let loud = second % 2 == 1
            for i in 0..<Int(rate) {
                samples.append(loud ? Float(0.3 * sin(2 * Double.pi * 200 * Double(i) / rate)) : Float(0.0005 * sin(Double(i))))
            }
        }
        var envelope = SpeechEnvelope(origin: 10, sampleRate: rate)
        samples.withUnsafeBufferPointer { all in
            // Arrives in uneven chunks, stamped in media time.
            var offset = 0
            for size in [1000, 7000, 24_000, 32_000] {
                envelope.add(UnsafeBufferPointer(rebasing: all[offset..<(offset + size)]), at: 10 + Double(offset) / rate)
                offset += size
            }
        }
        let words = [
            TranscriptWord(text: "first", start: Time(seconds: 10.2), end: Time(seconds: 12.0)),
            TranscriptWord(text: "second", start: Time(seconds: 12.0), end: Time(seconds: 14.0)),
            TranscriptWord(text: "tight", start: Time(seconds: 13.2), end: Time(seconds: 13.5))
        ]
        let snapped = envelope.snap(words)
        XCTAssertEqual(snapped[0].start.seconds, 10.98, accuracy: 0.011)
        XCTAssertEqual(snapped[0].end.seconds, 12.0, accuracy: 0.001, "voice right to the end: unchanged")
        XCTAssertEqual(snapped[1].start.seconds, 12.98, accuracy: 0.011)
        XCTAssertEqual(snapped[2], words[2], "a word that's all voice stays as it was")
        let pauses = Transcript(language: "en-US", engine: "test", words: Array(snapped.prefix(2))).pauses(longerThan: Time(seconds: 0.5))
        XCTAssertEqual(pauses.count, 1)
    }
}
