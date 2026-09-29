import AVFoundation
import CoreImage
import XCTest
import TandemCore
@testable import TandemMedia
@testable import TandemRender

/// Stickers and overlays with alpha (HEVC with alpha, ProRes 4444) keep
/// their transparency through the compositor, and through the scrub
/// proxies the viewer plays.
final class AlphaVideoTests: XCTestCase {
    func testHEVCWithAlphaOverlaysTheTrackBelow() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 1, draw: { TestMedia.fill($1, 1, 0, 0) })
        // HEVC with alpha: left half opaque blue, right half transparent.
        let url = media.folder.appendingPathComponent("sticker.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<180 { for x in 0..<320 { let o = y * row + x * 4
                if x < 160 { base[o] = 255; base[o+1] = 0; base[o+2] = 0; base[o+3] = 255 } else { base[o] = 0; base[o+1] = 0; base[o+2] = 0; base[o+3] = 0 } } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30)); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
        var sticker = media.item("med_k", "sticker.mov", role: .sticker, seconds: 1)
        sticker.hasAlpha = true
        let project = smallProject(video: [
            Track(kind: .video, name: "V1", clips: [Clip(id: "clip_r", content: .media(mediaID: "med_r"), start: .zero, duration: t(1))]),
            Track(kind: .video, name: "V2", clips: [Clip(id: "clip_k", content: .media(mediaID: "med_k"), start: .zero, duration: t(1))])
        ], media: [media.item("med_r", "red.mov", seconds: 1), sticker])
        let frame = Bitmap(try await FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder)).image(at: t(0.5)))
        assertColor(frame[80, 90], [0, 0, 255], tolerance: 16)
        assertColor(frame[240, 90], [255, 0, 0], tolerance: 8)
    }

    /// An overlay bigger than 1080p on the timeline gets a scrub proxy, and
    /// the viewer plays from it: the track below has to show through the
    /// proxy as it does through the original (exports, paused frames).
    /// ProRes 4444 and a QuickTime Animation sticker (by way of its
    /// converted copy) have straight alpha, HEVC with alpha from
    /// AVAssetWriter premultiplied.
    func testTheTrackBelowShowsThroughTheProxyOfABigOverlay() async throws {
        for codec in ["prores", "hevc", "qtrle"] {
            let media = try TestMedia()
            try await media.movie("blue.mov", seconds: 0.5, draw: { TestMedia.fill($1, 0, 0, 1) })
            let url = try await media.alphaOverlay("overlay.mov", codec: codec, width: 2400, height: 1350, seconds: 0.5)
            let overlay = try await MediaScanner.probe(url, folder: media.projectFolder, id: "med_over")
            XCTAssertTrue(overlay.hasAlpha, codec)
            let project = smallProject(video: [
                Track(kind: .video, name: "V1", clips: [Clip(id: "clip_bg", content: .media(mediaID: "med_bg"), start: .zero, duration: t(0.5))]),
                Track(kind: .video, name: "V2", clips: [Clip(id: "clip_over", content: .media(mediaID: "med_over"), start: .zero, duration: t(0.5))])
            ], media: [media.item("med_bg", "blue.mov", seconds: 0.5), overlay])
            XCTAssertTrue(AnalysisNeeds.needs(for: project).contains { $0.mediaID == "med_over" && $0.kind == .proxy }, "bigger than 1080p, \(codec)")
            let analysis = MediaAnalysis(folder: media.projectFolder, encoderLock: EncoderLock())
            let state = await analysis.waitFor(.proxy, for: overlay)
            XCTAssertEqual(state, .ready, codec)
            XCTAssertNotNil(analysis.proxyURL(for: overlay), codec)

            for useProxies in [false, true] {
                let what = "\(codec) \(useProxies ? "proxy" : "original")"
                let context = RenderContext(project: project, folder: media.projectFolder, analysis: analysis, useProxies: useProxies)
                let frame = Bitmap(try await FrameRenderer(context: context).image(at: t(0.25)))
                assertColor(frame[53, 90], [255, 255, 255], tolerance: 12, what)
                assertColor(frame[160, 90], [128, 128, 255], tolerance: 16, "half alpha over blue, \(what)")
                assertColor(frame[266, 90], [0, 0, 255], tolerance: 12, "the track below shows through, \(what)")
            }
            // The viewer's player, whose compositor writes 4:2:0.
            let playing = try await playerFrame(RenderContext(project: project, folder: media.projectFolder, analysis: analysis, useProxies: true), at: t(0.25))
            assertColor(playing[53, 90], [255, 255, 255], tolerance: 12, "\(codec) playing")
            assertColor(playing[160, 90], [128, 128, 255], tolerance: 16, "half alpha over blue, \(codec) playing")
            assertColor(playing[266, 90], [0, 0, 255], tolerance: 12, "the track below shows through, \(codec) playing")
        }
    }

    /// The frame a paused player shows at `time`, built as the viewer
    /// builds it.
    func playerFrame(_ context: RenderContext, at time: Time) async throws -> Bitmap {
        let built = try await CompositionBuilder.build(context)
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil) }
        await player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if output.hasNewPixelBuffer(forItemTime: time.cmTime), let pixels = output.copyPixelBuffer(forItemTime: time.cmTime, itemTimeForDisplay: nil) {
                return Bitmap(CIImage(cvPixelBuffer: pixels), size: built.renderSize)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return try XCTUnwrap(nil, "the player showed nothing at \(time.seconds) s")
    }
}

extension TestMedia {
    /// Half a second or so of overlay with alpha at 30 fps: the left third
    /// opaque white, the middle third white at half alpha, the right third
    /// clear. White, so it looks the same whichever YCbCr matrix a decoder
    /// guesses for these untagged files. `prores` (ProRes 4444) and `qtrle`
    /// (QuickTime Animation, which macOS can't decode) come from ffmpeg
    /// with straight alpha; `hevc` (HEVC with alpha) from AVAssetWriter,
    /// premultiplied. Skips the test when ffmpeg isn't installed.
    func alphaOverlay(_ name: String, codec: String, width: Int, height: Int, seconds: Double) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        guard codec != "hevc" else {
            try await writeHEVCWithAlpha(to: url, width: width, height: height, frames: Int(seconds * 30))
            return url
        }
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let encoder = codec == "qtrle"
            ? ["-c:v", "qtrle", "-pix_fmt", "argb"]
            : ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-alpha_bits", "16"]
        try ffmpeg.run([
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "color=c=white:s=\(width)x\(height):d=\(seconds):r=30,format=rgba,geq=r='255':g='255':b='255':a='if(lt(X,W/3),255,if(lt(X,2*W/3),128,0))'"
        ] + encoder + [url.path])
        return url
    }

    private func writeHEVCWithAlpha(to url: URL, width: Int, height: Int, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(writer.error as Any)")
        writer.startSession(atSourceTime: .zero)
        // One premultiplied BGRA row, copied down every frame.
        var row = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<(2 * width / 3) {
            let value: UInt8 = x < width / 3 ? 255 : 128
            for c in 0..<4 { row[x * 4 + c] = value }
        }
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &created)
            let buffer = try XCTUnwrap(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            row.withUnsafeBytes { bytes in
                for y in 0..<height { (base + y * stride).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
    }
}
