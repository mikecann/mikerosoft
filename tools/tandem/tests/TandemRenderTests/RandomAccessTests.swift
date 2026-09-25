import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Exact frames from files AVFoundation can't seek in cleanly: open-GOP
/// HEVC that has lost its `sync` sample group (as ffmpeg remuxes do) and
/// variable frame rate recordings with long gaps. The frame at t is always
/// the last one at or before t, never black.
final class RandomAccessTests: XCTestCase {
    /// Presentation time of each frame: 60 frames at 30 fps, a gap to 12 s
    /// (a static screen), then 30 more.
    static let times: [Double] = (0..<60).map { Double($0) / 30 } + (0..<30).map { 12 + Double($0) / 30 }

    /// Writes the frames with the hardware HEVC encoder (open GOPs, frame
    /// reordering, a keyframe every 60 frames, so frame 60 at 12 s is a
    /// keyframe whose leading frames are 57 to 59, shown before the gap).
    func openGOPMovie(_ media: TestMedia, name: String, stripSyncGroup: Bool) async throws -> URL {
        let url = media.folder.appendingPathComponent(name)
        let encoder = try VideoEncoder(size: CGSize(width: 320, height: 180), codec: .hevc, bitrate: 2_000_000, fps: .fps30)
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ] as CFDictionary, &pool)
        for (index, seconds) in Self.times.enumerated() {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer!), width: 320, height: 180, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            context.translateBy(x: 0, y: 180)
            context.scaleBy(x: 1, y: -1)
            TestMedia.drawIndex(index, context)
            // Some motion, so the encoder uses B-frames.
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: CGFloat(index * 3 % 300), y: 120, width: 20, height: 20))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            encoder.encode(buffer!, at: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(value: 20, timescale: 600))
        }
        encoder.finish()
        let hint = try XCTUnwrap(encoder.waitForFormat())
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        while let sample = encoder.nextEncoded() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            input.append(sample)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 13, timescale: 1))
        await writer.finishWriting()
        encoder.invalidate()
        XCTAssertEqual(writer.status, .completed)
        if stripSyncGroup { try Self.neutraliseBoxes(["sgpd", "sbgp", "cslg"], in: url) }
        return url
    }

    /// Renames boxes to `free`, which players skip: the file then looks
    /// like one remuxed without its HEVC sync sample group.
    static func neutraliseBoxes(_ types: Set<String>, in url: URL) throws {
        var data = try Data(contentsOf: url)
        func walk(_ start: Int, _ end: Int) {
            var position = start
            while position + 8 <= end {
                let size = Int(data[position..<position + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard size >= 8, position + size <= end else { return }
                let type = String(decoding: data[position + 4..<position + 8], as: UTF8.self)
                if ["moov", "trak", "mdia", "minf", "stbl"].contains(type) { walk(position + 8, position + size) }
                if types.contains(type) { data.replaceSubrange(position + 4..<position + 8, with: Data("free".utf8)) }
                position += size
            }
        }
        walk(0, data.count)
        try data.write(to: url)
    }

    func project(_ media: TestMedia, file: String) -> Project {
        let item = MediaItem(id: "med_s", path: file, kind: .video, role: .screen, duration: t(13), frameRate: .fps30,
                             width: 320, height: 180, hasVideo: true, variableFrameRate: true)
        let clip = Clip(id: "clip_s", content: .media(mediaID: "med_s"), start: .zero, duration: t(13))
        return smallProject(video: [Track(kind: .video, name: "Screen", clips: [clip])], media: [item])
    }

    /// Timeline time to expected frame index: the last frame at or before it.
    static func expectedIndex(at seconds: Double) -> Int {
        (times.lastIndex { $0 <= seconds + 1e-6 }) ?? 0
    }

    let whole = CGRect(x: 0, y: 0, width: 320, height: 90)
    /// Before and in the leading frames, deep in the gap, and around the
    /// keyframe after it.
    let probeTimes = [1.0, 1.88, 1.91, 1.95, 1.99, 2.5, 7.0, 11.9, 12.0, 12.05, 12.9]

    func testFrameGrabsFromRemuxedOpenGOPWithAGap() async throws {
        let media = try TestMedia()
        _ = try await openGOPMovie(media, name: "remuxed.mov", stripSyncGroup: true)
        let renderer = FrameRenderer(context: RenderContext(project: project(media, file: "remuxed.mov"), folder: media.projectFolder))
        for seconds in probeTimes {
            let frame = Bitmap(try await renderer.image(at: t(seconds)))
            XCTAssertEqual(TestMedia.readIndex(frame, in: whole), Self.expectedIndex(at: seconds), "at \(seconds) s")
        }
    }

    func testTheSameFramesFromAFileWithItsSyncGroup() async throws {
        let media = try TestMedia()
        _ = try await openGOPMovie(media, name: "clean.mov", stripSyncGroup: false)
        let renderer = FrameRenderer(context: RenderContext(project: project(media, file: "clean.mov"), folder: media.projectFolder))
        for seconds in probeTimes {
            let frame = Bitmap(try await renderer.image(at: t(seconds)))
            XCTAssertEqual(TestMedia.readIndex(frame, in: whole), Self.expectedIndex(at: seconds), "at \(seconds) s")
        }
    }

    func testRecoveryDecodesLeadingFramesDirectly() async throws {
        let media = try TestMedia()
        let url = try await openGOPMovie(media, name: "remuxed.mov", stripSyncGroup: true)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let source = SourceTrack(url: url, asset: asset, track: track, timeRange: try await track.load(.timeRange))
        let recovery = FrameRecovery()
        // Out of order, as scrubbing does: fresh readers and continuations.
        for seconds in [7.0, 1.95, 1.99, 12.9, 12.05, 0.0, 30.0] {
            let pixels = try XCTUnwrap(recovery.frame(source, at: CMTime(seconds: seconds, preferredTimescale: 600)), "at \(seconds)")
            let frame = Bitmap(CIImage(cvPixelBuffer: pixels), size: CGSize(width: 320, height: 180))
            XCTAssertEqual(TestMedia.readIndex(frame, in: whole), Self.expectedIndex(at: min(seconds, 12.97)), "at \(seconds) s")
        }
    }

    func testAPausedPlayerShowsLeadingFrames() async throws {
        let media = try TestMedia()
        _ = try await openGOPMovie(media, name: "remuxed.mov", stripSyncGroup: true)
        let built = try await CompositionBuilder.build(RenderContext(project: project(media, file: "remuxed.mov"), folder: media.projectFolder))
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for seconds in [1.95, 7.0] {
            let target = CMTime(seconds: seconds, preferredTimescale: 600)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            var pixels: CVPixelBuffer?
            let deadline = Date().addingTimeInterval(5)
            while pixels == nil && Date() < deadline {
                if output.hasNewPixelBuffer(forItemTime: target) {
                    pixels = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil)
                }
                if pixels == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            }
            let frame = Bitmap(CIImage(cvPixelBuffer: try XCTUnwrap(pixels, "no frame at \(seconds)")), size: CGSize(width: 320, height: 180))
            XCTAssertEqual(TestMedia.readIndex(frame, in: whole), Self.expectedIndex(at: seconds), "at \(seconds) s")
        }
    }

    func testACutIntoLeadingFramesExportsThem() async throws {
        let media = try TestMedia()
        _ = try await openGOPMovie(media, name: "remuxed.mov", stripSyncGroup: true)
        // A clip that starts on a leading frame, after one elsewhere.
        let first = Clip(id: "clip_a", content: .media(mediaID: "med_s"), start: .zero, duration: t(0.5), sourceStart: t(12.2))
        let second = Clip(id: "clip_b", content: .media(mediaID: "med_s"), start: t(0.5), duration: t(0.5), sourceStart: t(1.9))
        var project = project(media, file: "remuxed.mov")
        project.videoTracks[0].clips = [first, second]
        let out = media.folder.appendingPathComponent("cut.mp4")
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder),
                               preset: ExportPreset(name: "t", codec: .h264, videoBitrate: 4_000_000, loudnessTarget: nil), output: out).run()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (seconds, expected) in [(0.5, 57), (0.54, 58), (0.57, 59), (0.9, 59)] {
            let frame = Bitmap(try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image)
            XCTAssertEqual(TestMedia.readIndex(frame, in: whole), expected, "at \(seconds) s")
        }
    }
}
