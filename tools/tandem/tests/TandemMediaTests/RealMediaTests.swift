import Accelerate
import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

/// Checks and timings on Mike's real footage (read only). Opt-in:
///
///     TANDEM_REAL_MEDIA=1 swift test -c release -Xswiftc -enable-testing \
///       --package-path tools/tandem --filter RealMediaTests
///
/// Add TANDEM_REAL_MEDIA_FULL=1 for the whole-take transcript. Results and
/// timings go to /private/tmp/claude-501/tandem-media/real/.
final class RealMediaTests: XCTestCase {
    static let project = URL(fileURLWithPath: NSString(string: "~/dev/convex/convex-videos/decision-models").expandingTildeInPath)
    static let camera = project.appendingPathComponent("edit/main-camera.mov")
    static let screen = project.appendingPathComponent("edit/main-screen.mov")
    static let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/tandem-media/real")
    /// The minute with the most speech, as in the spikes.
    static let minute = CMTimeRange(start: CMTime(seconds: 1010, preferredTimescale: 600), duration: CMTime(seconds: 60, preferredTimescale: 600))

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_REAL_MEDIA"] == "1", "set TANDEM_REAL_MEDIA=1 to run the real footage tests")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.camera.path), "decision-models footage isn't on this Mac")
        try FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
    }

    func report(_ line: String) {
        print("REAL \(line)")
        let url = Self.scratch.appendingPathComponent("report.txt")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }

    func output(_ name: String) throws -> URL {
        let url = Self.scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func context(_ kind: AnalysisKind, qos: DispatchQoS.QoSClass = .utility) -> JobContext {
        JobContext(id: "real-\(kind.rawValue)", kind: kind, qos: qos, scheduler: nil)
    }

    func item(_ url: URL) async throws -> MediaItem {
        try await MediaScanner.probe(url, folder: ProjectFolder(root: Self.project))
    }

    func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = Date()
        let value = try await body()
        return (value, Date().timeIntervalSince(start))
    }

    // MARK: - Scanning

    func testScanTheDecisionModelsFolder() async throws {
        let folder = ProjectFolder(root: Self.project)
        let (report, seconds) = try await time { try await MediaScanner.scanReport(folder, known: []) }
        let (again, rescanSeconds) = try await time { try await MediaScanner.scanReport(folder, known: report.items) }
        self.report(String(format: "scan decision-models: %d media, %d skipped, %d notes in %.2f s; rescan with known items %.2f s", report.items.count, report.skipped.count, report.notes.count, seconds, rescanSeconds))
        for note in report.notes { self.report("  note: \(note)") }
        for skipped in report.skipped { self.report("  skipped: \(skipped.path): \(skipped.reason)") }
        XCTAssertEqual(Set(again.items.map(\.id)), Set(report.items.map(\.id)))

        let byPath = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0) })
        let camera = try XCTUnwrap(byPath["edit/main-camera.mov"])
        let screen = try XCTUnwrap(byPath["edit/main-screen.mov"])
        XCTAssertEqual(camera.role, .camera)
        XCTAssertEqual(screen.role, .screen)
        XCTAssertEqual(camera.width, 3840)
        XCTAssertEqual(camera.height, 2160)
        XCTAssertEqual(camera.frameRate, FrameRate(30))
        XCTAssertFalse(camera.variableFrameRate, "7 dropped frames don't make the camera VFR")
        XCTAssertTrue(screen.variableFrameRate)
        XCTAssertEqual(screen.frameRate, FrameRate(30))
        XCTAssertNotNil(camera.takeID)
        XCTAssertEqual(camera.takeID, screen.takeID)
        XCTAssertEqual(byPath["source/2026-09-24_102826-camera.mov"]?.takeID, byPath["source/2026-09-24_102826-screen.mov"]?.takeID)
        XCTAssertNotNil(byPath["source/2026-09-24_102826-camera.mov"]?.takeID)
        XCTAssertEqual(byPath["music/c1a.mp3"]?.role, .music)
        XCTAssertEqual(byPath["broll/hf-decider.mp4"]?.role, .broll)
        XCTAssertNil(report.items.first { $0.path.contains("node_modules") || $0.path.hasSuffix(".wfp.dir") })
        self.report("  camera \(camera.duration!) \(camera.frameRate!.framesPerSecond) fps VFR \(camera.variableFrameRate); screen \(screen.duration!) VFR \(screen.variableFrameRate); take offsets \(camera.takeOffset!.seconds) / \(screen.takeOffset!.seconds)")
    }

    // MARK: - Loudness and waveform

    func ffmpegLoudness(_ url: URL) throws -> (integrated: Double, range: Double, peak: Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-nostats", "-hide_banner", "-i", url.path, "-vn", "-af", "ebur128=peak=true", "-f", "null", "-"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "") + ":\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin"
        process.environment = environment
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let summary = text.components(separatedBy: "Summary:").last ?? ""
        func value(_ label: String) -> Double? {
            guard let range = summary.range(of: "\(label):") else { return nil }
            return Double(summary[range.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
        }
        return (try XCTUnwrap(value("I")), try XCTUnwrap(value("LRA")), try XCTUnwrap(value("Peak")))
    }

    func testLoudnessMatchesFFmpeg() async throws {
        for url in [Self.camera, Self.project.appendingPathComponent("music/c1a.mp3"), Self.project.appendingPathComponent("broll/hf-decider.mp4")] {
            let asset = AVURLAsset(url: url)
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { continue }
            let (ours, seconds) = try await time { try await LoudnessJob.measure(source: url, context: context(.loudness)) }
            let theirs = try ffmpegLoudness(url)
            report(String(format: "loudness %@: ours I %.2f LUFS, LRA %.2f LU, TP %.2f dBTP in %.2f s; ffmpeg I %.1f, LRA %.1f, TP %.1f",
                          url.lastPathComponent, ours.integratedLUFS, ours.loudnessRange, ours.truePeakDBTP, seconds, theirs.integrated, theirs.range, theirs.peak))
            XCTAssertEqual(ours.integratedLUFS, theirs.integrated, accuracy: 0.2, url.lastPathComponent)
            XCTAssertEqual(ours.truePeakDBTP, theirs.peak, accuracy: 0.5, url.lastPathComponent)
            XCTAssertEqual(ours.loudnessRange, theirs.range, accuracy: 1.0, url.lastPathComponent)
        }
    }

    func testWaveformAndThumbnailsOfTheWholeCamera() async throws {
        let camera = try await item(Self.camera)
        let waveformFolder = try output("waveform")
        let (_, waveformSeconds) = try await time {
            try await WaveformJob.run(source: Self.camera, rate: 100, into: waveformFolder, context: context(.waveform))
        }
        let waveform = try XCTUnwrap(WaveformJob.read(from: waveformFolder))
        report(String(format: "waveform main-camera (%.0f s): %d peaks in %.2f s", camera.duration!.seconds, waveform.peaks.count, waveformSeconds))
        XCTAssertEqual(Double(waveform.peaks.count), camera.duration!.seconds * 100, accuracy: 2)

        let thumbnailFolder = try output("thumbnails")
        let (_, thumbnailSeconds) = try await time {
            try await ThumbnailJob.run(source: Self.camera, kind: .video, interval: 2, width: 320, into: thumbnailFolder, context: context(.thumbnails))
        }
        let strip = try XCTUnwrap(ThumbnailJob.read(from: thumbnailFolder))
        let bytes = AnalysisCache.folderSize(thumbnailFolder)
        report(String(format: "thumbnails main-camera: %d JPEGs %dx%d, %.1f MB in %.2f s", strip.files.count, strip.width, strip.height, Double(bytes) / 1e6, thumbnailSeconds))
        XCTAssertEqual(strip.files.count, Int((camera.duration!.seconds / 2).rounded(.up)))
    }

    // MARK: - Proxies

    /// Presentation times of every video sample in movie time: sample-table
    /// times moved by the track's edit list (a proxy of a range starts with
    /// an empty edit up to the range).
    func movieTimes(_ url: URL) async throws -> [CMTime] {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        let segments = try await track.load(.segments)
        let mapping = try XCTUnwrap(segments.first { !$0.isEmpty }?.timeMapping)
        let offset = mapping.target.start - mapping.source.start
        let cursor = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        var times: [CMTime] = []
        repeat { times.append(cursor.presentationTimeStamp + offset) } while cursor.stepInDecodeOrder(byCount: 1) == 1
        return times.sorted { CMTimeCompare($0, $1) < 0 }
    }

    /// Checks a derived movie (proxy or matte) has exactly the source's
    /// frames, at exactly the source's times, over the stretch it covers.
    ///
    /// Reading a time range makes AVAssetReader clip the frame that's on
    /// screen at the range start to begin there, so the first frame of a
    /// range build sits at 1010.000 rather than its source time 1009.997.
    /// Whole-file builds (what the app makes) have no such frame.
    func assertSameFrames(_ derived: URL, as source: URL, _ label: String, file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        let ours = try await movieTimes(derived)
        let theirs = try await movieTimes(source)
        let first = try XCTUnwrap(ours.first), last = try XCTUnwrap(ours.last)
        XCTAssertEqual(first.seconds, Self.minute.start.seconds, accuracy: 0.0001, "\(label): starts at the range start", file: file, line: line)
        let rest = Array(ours.dropFirst())
        let window = theirs.filter { CMTimeCompare($0, first) > 0 && CMTimeCompare($0, last) <= 0 }
        XCTAssertEqual(rest.count, window.count, "\(label): frame count", file: file, line: line)
        XCTAssertEqual(zip(rest, window).filter { CMTimeCompare($0, $1) != 0 }.count, 0, "\(label): every frame at its source time", file: file, line: line)
        XCTAssertGreaterThanOrEqual(last.seconds, Self.minute.end.seconds - 0.2, label, file: file, line: line)
        return ours.count
    }

    func testProxiesOfAMinute() async throws {
        let settings = AnalysisSettings()
        for (name, url, qos) in [("camera", Self.camera, DispatchQoS.QoSClass.utility), ("screen", Self.screen, .utility), ("camera-background-qos", Self.camera, .background)] {
            let folder = try output("proxy-\(name)")
            let (_, seconds) = try await time {
                try await ProxyJob.run(source: url, settings: settings, into: folder, context: context(.proxy, qos: qos), timeRange: Self.minute)
            }
            let frames = try await assertSameFrames(folder.appendingPathComponent(ProxyJob.file), as: url, name)
            let bytes = AnalysisCache.folderSize(folder)
            report(String(format: "proxy %@ 60 s: %d frames in %.2f s = %.0f fps, %.1f MB (%.1f Mbps)", name, frames, seconds, Double(frames) / seconds, Double(bytes) / 1e6, Double(bytes) * 8 / 60 / 1e6))
        }
    }

    // MARK: - Matte

    func testMatteOfAMinute() async throws {
        let folder = try output("matte")
        let settings = AnalysisSettings()
        let (_, seconds) = try await time {
            try await MatteJob.run(source: Self.camera, settings: settings, into: folder, context: context(.matte), timeRange: Self.minute)
        }
        let matte = folder.appendingPathComponent(MatteJob.file)
        let frames = try await assertSameFrames(matte, as: Self.camera, "matte")
        let bytes = AnalysisCache.folderSize(folder)
        report(String(format: "matte camera 60 s (version 2: accurate + subject, steadied, %d workers): %d frames in %.2f s = %.1f fps (a 24 min take: %.1f min), %.1f MB",
                      MatteJob.workers, frames, seconds, Double(frames) / seconds, 43_376 / (Double(frames) / seconds) / 60, Double(bytes) / 1e6))

        // Stills of the matte and a cutout over blue for looking at.
        for t in [1015.0, 1040.0, 1065.0] {
            try await exportCutout(matte: matte, at: t, to: Self.scratch.appendingPathComponent("matte/cutout_\(Int(t)).png"))
        }
    }

    /// Version 2 and RVM (its model must already be in place) against
    /// version 1 on 20 s of the camera: the matte's
    /// average frame-to-frame change (every 4th pixel), moving hands
    /// included. docs/MEDIA.md has the finer score, where the picture is
    /// still.
    func testMatteIsSteadierThanVersion1() async throws {
        let range = CMTimeRange(start: CMTime(seconds: 1010, preferredTimescale: 600), duration: CMTime(seconds: 20, preferredTimescale: 600))
        var change: [String: Double] = [:]
        for (name, settings) in [("version-1", AnalysisSettings(matteProps: .personInstances, matteSmoothing: .off)),
                                 ("version-2-per-frame", AnalysisSettings(matteSmoothing: .off)),
                                 ("version-2", AnalysisSettings()),
                                 ("rvm", AnalysisSettings(matteModel: .robustVideoMatting))] {
            let folder = try output("matte-\(name)")
            let (_, seconds) = try await time {
                try await MatteJob.run(source: Self.camera, settings: settings, into: folder, context: context(.matte), timeRange: range)
            }
            let frames = try await matteFrames(folder.appendingPathComponent(MatteJob.file))
            let value = zip(frames, frames.dropFirst()).map { meanDifference($0, $1) }.reduce(0, +) / Double(max(1, frames.count - 1))
            change[name] = value
            report(String(format: "matte %@ 20 s: %.1f fps, frame-to-frame change %.3f", name, Double(frames.count) / seconds, value))
        }
        // Measured 1.65 against 3.41 (moving hands are most of what's left).
        XCTAssertLessThan(try XCTUnwrap(change["version-2"]), try XCTUnwrap(change["version-1"]) * 0.6)
        XCTAssertLessThan(try XCTUnwrap(change["rvm"]), try XCTUnwrap(change["version-1"]) * 0.6)
    }

    /// Luma planes of every frame of a matte, in order.
    func matteFrames(_ url: URL) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        reader.add(output)
        reader.startReading()
        var frames: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            // Every 4th pixel each way is plenty for comparing mattes.
            var plane: [UInt8] = []
            plane.reserveCapacity(width * height / 16)
            for y in Swift.stride(from: 0, to: height, by: 4) { for x in Swift.stride(from: 0, to: width, by: 4) { plane.append(base[y * stride + x]) } }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append(plane)
        }
        return frames
    }

    func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for i in 0..<min(a.count, b.count) { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(max(1, min(a.count, b.count)))
    }

    /// Compares Vision's temporal state handling: several workers sharing
    /// frames (each request sees every third frame), fresh requests every
    /// frame, and one worker in order.
    func testMatteTemporalStateExperiment() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_MATTE_EXPERIMENT"] == "1", "set TANDEM_MATTE_EXPERIMENT=1")
        let range = CMTimeRange(start: CMTime(seconds: 1010, preferredTimescale: 600), duration: CMTime(seconds: 20, preferredTimescale: 600))
        var results: [String: [[UInt8]]] = [:]
        for (name, tuning) in [("shared-a", MatteJob.Tuning(workers: 3, stateless: false)), ("shared-b", MatteJob.Tuning(workers: 3, stateless: false)),
                               ("stateless-a", MatteJob.Tuning(workers: 3, stateless: true)), ("stateless-b", MatteJob.Tuning(workers: 3, stateless: true)),
                               ("in-order", MatteJob.Tuning(workers: 1, stateless: false))] {
            let folder = try output("matte-\(name)")
            let (_, seconds) = try await time {
                try await MatteJob.run(source: Self.camera, settings: AnalysisSettings(), into: folder, context: context(.matte), timeRange: range, tuning: tuning)
            }
            let frames = try await matteFrames(folder.appendingPathComponent(MatteJob.file))
            results[name] = frames
            let flicker = zip(frames, frames.dropFirst()).map { meanDifference($0, $1) }.reduce(0, +) / Double(max(1, frames.count - 1))
            report(String(format: "matte experiment %@: %d frames in %.1f s = %.1f fps, frame-to-frame change %.3f", name, frames.count, seconds, Double(frames.count) / seconds, flicker))
        }
        func compare(_ a: String, _ b: String) -> Double {
            let x = results[a]!, y = results[b]!
            return zip(x, y).map { meanDifference($0, $1) }.reduce(0, +) / Double(min(x.count, y.count))
        }
        report(String(format: "  run to run: shared %.3f, stateless %.3f", compare("shared-a", "shared-b"), compare("stateless-a", "stateless-b")))
        report(String(format: "  against in-order: shared %.3f, stateless %.3f", compare("shared-a", "in-order"), compare("stateless-a", "in-order")))
    }

    /// Composites the camera over blue through the matte at one time.
    func exportCutout(matte: URL, at seconds: Double, to url: URL) async throws {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        func frame(_ source: URL) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 1920, height: 1080)
            return try await generator.image(at: time).image
        }
        let picture = try await frame(Self.camera)
        let mask = try await frame(matte)
        let width = 1920, height = 1080
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.13, green: 0.33, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The matte as a greyscale mask.
        let grey = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        grey.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        let greyMask = grey.makeImage()!
        // A greyscale image clips like alpha: white paints, black doesn't.
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: greyMask)
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Transcript

    func testTranscriptOfAMinute() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        let (transcript, seconds) = try await time {
            try await SpeechTranscription.transcribe(source: Self.camera, localeID: "en-US", context: context(.transcript), timeRange: Self.minute)
        }
        let raw = try await SpeechTranscription.transcribe(source: Self.camera, localeID: "en-US", context: context(.transcript), timeRange: Self.minute, snapWords: false)
        report(String(format: "transcript camera 60 s: %d words in %.2f s = %.0fx realtime", transcript.words.count, seconds, 60 / seconds))
        report("  text: \(transcript.text.prefix(200))...")
        XCTAssertGreaterThan(transcript.words.count, 120)
        XCTAssertGreaterThanOrEqual(transcript.words.first!.start.seconds, 1009.9, "media time, not clip time")

        // Agreement with Whisper medium.en on the same minute (the spike's
        // reference), before and after pulling word edges in to the voice.
        let whisperURL = URL(fileURLWithPath: NSString(string: "~/dev/me/tandem-research/spikes/06-transcription/in60.whisper-medium.en.json").expandingTildeInPath)
        guard let data = try? Data(contentsOf: whisperURL),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let whisper = json["words"] as? [[String: Any]] else { return }
        let reference = whisper.compactMap { entry -> TranscriptWord? in
            guard let text = entry["text"] as? String, let start = entry["start"] as? Double, let end = entry["end"] as? Double else { return nil }
            return TranscriptWord(text: text, start: Time(seconds: start + 1010), end: Time(seconds: end + 1010))
        }
        for (label, words) in [("raw", raw.words), ("snapped", transcript.words)] {
            let pairs = align(words, reference)
            let starts = pairs.map { abs($0.0.start.seconds - $0.1.start.seconds) }.sorted()
            let ends = pairs.map { abs($0.0.end.seconds - $0.1.end.seconds) }.sorted()
            let pauses = Transcript(language: "en-US", engine: "", words: words).pauses(longerThan: Time(seconds: 0.3))
            report(String(format: "  %@ vs whisper medium.en: %d words matched, start diff median %.0f ms p90 %.0f ms, end diff median %.0f ms p90 %.0f ms; %d pauses over 0.3 s totalling %.2f s",
                          label, pairs.count, starts[starts.count / 2] * 1000, starts[starts.count * 9 / 10] * 1000, ends[ends.count / 2] * 1000, ends[ends.count * 9 / 10] * 1000,
                          pauses.count, pauses.reduce(0) { $0 + $1.duration.seconds }))
        }
        let whisperPauses = Transcript(language: "en-US", engine: "", words: reference).pauses(longerThan: Time(seconds: 0.3))
        report(String(format: "  whisper medium.en: %d pauses over 0.3 s totalling %.2f s", whisperPauses.count, whisperPauses.reduce(0) { $0 + $1.duration.seconds }))
    }

    /// Pairs equal words of two transcripts in order (longest common
    /// subsequence on normalised text).
    func align(_ a: [TranscriptWord], _ b: [TranscriptWord]) -> [(TranscriptWord, TranscriptWord)] {
        func norm(_ word: TranscriptWord) -> String { word.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
        let x = a.map(norm), y = b.map(norm)
        var table = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                table[i][j] = x[i] == y[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(TranscriptWord, TranscriptWord)] = []
        var i = 0, j = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] {
                pairs.append((a[i], b[j]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    func testTranscriptOfTheWholeCamera() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_REAL_MEDIA_FULL"] == "1", "set TANDEM_REAL_MEDIA_FULL=1 for the whole take")
        let before = peakMemory()
        let folder = try output("transcript-full")
        let (_, seconds) = try await time {
            try await TranscriptJob.run(source: Self.camera, locale: "en-US", into: folder, context: context(.transcript))
        }
        let transcript = try XCTUnwrap(TranscriptJob.read(from: folder))
        let after = peakMemory()
        report(String(format: "transcript whole camera (1446 s): %d words in %.1f s = %.0fx realtime; peak memory %.0f MB (was %.0f MB before)",
                      transcript.words.count, seconds, 1446 / seconds, after / 1e6, before / 1e6))
        XCTAssertGreaterThan(transcript.words.count, 2000)
        XCTAssertLessThan(after - before, 400e6, "streams instead of loading the take")
    }

    func peakMemory() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss)
    }

    // MARK: - Everything, through the scheduler

    /// A real 43 s record-it take (camera and screen) with every default
    /// analysis, queued at background priority like new footage in the app.
    func testEverythingForAShortTakeThroughTheScheduler() async throws {
        let folder = ProjectFolder(root: try output("project"))
        let camera = try await MediaScanner.probe(Self.project.appendingPathComponent("source/2026-09-24_105238-camera.mov"), folder: folder)
        let screen = try await MediaScanner.probe(Self.project.appendingPathComponent("source/2026-09-24_105238-screen.mov"), folder: folder)
        let analysis = MediaAnalysis(folder: folder, encoderLock: EncoderLock())

        final class Timeline: @unchecked Sendable {
            let lock = NSLock()
            var started: [String: Date] = [:]
            var ended: [String: Date] = [:]
            var labels: [String: String] = [:]
        }
        let timeline = Timeline()
        let token = analysis.observe { jobs in
            timeline.lock.withLock {
                for job in jobs {
                    timeline.labels[job.id] = "\(job.kind.rawValue) \(job.mediaID == camera.id ? "camera" : "screen")"
                    if job.state == .running, timeline.started[job.id] == nil { timeline.started[job.id] = Date() }
                    if [.done, .failed, .cancelled].contains(job.state), timeline.ended[job.id] == nil { timeline.ended[job.id] = Date() }
                }
            }
        }
        let start = Date()
        analysis.requestDefaults(for: [camera, screen], usedOnTimeline: [])
        var ids: [String] = []
        for item in [camera, screen] {
            for kind in MediaAnalysis.defaultKinds(for: item) {
                ids.append(MediaAnalysis.jobID(kind, key: try XCTUnwrap(analysis.cacheKey(kind, for: item))))
            }
        }
        for id in ids { _ = await analysis.scheduler.wait(for: id) }
        let total = Date().timeIntervalSince(start)
        try await Task.sleep(nanoseconds: 200_000_000)
        analysis.removeObserver(token)

        report(String(format: "all defaults for a %.0f s take (camera and screen), background priority: %.1f s", camera.duration!.seconds, total))
        timeline.lock.withLock {
            for (id, label) in timeline.labels.sorted(by: { (timeline.started[$0.key] ?? .distantFuture) < (timeline.started[$1.key] ?? .distantFuture) }) {
                let from = timeline.started[id].map { $0.timeIntervalSince(start) } ?? -1
                let to = timeline.ended[id].map { $0.timeIntervalSince(start) } ?? -1
                report(String(format: "  %@: %.1f s to %.1f s", label, from, to))
            }
        }
        for item in [camera, screen] {
            for kind in MediaAnalysis.defaultKinds(for: item) {
                XCTAssertEqual(analysis.state(kind, for: item), .ready, "\(kind) for \(item.path)")
            }
        }
        XCTAssertNotNil(analysis.transcript(for: camera)?.words.first)
        XCTAssertNotNil(analysis.proxyURL(for: screen))
        report(String(format: "  cache: %.1f MB", Double(analysis.cache.totalSize) / 1e6))
    }

    // MARK: - Isolated voice

    func testIsolatedVoiceOfAMinuteLinesUp() async throws {
        let folder = try output("voice")
        let url = folder.appendingPathComponent(IsolatedVoiceJob.file)
        let (result, seconds) = try await time {
            try await IsolatedVoiceJob.render(source: Self.camera, model: .voice, to: url, context: context(.isolatedVoice), timeRange: Self.minute)
        }
        report(String(format: "isolated voice camera 60 s: %.2f s = %.0fx realtime, latency %d samples, %d frames", seconds, 60 / seconds, result.latency, result.frames))
        XCTAssertEqual(result.frames, 60 * 48_000)

        // Cross-correlate 8 s of speech with the original to find any offset.
        let original = try await monoSamples(Self.camera, range: CMTimeRange(start: CMTime(seconds: 1020, preferredTimescale: 600), duration: CMTime(seconds: 8, preferredTimescale: 600)))
        let voiceFile = try AVAudioFile(forReading: url)
        voiceFile.framePosition = 10 * 48_000
        let buffer = AVAudioPCMBuffer(pcmFormat: voiceFile.processingFormat, frameCapacity: AVAudioFrameCount(original.count))!
        try voiceFile.read(into: buffer, frameCount: AVAudioFrameCount(original.count))
        var voice = [Float](repeating: 0, count: Int(buffer.frameLength))
        for channel in 0..<Int(buffer.format.channelCount) {
            vDSP_vadd(voice, 1, buffer.floatChannelData![channel], 1, &voice, 1, vDSP_Length(voice.count))
        }
        let lag = bestLag(original, voice, maxLag: 5000)
        report("  offset against the original: \(lag) samples")
        XCTAssertLessThanOrEqual(abs(lag), 2)

        // The voice is still there at about the same loudness.
        let before = try await LoudnessJob.measure(source: Self.camera, context: context(.loudness), timeRange: Self.minute)
        let after = try await LoudnessJob.measure(source: url, context: context(.loudness))
        report(String(format: "  loudness of the minute: original %.1f LUFS, isolated %.1f LUFS", before.integratedLUFS, after.integratedLUFS))
        XCTAssertEqual(after.integratedLUFS, before.integratedLUFS, accuracy: 3)

        // A mono source: the unit reports a different latency (2,705), so
        // check that lines up too.
        let monoSource = folder.appendingPathComponent("mono-source.wav")
        let minute = try await monoSamples(Self.camera, range: Self.minute)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: monoSource, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(minute.count))!
            pcm.frameLength = pcm.frameCapacity
            pcm.floatChannelData![0].update(from: minute, count: minute.count)
            try file.write(from: pcm)
        }
        let monoURL = folder.appendingPathComponent("voice-mono.caf")
        let mono = try await IsolatedVoiceJob.render(source: monoSource, model: .voice, to: monoURL, context: context(.isolatedVoice))
        XCTAssertEqual(mono.frames, minute.count)
        let monoFile = try AVAudioFile(forReading: monoURL)
        monoFile.framePosition = 10 * 48_000
        let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFile.processingFormat, frameCapacity: AVAudioFrameCount(original.count))!
        try monoFile.read(into: monoBuffer, frameCount: AVAudioFrameCount(original.count))
        let monoVoice = Array(UnsafeBufferPointer(start: monoBuffer.floatChannelData![0], count: Int(monoBuffer.frameLength)))
        let monoLag = bestLag(Array(minute[(10 * 48_000)..<(10 * 48_000 + original.count)]), monoVoice, maxLag: 5000)
        report("  mono: latency \(mono.latency) samples, offset against the original \(monoLag) samples")
        XCTAssertLessThanOrEqual(abs(monoLag), 2)
    }

    func monoSamples(_ url: URL, range: CMTimeRange) async throws -> [Float] {
        let reader = try await AudioReader(url: url, sampleRate: 48_000, channels: 1, timeRange: range)
        var samples: [Float] = []
        while try reader.next({ chunk, _, _ in samples.append(contentsOf: chunk) }) {}
        return samples
    }

    /// The shift of `b` against `a` (in samples) with the highest correlation.
    func bestLag(_ a: [Float], _ b: [Float], maxLag: Int) -> Int {
        let length = min(a.count, b.count) - 2 * maxLag
        var best = (lag: 0, value: -Float.infinity)
        var padded = [Float](repeating: 0, count: length + 2 * maxLag)
        for i in 0..<min(padded.count, b.count) { padded[i] = b[i] }
        var result = [Float](repeating: 0, count: 2 * maxLag + 1)
        let window = Array(a[maxLag..<(maxLag + length)])
        // result[k] = sum_n padded[n + k] * window[n]: b shifted by k - maxLag.
        vDSP_conv(padded, 1, window, 1, &result, 1, vDSP_Length(2 * maxLag + 1), vDSP_Length(length))
        for (k, value) in result.enumerated() where value > best.value { best = (k - maxLag, value) }
        return best.lag
    }
}
