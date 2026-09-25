import Accelerate
import AVFoundation
import CoreVideo
import Foundation
import TandemCore
import Vision

/// The cutout matte: Vision person segmentation for every frame, blended
/// with the person-instance mask so a handheld mic survives, written as a
/// greyscale HEVC movie with the source's exact frame times.
///
/// The matte is the luma of full-range (420f) frames: 0 is background, 255
/// is person. Chroma is neutral. The track carries the source's rotation, so
/// it lines up with the source in display space too.
enum MatteJob {
    static let file = "matte.mov"
    /// Vision requests in flight. The Neural Engine saturates at three
    /// (60 fps accurate on the M5 Pro); more only adds latency.
    static let workers = 3

    static func run(source: URL, settings: AnalysisSettings, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil) async throws {
        let reader = try await VideoFrameReader(url: source, timeRange: timeRange)
        let size = fittedSize(width: Int(reader.size.width), height: Int(reader.size.height), maxWidth: settings.matteMaxWidth, maxHeight: settings.matteMaxHeight)
        let writer = try EncodedMovieWriter(url: folder.appendingPathComponent(file), settings: .init(
            width: size.width, height: size.height,
            // Short GOPs without reordering keep random access cheap for
            // scrubbing, and a mostly flat greyscale picture stays small.
            keyFrameInterval: 10, quality: 0.6, prioritizeSpeed: true,
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2, transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            timescale: reader.timescale, transform: reader.transform, expectedFrameRate: reader.nominalFrameRate > 0 ? reader.nominalFrameRate : nil
        ))
        let pipeline = try MattePipeline(reader: reader, width: size.width, height: size.height, quality: settings.matteQuality, mode: settings.matteMode, workers: workers)
        pipeline.start()
        await context.acquireEncoder()
        do {
            while true {
                let more = try await Blocking.run(qos: context.qos) { try pipeline.write(upTo: 15, into: writer) }
                let done = pipeline.written
                var message = "Frame \(done) of \(reader.frameCount)"
                if pipeline.failures > 0 { message += ", \(pipeline.failures) held from the frame before" }
                context.progress(Double(done) / Double(max(1, reader.frameCount)), message: message)
                if !more { break }
                try await context.checkpoint()
            }
            try await writer.finish(endTime: reader.endTime)
            pipeline.stop()
        } catch {
            pipeline.stop()
            reader.cancel()
            writer.cancel()
            throw error
        }
    }
}

/// Decoder thread, Vision workers and an in-order hand-off to the writer,
/// with bounded queues so a paused job holds a few frames, not the file.
final class MattePipeline: @unchecked Sendable {
    let width: Int
    let height: Int
    private let reader: VideoFrameReader
    private let quality: MatteQuality
    private let mode: CutoutMode
    private let workerCount: Int
    private let pool: CVPixelBufferPool

    private let condition = NSCondition()
    private var inbox: [(index: Int, buffer: CVPixelBuffer, time: CMTime)] = []
    private var results: [Int: (buffer: CVPixelBuffer, time: CMTime)] = [:]
    private var decoded = 0
    private var endOfInput = false
    private var stopped = false
    private var readError: Error?
    private var next = 0
    private var lastGood: CVPixelBuffer?
    private(set) var written = 0
    private(set) var failures = 0

    init(reader: VideoFrameReader, width: Int, height: Int, quality: MatteQuality, mode: CutoutMode, workers: Int) throws {
        self.reader = reader
        self.width = width
        self.height = height
        self.quality = quality
        self.mode = mode
        workerCount = max(1, workers)
        pool = try makePixelBufferPool(width: width, height: height, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    func start() {
        let decoder = Thread { [self] in decodeLoop() }
        decoder.name = "tandem.matte.decode"
        decoder.qualityOfService = .utility
        decoder.start()
        for index in 0..<workerCount {
            let worker = Thread { [self] in workLoop() }
            worker.name = "tandem.matte.vision.\(index)"
            worker.qualityOfService = .utility
            worker.start()
        }
    }

    func stop() {
        condition.lock()
        stopped = true
        inbox.removeAll()
        results.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    private func decodeLoop() {
        var index = 0
        while true {
            let frame: (buffer: CVPixelBuffer, time: CMTime)?
            do {
                frame = try autoreleasepool { try reader.next() }
            } catch {
                condition.lock()
                readError = error
                endOfInput = true
                condition.broadcast()
                condition.unlock()
                return
            }
            condition.lock()
            guard let frame, !stopped else {
                endOfInput = true
                decoded = index
                condition.broadcast()
                condition.unlock()
                return
            }
            while inbox.count >= workerCount * 2, !stopped { condition.wait() }
            inbox.append((index, frame.buffer, frame.time))
            index += 1
            decoded = index
            condition.broadcast()
            condition.unlock()
        }
    }

    private func workLoop() {
        let blender = MatteBlender(width: width, height: height, quality: quality, mode: mode)
        while true {
            condition.lock()
            while inbox.isEmpty, !endOfInput, !stopped { condition.wait() }
            if stopped || (inbox.isEmpty && endOfInput) {
                condition.unlock()
                return
            }
            let job = inbox.removeFirst()
            condition.broadcast()
            condition.unlock()

            let matte: CVPixelBuffer? = autoreleasepool {
                var output: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
                guard let output, blender.render(job.buffer, into: output) else { return nil }
                return output
            }

            condition.lock()
            // Don't run far ahead of the writer: memory stays flat however
            // long the take is.
            while results.count >= workerCount * 4, job.index > next, !stopped { condition.wait() }
            if let matte {
                results[job.index] = (matte, job.time)
            } else if let stand = lastGood ?? blankFrame() {
                failures += 1
                results[job.index] = (stand, job.time)
            } else {
                readError = MediaError.failed("Out of memory for matte frames")
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Hands up to `count` frames to the writer in order. Returns false when
    /// every frame has been written.
    func write(upTo count: Int, into writer: EncodedMovieWriter) throws -> Bool {
        for _ in 0..<count {
            condition.lock()
            while results[next] == nil, !(endOfInput && next >= decoded), !stopped, readError == nil { condition.wait() }
            if let readError {
                condition.unlock()
                throw readError
            }
            if stopped {
                condition.unlock()
                throw CancellationError()
            }
            guard let frame = results.removeValue(forKey: next) else {
                condition.unlock()
                return false
            }
            next += 1
            lastGood = frame.buffer
            condition.broadcast()
            condition.unlock()
            try writer.append(frame.buffer, at: frame.time)
            written += 1
        }
        return true
    }

    /// An empty matte for a frame Vision failed on before any succeeded.
    /// Falls back to a one-off buffer if the pool is exhausted.
    private func blankFrame() -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        if output == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &output)
        }
        guard let output else { return nil }
        MatteBlender.fill(output, luma: 0)
        return output
    }
}

/// Turns one frame into a matte. Each worker owns one: Vision requests and
/// scratch buffers are reused frame to frame.
final class MatteBlender {
    let width: Int
    let height: Int
    let mode: CutoutMode
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let instances = VNGeneratePersonInstanceMaskRequest()
    private let handler = VNSequenceRequestHandler()
    private var person: [UInt8]
    private var combined: [UInt8]

    /// The instance mask is soft and sometimes only 60% sure of the mic;
    /// this curve makes 0.6 and up solid and drops the faint halo below 0.25.
    static let instanceCurve: [UInt8] = (0..<256).map { value in
        let x = (Double(value) / 255 - 0.25) / (0.6 - 0.25)
        return UInt8((min(1, max(0, x)) * 255).rounded())
    }
    /// Holes in the person mask smaller than this share of the frame height
    /// (a mic held in front of the chest) are filled from the instance mask.
    static let holeSize = 0.33

    init(width: Int, height: Int, quality: MatteQuality, mode: CutoutMode) {
        self.width = width
        self.height = height
        self.mode = mode
        switch quality {
        case .fast: segmentation.qualityLevel = .fast
        case .balanced: segmentation.qualityLevel = .balanced
        case .accurate: segmentation.qualityLevel = .accurate
        }
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        person = [UInt8](repeating: 0, count: width * height)
        combined = [UInt8](repeating: 0, count: width * height)
    }

    /// Writes the matte for `frame` into the luma of `output` (420f).
    func render(_ frame: CVPixelBuffer, into output: CVPixelBuffer) -> Bool {
        let requests: [VNRequest] = mode == .personAndProps ? [segmentation, instances] : [segmentation]
        do {
            try handler.perform(requests, on: frame, orientation: .up)
        } catch {
            return false
        }
        guard let mask = segmentation.results?.first?.pixelBuffer else { return false }
        guard Self.scale(mask, into: &person, width: width, height: height) else { return false }

        var matte = person
        if mode == .personAndProps, let observation = instances.results?.first, !observation.allInstances.isEmpty,
           let instanceMask = try? observation.generateMask(forInstances: observation.allInstances) {
            if let props = props(personMask: mask, instanceMask: instanceMask) {
                combined.withUnsafeMutableBufferPointer { out in
                    person.withUnsafeBufferPointer { p in
                        props.withUnsafeBufferPointer { e in
                            for i in 0..<out.count { out[i] = max(p[i], e[i]) }
                        }
                    }
                }
                matte = combined
            }
        }
        Self.copy(matte, width: width, height: height, into: output)
        return true
    }

    /// What the instance mask adds: the parts of it inside holes of the
    /// person mask, at output size.
    ///
    /// Working at the instance mask's size (512x384): close the person mask
    /// (dilate then erode) so holes the size of a mic fill in while its
    /// outline stays put, sharpen the instance mask with `instanceCurve`,
    /// and keep the instance mask only where the closed person mask is. The
    /// instance mask's soft halo and the chair it likes to include both sit
    /// outside the person, so they're cut away.
    private func props(personMask: CVPixelBuffer, instanceMask: CVPixelBuffer) -> [UInt8]? {
        let smallWidth = CVPixelBufferGetWidth(instanceMask)
        let smallHeight = CVPixelBufferGetHeight(instanceMask)
        guard smallWidth > 0, smallHeight > 0 else { return nil }
        var instance = [UInt8](repeating: 0, count: smallWidth * smallHeight)
        guard Self.floatMask(instanceMask, into: &instance) else { return nil }
        var smallPerson = [UInt8](repeating: 0, count: smallWidth * smallHeight)
        guard Self.scale(personMask, into: &smallPerson, width: smallWidth, height: smallHeight) else { return nil }

        var kernel = Int(Self.holeSize * Double(smallHeight))
        if kernel % 2 == 0 { kernel += 1 }
        var dilated = [UInt8](repeating: 0, count: smallWidth * smallHeight)
        var closed = [UInt8](repeating: 0, count: smallWidth * smallHeight)
        Self.withImage(&smallPerson, smallWidth, smallHeight) { source in
            Self.withImage(&dilated, smallWidth, smallHeight) { destination in
                _ = vImageMax_Planar8(&source, &destination, nil, 0, 0, vImagePixelCount(kernel), vImagePixelCount(kernel), vImage_Flags(kvImageNoFlags))
            }
        }
        Self.withImage(&dilated, smallWidth, smallHeight) { source in
            Self.withImage(&closed, smallWidth, smallHeight) { destination in
                _ = vImageMin_Planar8(&source, &destination, nil, 0, 0, vImagePixelCount(kernel), vImagePixelCount(kernel), vImage_Flags(kvImageNoFlags))
            }
        }
        Self.instanceCurve.withUnsafeBufferPointer { curve in
            Self.withImage(&instance, smallWidth, smallHeight) { image in
                _ = vImageTableLookUp_Planar8(&image, &image, curve.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }
        for i in 0..<instance.count { instance[i] = min(instance[i], closed[i]) }

        var props = [UInt8](repeating: 0, count: width * height)
        Self.withImage(&instance, smallWidth, smallHeight) { source in
            Self.withImage(&props, width, height) { destination in
                _ = vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return props
    }

    // MARK: - Pixel plumbing

    static func withImage<T>(_ pixels: inout [UInt8], _ width: Int, _ height: Int, _ body: (inout vImage_Buffer) -> T) -> T {
        pixels.withUnsafeMutableBytes { raw in
            var image = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            return body(&image)
        }
    }

    /// Scales a one-channel 8-bit buffer into `pixels`.
    static func scale(_ buffer: CVPixelBuffer, into pixels: inout [UInt8], width: Int, height: Int) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        var source = vImage_Buffer(
            data: base, height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(buffer)), rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        let error = withImage(&pixels, width, height) { destination in
            vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        return error == kvImageNoError
    }

    /// Converts a 0...1 float mask to 8 bits.
    static func floatMask(_ buffer: CVPixelBuffer, into pixels: inout [UInt8]) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let error = withImage(&pixels, width, height) { destination in
            vImageConvert_PlanarFtoPlanar8(&source, &destination, 1, 0, vImage_Flags(kvImageNoFlags))
        }
        return error == kvImageNoError
    }

    /// Puts the matte in the luma plane and neutral grey in the chroma plane.
    static func copy(_ matte: [UInt8], width: Int, height: Int, into output: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        matte.withUnsafeBytes { source in
            for row in 0..<height {
                memcpy(luma + row * lumaStride, source.baseAddress! + row * width, width)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(output, 1) * CVPixelBufferGetHeightOfPlane(output, 1))
        tagBT709(output)
    }

    static func fill(_ output: CVPixelBuffer, luma: UInt8) {
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        memset(CVPixelBufferGetBaseAddressOfPlane(output, 0)!, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(output, 0) * CVPixelBufferGetHeightOfPlane(output, 0))
        memset(CVPixelBufferGetBaseAddressOfPlane(output, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(output, 1) * CVPixelBufferGetHeightOfPlane(output, 1))
        tagBT709(output)
    }

    static func tagBT709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }
}
