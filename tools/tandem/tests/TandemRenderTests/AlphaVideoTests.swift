import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Stickers and overlays with alpha (HEVC with alpha, ProRes 4444) keep
/// their transparency through the compositor.
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
}
