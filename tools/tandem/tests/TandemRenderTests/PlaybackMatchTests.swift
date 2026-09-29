import AVFoundation
import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// R'G'B' (0...255) of a frame, box-averaged down to a small size and
/// worked out here from the raw planes, using the matrix and range the
/// buffer is tagged with. Core Image's reading of buffers is part of what
/// these tests check, so it isn't used to measure them.
struct Levels {
    let width: Int
    let height: Int
    var rgb: [Double]

    static func fourCC(_ format: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((format >> $0) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Tags and format, for the report.
    static func describe(_ buffer: CVPixelBuffer) -> String {
        let format = fourCC(CVPixelBufferGetPixelFormatType(buffer))
        func tag(_ key: CFString) -> String {
            (CVBufferCopyAttachment(buffer, key, nil) as? String)?.replacingOccurrences(of: "ITU_R_", with: "") ?? "-"
        }
        var space = "-"
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
           let made = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() {
            space = (made.name as String?) ?? "\(made)"
        }
        return "\(format) \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) matrix \(tag(kCVImageBufferYCbCrMatrixKey)) primaries \(tag(kCVImageBufferColorPrimariesKey)) transfer \(tag(kCVImageBufferTransferFunctionKey)) space \(space)"
    }

    init(width: Int, height: Int, rgb: [Double]) {
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    /// From a YCbCr 4:2:0 (8 or 10 bit, video or full range) or BGRA buffer.
    init(_ buffer: CVPixelBuffer, width: Int = 480, height: Int = 270) {
        self.width = width
        self.height = height
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var sums = [Double](repeating: 0, count: width * height * 3)
        var counts = [Double](repeating: 0, count: width * height)
        // Sample every other pixel; plenty for levels.
        let step = max(1, min(w / width, h / height) / 2)
        func add(_ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double) {
            let i = min(height - 1, y * height / h) * width + min(width - 1, x * width / w)
            sums[i * 3] += r; sums[i * 3 + 1] += g; sums[i * 3 + 2] += b
            counts[i] += 1
        }
        switch format {
        case kCVPixelFormatType_32BGRA:
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in stride(from: 0, to: h, by: step) {
                for x in stride(from: 0, to: w, by: step) {
                    let p = base + y * row + x * 4
                    add(x, y, Double(p[2]), Double(p[1]), Double(p[0]))
                }
            }
        default:
            let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
            let (kr, kb): (Double, Double) = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) ? (0.2126, 0.0722) : (0.299, 0.114)
            let kg = 1 - kr - kb
            let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
            let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
            let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            func sample(_ base: UnsafeMutableRawPointer, _ row: Int, _ x: Int, _ y: Int, _ index: Int) -> Double {
                if tenBit {
                    let value = (base + y * row).assumingMemoryBound(to: UInt16.self)[x * (index < 0 ? 1 : 2) + max(index, 0)]
                    return Double(value >> 6) / 4
                }
                return Double((base + y * row).assumingMemoryBound(to: UInt8.self)[x * (index < 0 ? 1 : 2) + max(index, 0)])
            }
            for y in stride(from: 0, to: h, by: step) {
                for x in stride(from: 0, to: w, by: step) {
                    let luma = sample(yBase, yRow, x, y, -1)
                    let cb = sample(cBase, cRow, x / 2, y / 2, 0)
                    let cr = sample(cBase, cRow, x / 2, y / 2, 1)
                    let yy = full ? luma / 255 : (luma - 16) / 219
                    let pb = full ? (cb - 128) / 255 : (cb - 128) / 224
                    let pr = full ? (cr - 128) / 255 : (cr - 128) / 224
                    let r = yy + 2 * (1 - kr) * pr
                    let b = yy + 2 * (1 - kb) * pb
                    let g = (yy - kr * r - kb * b) / kg
                    add(x, y, r * 255, g * 255, b * 255)
                }
            }
        }
        rgb = (0..<(width * height * 3)).map { sums[$0] / max(counts[$0 / 3], 1) }
    }

    /// The raw values of a CGImage, in its own colour space (no matching).
    init(_ image: CGImage, width: Int = 480, height: Int = 270) {
        let bitmap = Bitmap(image)
        self.width = width
        self.height = height
        var sums = [Double](repeating: 0, count: width * height * 3)
        var counts = [Double](repeating: 0, count: width * height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let p = bitmap[x, y]
                let i = min(height - 1, y * height / bitmap.height) * width + min(width - 1, x * width / bitmap.width)
                sums[i * 3] += Double(p[0]); sums[i * 3 + 1] += Double(p[1]); sums[i * 3 + 2] += Double(p[2])
                counts[i] += 1
            }
        }
        rgb = (0..<(width * height * 3)).map { sums[$0] / max(counts[$0 / 3], 1) }
    }

    /// Mean R'G'B' of a region given as fractions of the frame (y down).
    func mean(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Double] {
        var total = [0.0, 0.0, 0.0]
        var n = 0.0
        for y in Int(y0 * Double(height))..<Int(y1 * Double(height)) {
            for x in Int(x0 * Double(width))..<Int(x1 * Double(width)) {
                for c in 0..<3 { total[c] += rgb[(y * width + x) * 3 + c] }
                n += 1
            }
        }
        return total.map { $0 / max(n, 1) }
    }

    var lumas: [Double] {
        (0..<(width * height)).map { 0.2126 * rgb[$0 * 3] + 0.7152 * rgb[$0 * 3 + 1] + 0.0722 * rgb[$0 * 3 + 2] }
    }

    var summary: String {
        let sorted = lumas.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let n = Double(width * height)
        let r = stride(from: 0, to: rgb.count, by: 3).reduce(0) { $0 + rgb[$1] } / n
        let g = stride(from: 1, to: rgb.count, by: 3).reduce(0) { $0 + rgb[$1] } / n
        let b = stride(from: 2, to: rgb.count, by: 3).reduce(0) { $0 + rgb[$1] } / n
        return String(format: "RGB %6.2f %6.2f %6.2f  luma p2 %6.2f p50 %6.2f p98 %6.2f", r, g, b, pct(0.02), pct(0.5), pct(0.98))
    }

    /// Mean absolute difference per channel, and the mean signed luma
    /// difference (self minus other).
    func difference(_ other: Levels) -> (mean: Double, luma: Double) {
        var total = 0.0
        for i in 0..<min(rgb.count, other.rgb.count) { total += abs(rgb[i] - other.rgb[i]) }
        let a = lumas, b = other.lumas
        var signed = 0.0
        for i in 0..<min(a.count, b.count) { signed += a[i] - b[i] }
        return (total / Double(rgb.count), signed / Double(a.count))
    }
}

/// The viewer plays through AVPlayerLayer, shows paused frames from
/// FrameRenderer, and export writes a file. All three must look the same:
/// the same pixel values, shown on screen the same way.
final class PlaybackMatchTests: XCTestCase {
    /// Blacks, shadows, greys, whites and a few colours, as R'G'B'.
    static let patches: [[Double]] = [
        [0, 0, 0], [16, 16, 16], [32, 32, 32], [48, 48, 48], [64, 64, 64], [96, 96, 96], [128, 128, 128],
        [160, 160, 160], [192, 192, 192], [224, 224, 224], [255, 255, 255], [200, 150, 120], [40, 90, 160], [180, 40, 50]
    ]

    /// A second of the patches tagged the way Mike's camera files are:
    /// SMPTE-C primaries, BT.601 matrix, BT.709 transfer, full range.
    func patchMovie(_ url: URL, size: CGSize) throws {
        let width = Int(size.width), height = Int(size.height)
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()] as CFDictionary, &made)
        let frame = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(frame, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(frame, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
        let (kr, kb) = (0.299, 0.114)
        for x in 0..<width {
            let p = Self.patches[x * Self.patches.count / width].map { $0 / 255 }
            let y = kr * p[0] + (1 - kr - kb) * p[1] + kb * p[2]
            let cb = (p[2] - y) / (2 * (1 - kb)), cr = (p[0] - y) / (2 * (1 - kr))
            for row in 0..<height { luma[row * lumaRow + x] = UInt8((255 * y).rounded()) }
            if x % 2 == 0 {
                for row in 0..<(height / 2) {
                    chroma[row * chromaRow + x] = UInt8(max(0, min(255, (128 + 255 * cb).rounded())))
                    chroma[row * chromaRow + x + 1] = UInt8(max(0, min(255, (128 + 255 * cr).rounded())))
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.95],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(writer.error as Any)")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
    }

    /// The frame an AVPlayer shows at `seconds`, as the viewer's layer gets it.
    func playerFrame(_ built: BuiltComposition, at seconds: Double) async throws -> CVPixelBuffer {
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        for _ in 0..<500 {
            if output.hasNewPixelBuffer(forItemTime: target), let pixels = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) {
                return pixels
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RenderError.compositor("the player showed nothing at \(seconds) s")
    }

    /// A file's decoded frame at `seconds`, in the format it was written in.
    func decodedFrame(_ url: URL, at seconds: Double, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(seconds: 0.1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
        reader.add(output)
        reader.startReading()
        let sample = try XCTUnwrap(output.copyNextSampleBuffer(), "no frame at \(seconds) s")
        reader.cancelReading()
        return try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    }

    /// Mean R'G'B' of the middle of each patch.
    func patchValues(_ levels: Levels) -> [[Double]] {
        let count = Self.patches.count
        return (0..<count).map { patch in
            var total = [0.0, 0.0, 0.0]
            var n = 0.0
            let from = (patch * 3 + 1) * levels.width / (count * 3), to = (patch * 3 + 2) * levels.width / (count * 3)
            for y in 0..<levels.height {
                for x in from..<max(to, from + 1) {
                    for c in 0..<3 { total[c] += levels.rgb[(y * levels.width + x) * 3 + c] }
                    n += 1
                }
            }
            return total.map { $0 / n }
        }
    }

    /// What a screen shows for each patch: the values in the colour space
    /// the display uses for that frame, matched to Display P3.
    func shown(_ values: [[Double]], in space: CGColorSpace) -> [[Double]] {
        let count = values.count
        let bytes = values.flatMap { $0.map { UInt8(max(0, min(255, $0.rounded()))) } + [255] }
        let image = CGImage(width: count, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: count * 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var out = [Float](repeating: 0, count: count * 4)
        let context = CGContext(data: &out, width: count, height: 1, bitsPerComponent: 32, bytesPerRow: count * 16,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: count, height: 1))
        return (0..<count).map { i in (0..<3).map { Double(out[i * 4 + $0]) * 255 } }
    }

    func worst(_ a: [[Double]], _ b: [[Double]]) -> (difference: Double, patch: Int) {
        var result = (difference: 0.0, patch: 0)
        for i in 0..<min(a.count, b.count) {
            let d = (0..<3).map { abs(a[i][$0] - b[i][$0]) }.max()!
            if d > result.difference { result = (d, i) }
        }
        return result
    }

    func describe(_ values: [[Double]]) -> String {
        values.map { String(format: "%.0f/%.0f/%.0f", $0[0], $0[1], $0[2]) }.joined(separator: " ")
    }

    func testPlaybackStillsAndExportShowTheSameColours() async throws {
        let media = try TestMedia()
        let size = CGSize(width: 672, height: 378)
        let source = media.folder.appendingPathComponent("patches.mov")
        try patchMovie(source, size: size)
        let item = MediaItem(id: "med_cam", path: source.path, kind: .video, role: .camera, duration: Time(seconds: 1),
                             frameRate: .fps30, width: Int(size.width), height: Int(size.height), hasVideo: true)
        let clip = Clip(id: "clip_cam", content: .media(mediaID: "med_cam"), start: .zero, duration: Time(seconds: 1))
        let project = Project(name: "Patches", settings: ProjectSettings(width: Int(size.width), height: Int(size.height), frameRate: .fps30),
                              media: [item], videoTracks: [Track(kind: .video, name: "V1", clips: [clip])], audioTracks: [])
        let context = RenderContext(project: project, folder: media.projectFolder)
        let at = 0.5

        // Playback: the compositor's buffers, as AVPlayerLayer gets them.
        let playing = try await playerFrame(try await CompositionBuilder.build(context), at: at)
        // Paused: FrameRenderer's still.
        let still = try await FrameRenderer(context: context).image(at: Time(seconds: at))
        // `tandem frame`: the same renderer's PNG, read back.
        let png = try await FrameRenderer(context: context).pngData(at: Time(seconds: at))
        let source0 = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let frameImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source0, 0, nil))
        // Export, decoded again.
        let exported = media.folder.appendingPathComponent("export.mov")
        let preset = ExportPreset(name: "Test", codec: .hevc, videoBitrate: 20_000_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: context, preset: preset, output: exported).run()
        let written = try await decodedFrame(exported, at: at)

        let columns = Self.patches.count * 12
        let player = patchValues(Levels(playing, width: columns, height: 8))
        let paused = patchValues(Levels(still, width: columns, height: 8))
        let export = patchValues(Levels(written, width: columns, height: 8))
        let grabbed = patchValues(Levels(frameImage, width: columns, height: 8))
        let original = patchValues(Levels(try await decodedFrame(source, at: at, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), width: columns, height: 8))

        // The same values: nothing lost to range, matrix or rounding.
        for (name, values) in [("player", player), ("export", export), ("tandem frame", grabbed), ("source", original)] {
            let off = worst(values, paused)
            XCTAssertLessThanOrEqual(off.difference, 3, "\(name) values are \(off.difference) levels off the still at patch \(off.patch):\n\(describe(values))\n\(describe(paused))")
        }

        // Shown the same way. AVPlayerLayer uses a frame's attached colour
        // space; without one it reads the BT.709 tags as the exact curve,
        // which lifts the shadows (black 16 showed as 32 against the still's
        // 14 on screen).
        let playerSpace = (CVBufferCopyAttachment(playing, kCVImageBufferCGColorSpaceKey, nil) as! CGColorSpace?) ?? CGColorSpace(name: CGColorSpace.itur_709)!
        let exportSpace = try XCTUnwrap(CVBufferCopyAttachment(written, kCVImageBufferCGColorSpaceKey, nil) as! CGColorSpace?, "decoders attach a colour space")
        let stillSpace = try XCTUnwrap(still.colorSpace)
        let onScreenPaused = shown(paused, in: stillSpace)
        let frameSpace = try XCTUnwrap(frameImage.colorSpace, "the PNG carries its colour space")
        for (name, values, space) in [("player", player, playerSpace), ("export", export, exportSpace), ("tandem frame", grabbed, frameSpace)] {
            let onScreen = shown(values, in: space)
            let off = worst(onScreen, onScreenPaused)
            XCTAssertLessThanOrEqual(off.difference, 2.5, "\(name) shows \(off.difference) levels off the paused still at patch \(off.patch) (Display P3):\n\(describe(onScreen))\n\(describe(onScreenPaused))")
        }
    }
}

extension PlaybackMatchTests {
    /// A camera frame: a green room with an orange "person" disc and a dark
    /// cap on top, drawn at any size so proxies match the original.
    static func drawCamera(_ context: CGContext, size: CGSize) {
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.6, blue: 0.47, alpha: 1))
        context.fillEllipse(in: person(size))
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: size.width * 0.4, y: size.height * 0.62, width: size.width * 0.2, height: size.height * 0.1))
    }

    /// Where the person is, as a fraction of the frame (y down).
    static func person(_ size: CGSize) -> CGRect {
        CGRect(x: size.width * 0.3, y: size.height * 0.15, width: size.width * 0.4, height: size.height * 0.6)
    }

    /// Share of 6x6 blocks (in a 168x96 reduction) whose mean differs by
    /// more than 12 levels in any channel, and the mean absolute difference.
    func blocks(_ a: Levels, _ b: Levels) -> (share: Double, mean: Double) {
        var differing = 0, total = 0, sum = 0.0
        for by in stride(from: 0, to: a.height - 5, by: 6) {
            for bx in stride(from: 0, to: a.width - 5, by: 6) {
                var worst = 0.0
                for c in 0..<3 {
                    var x = 0.0, y = 0.0
                    for dy in 0..<6 { for dx in 0..<6 { let i = ((by + dy) * a.width + bx + dx) * 3 + c; x += a.rgb[i]; y += b.rgb[i] } }
                    worst = max(worst, abs(x - y) / 36)
                    sum += abs(x - y) / 36
                }
                total += 1
                if worst > 12 { differing += 1 }
            }
        }
        return (Double(differing) / Double(total) * 100, sum / Double(total * 3))
    }

    /// Paused, playing, `tandem frame` and export agree on a clip with its
    /// cutout on, placed as a picture in picture over the patches: the same
    /// matte, placement and colour, although playback reads a half-size
    /// proxy and the matte is half size too.
    func testCutoutMatchesPausedPlayingFrameAndExport() async throws {
        let media = try TestMedia()
        let size = CGSize(width: 672, height: 384), half = CGSize(width: 336, height: 192)
        let background = media.folder.appendingPathComponent("patches.mov")
        try patchMovie(background, size: size)
        try await media.movie("camera.mov", seconds: 1, size: size, draw: { _, c in Self.drawCamera(c, size: size) })
        let proxy = try await media.movie("camera-proxy.mov", seconds: 1, size: half, draw: { _, c in Self.drawCamera(c, size: half) })
        let matte = try await media.movie("matte.mov", seconds: 1, size: half, draw: { _, c in
            TestMedia.fill(c, 0, 0, 0, size: half)
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fillEllipse(in: Self.person(half))
        })
        let items = [
            MediaItem(id: "med_bg", path: background.path, kind: .video, role: .screen, duration: Time(seconds: 1), frameRate: .fps30,
                      width: Int(size.width), height: Int(size.height), hasVideo: true),
            MediaItem(id: "med_cam", path: "camera.mov", kind: .video, role: .camera, duration: Time(seconds: 1), frameRate: .fps30,
                      width: Int(size.width), height: Int(size.height), hasVideo: true)
        ]
        let screen = Clip(id: "clip_bg", content: .media(mediaID: "med_bg"), start: .zero, duration: Time(seconds: 1))
        let camera = Clip(id: "clip_cam", content: .media(mediaID: "med_cam"), start: .zero, duration: Time(seconds: 1),
                          video: VideoProperties(transform: Transform(position: Point(x: 0.7, y: 0.6), scale: 0.5), cutout: Cutout(edgeFeather: 0)))
        let project = Project(name: "Cutout", settings: ProjectSettings(width: Int(size.width), height: Int(size.height), frameRate: .fps30), media: items,
                              videoTracks: [Track(kind: .video, name: "Screen", clips: [screen]), Track(kind: .video, name: "Camera", clips: [camera])], audioTracks: [])
        let assets = FakeAssets()
        assets.proxies["med_cam"] = proxy
        assets.mattes["med_cam"] = matte
        var playing = RenderContext(project: project, folder: media.projectFolder, useProxies: true, assets: assets)
        playing.sizeOverride = nil
        let exact = RenderContext(project: project, folder: media.projectFolder, useProxies: false, assets: assets)
        let at = 0.5

        let player = Levels(try await playerFrame(try await CompositionBuilder.build(playing), at: at), width: 168, height: 96)
        let paused = Levels(try await FrameRenderer(context: exact).image(at: Time(seconds: at)), width: 168, height: 96)
        let png = try await FrameRenderer(context: exact).pngData(at: Time(seconds: at))
        let grabbed = Levels(try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil)), 0, nil)), width: 168, height: 96)
        let exported = media.folder.appendingPathComponent("export.mov")
        _ = try await Exporter(context: exact, preset: ExportPreset(name: "Test", codec: .hevc, videoBitrate: 20_000_000, loudnessTarget: nil, truePeakCeiling: nil), output: exported).run()
        let export = Levels(try await decodedFrame(exported, at: at), width: 168, height: 96)

        // The picture in picture covers x 0.45...0.95, y 0.35...0.85; the
        // matte keeps the person and shows the patches around them.
        func pixel(_ levels: Levels, _ x: Double, _ y: Double) -> [Double] {
            let i = (Int(y * Double(levels.height)) * levels.width + Int(x * Double(levels.width))) * 3
            return Array(levels.rgb[i..<(i + 3)])
        }
        for (name, levels) in [("paused", paused), ("playing", player), ("tandem frame", grabbed), ("export", export)] {
            let corner = pixel(levels, 0.49, 0.40), person = pixel(levels, 0.7, 0.55)
            XCTAssertFalse(corner[1] > corner[0] + 60 && corner[1] > corner[2] + 60, "\(name) shows the camera's green around the person: no matte (\(corner))")
            XCTAssertGreaterThan(person[0], 150, "\(name) has no person where the cutout puts them (\(person))")
        }
        for (name, levels) in [("playing", player), ("tandem frame", grabbed), ("export", export)] {
            let difference = blocks(levels, paused)
            XCTAssertLessThan(difference.share, 3, String(format: "%@ differs from the paused still in %.1f%% of blocks (mean %.2f)", name, difference.share, difference.mean))
            XCTAssertLessThan(difference.mean, 3, String(format: "%@ is %.2f levels off the paused still on average", name, difference.mean))
        }
    }
}
