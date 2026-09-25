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

    func analysis() -> MediaAnalysis {
        MediaAnalysis(folder: folder, encoderLock: EncoderLock())
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

    func testProxyIsSmallerAllIntraAndKeepsEveryTimestamp() async throws {
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
        let size = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))

        let sourceTimes = try await videoSampleTimes(file("source/demo-screen.mov"))
        let proxyTimes = try await videoSampleTimes(proxy)
        XCTAssertEqual(proxyTimes.count, sourceTimes.count)
        for (a, b) in zip(sourceTimes, proxyTimes) { XCTAssertEqual(CMTimeCompare(a, b), 0, "\(a.seconds) vs \(b.seconds)") }

        let cursor = try XCTUnwrap(tracks[0].makeSampleCursorAtFirstSampleInDecodeOrder())
        var keyframes = 0
        repeat { if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { keyframes += 1 } } while cursor.stepInDecodeOrder(byCount: 1) == 1
        XCTAssertEqual(keyframes, sourceTimes.count, "all-intra")

        let sourceEnd = try await AVURLAsset(url: file("source/demo-screen.mov")).loadTracks(withMediaType: .video)[0].load(.timeRange).end
        let proxyEnd = try await tracks[0].load(.timeRange).end
        XCTAssertEqual(proxyEnd.seconds, sourceEnd.seconds, accuracy: 0.001, "the last frame lasts as long as in the source")
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
