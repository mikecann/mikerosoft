import Accelerate
import AVFoundation
import CoreVideo
import Foundation
import TandemCore
import Vision

/// The cutout matte, written as a greyscale HEVC movie with the source's
/// exact frame times.
///
/// Version 2, the default: Vision's person segmentation for every frame,
/// with the foreground subject mask adding what the person holds (the mic,
/// `MatteBlender.keepSubject`), then steadied over time where the picture
/// is still (`MatteSmoother`). Version 1 blended the person instance mask
/// and had no smoothing, so the mic popped in and out and the edges
/// shimmered; `MatteProps.personInstances` with `MatteSmoothing.off` still
/// makes it.
///
/// The matte is the luma of full-range (420f) frames: 0 is background, 255
/// is person. Chroma is neutral. The track carries the source's rotation, so
/// it lines up with the source in display space too.
enum MatteJob {
    static let file = "matte.mov"
    /// Frames in Vision at once. With two requests a frame the Neural
    /// Engine saturates at four (41 fps on the M5 Pro against 39 with
    /// three); more only adds latency and memory.
    static let workers = 4

    /// Knobs for measuring the pipeline; the app uses the defaults.
    ///
    /// The segmentation request is a VNStatefulRequest, so workers taking
    /// frames in whatever order they finish looked risky. Measured on 20 s
    /// of the camera (RealMediaTests.testMatteTemporalStateExperiment), the
    /// mattes are identical to the byte whether three workers share frames,
    /// every frame gets a fresh request, or one worker goes in order (at
    /// half the speed), and identical from run to run.
    struct Tuning {
        var workers = MatteJob.workers
        /// A fresh segmentation request for every frame: no temporal state.
        var stateless = false
    }

    static func run(source: URL, settings: AnalysisSettings, into folder: URL, context: JobContext, timeRange: CMTimeRange? = nil, tuning: Tuning = Tuning()) async throws {
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
        let pipeline = try MattePipeline(reader: reader, width: size.width, height: size.height, settings: settings, workers: tuning.workers, stateless: tuning.stateless)
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

/// Decoder thread, Vision workers and an in-order hand-off to the smoother
/// and the writer, with bounded queues so a paused job holds a few frames,
/// not the file.
final class MattePipeline: @unchecked Sendable {
    let width: Int
    let height: Int
    private let reader: VideoFrameReader
    private let settings: AnalysisSettings
    private let workerCount: Int
    private let pool: CVPixelBufferPool
    /// Pictures for the smoother's motion test, a quarter of the matte each way.
    private let pictureWidth: Int
    private let pictureHeight: Int

    private let condition = NSCondition()
    private var inbox: [(index: Int, buffer: CVPixelBuffer, time: CMTime)] = []
    private var results: [Int: Worked] = [:]
    private var decoded = 0
    private var endOfInput = false
    private var stopped = false
    private var readError: Error?
    private var next = 0

    // The writer's side, one call at a time.
    private let smoother: MatteSmoother?
    /// Times of the frames in the smoother, oldest first.
    private var times: [CMTime] = []
    private var lastMatte: [UInt8]?
    private(set) var written = 0
    private(set) var failures = 0

    private let stateless: Bool

    /// A worker's result: the matte (nil if Vision failed) and, when
    /// smoothing, the frame's picture.
    private struct Worked {
        var matte: [UInt8]?
        var picture: MotionPicture?
        var time: CMTime
    }

    init(reader: VideoFrameReader, width: Int, height: Int, settings: AnalysisSettings, workers: Int, stateless: Bool = false) throws {
        self.stateless = stateless
        self.reader = reader
        self.width = width
        self.height = height
        self.settings = settings
        workerCount = max(1, workers)
        pool = try makePixelBufferPool(width: width, height: height, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        pictureWidth = max(2, width / 4)
        pictureHeight = max(2, height / 4)
        smoother = settings.matteSmoothing == .steady ? MatteSmoother(width: width, height: height) : nil
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
        let blender = MatteBlender(width: width, height: height, quality: settings.matteQuality, mode: settings.matteMode, props: settings.matteProps, stateless: stateless)
        let smoothing = settings.matteSmoothing == .steady
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

            let worked = autoreleasepool {
                Worked(
                    matte: blender.matte(for: job.buffer),
                    picture: smoothing ? MotionPicture(frame: job.buffer, width: pictureWidth, height: pictureHeight) : nil,
                    time: job.time
                )
            }

            condition.lock()
            // Don't run far ahead of the writer: memory stays flat however
            // long the take is.
            while results.count >= workerCount * 4, job.index > next, !stopped { condition.wait() }
            results[job.index] = worked
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Hands up to `count` frames to the writer in order, through the
    /// smoother. Returns false when every frame has been written.
    func write(upTo count: Int, into writer: EncodedMovieWriter) throws -> Bool {
        var appended = 0
        while appended < count {
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
            let frame = results.removeValue(forKey: next)
            if frame != nil { next += 1 }
            condition.broadcast()
            condition.unlock()
            guard let frame else {
                for matte in smoother?.finish() ?? [] { try append(matte, into: writer) }
                return false
            }
            var matte: [UInt8]
            if let made = frame.matte {
                matte = made
            } else {
                // Vision failed on this frame: hold the one before.
                failures += 1
                matte = lastMatte ?? [UInt8](repeating: 0, count: width * height)
            }
            lastMatte = matte
            times.append(frame.time)
            if let smoother, let picture = frame.picture {
                for ready in smoother.push(matte, picture: picture) {
                    try append(ready, into: writer)
                    appended += 1
                }
            } else {
                try append(matte, into: writer)
                appended += 1
            }
        }
        return true
    }

    /// Writes the oldest waiting frame's matte.
    private func append(_ matte: [UInt8], into writer: EncodedMovieWriter) throws {
        let time = times.removeFirst()
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        if output == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &output)
        }
        guard let output else { throw MediaError.failed("Out of memory for matte frames") }
        MatteBlender.copy(matte, width: width, height: height, into: output)
        try writer.append(output, at: time)
        written += 1
    }
}

/// Turns one frame into a matte. Each worker owns one: Vision requests and
/// scratch buffers are reused frame to frame.
final class MatteBlender {
    let width: Int
    let height: Int
    let mode: CutoutMode
    let props: MatteProps
    private var segmentation = VNGeneratePersonSegmentationRequest()
    private let quality: MatteQuality
    private let stateless: Bool
    private let instances = VNGeneratePersonInstanceMaskRequest()
    private let subject = VNGenerateForegroundInstanceMaskRequest()
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
    /// (a mic held in front of the chest) are filled from the instance or
    /// subject mask.
    static let holeSize = 0.33
    /// The subject mask may add to the person's hull (the person mask with
    /// its holes closed) grown by this share of the frame height, so the end
    /// of a mic poking past the outline isn't cut square.
    static let hullGrowth = 0.06
    /// Within this share of the frame height of the subject, the person
    /// mask counts as it is: soft edges, hair.
    static let nearSubject = 0.011
    /// Away from the subject, person mask values from 0.6 (half-sure desk
    /// and sofa) to 0.95 are stretched to 0...1, so only what Vision is sure
    /// of stays, like a hand held out.
    static let confident: [UInt8] = (0..<256).map { UInt8(max(0, min(255, ($0 - 153) * 255 / 89))) }

    init(width: Int, height: Int, quality: MatteQuality, mode: CutoutMode, props: MatteProps = .subject, stateless: Bool = false) {
        self.width = width
        self.height = height
        self.mode = mode
        self.props = props
        self.quality = quality
        self.stateless = stateless
        person = [UInt8](repeating: 0, count: width * height)
        combined = [UInt8](repeating: 0, count: width * height)
        segmentation = Self.segmentationRequest(quality)
    }

    static func segmentationRequest(_ quality: MatteQuality) -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        switch quality {
        case .fast: request.qualityLevel = .fast
        case .balanced: request.qualityLevel = .balanced
        case .accurate: request.qualityLevel = .accurate
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    /// The matte for `frame`, width x height, or nil if Vision failed.
    func matte(for frame: CVPixelBuffer) -> [UInt8]? {
        if stateless { segmentation = Self.segmentationRequest(quality) }
        let blendInstances = mode == .personAndProps && props == .personInstances
        let requests: [VNRequest] = blendInstances ? [segmentation, instances] : [segmentation]
        do {
            if stateless {
                try VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:]).perform(requests)
            } else {
                try handler.perform(requests, on: frame, orientation: .up)
            }
        } catch {
            return nil
        }
        guard let mask = segmentation.results?.first?.pixelBuffer else { return nil }
        guard Self.scale(mask, into: &person, width: width, height: height) else { return nil }
        guard mode == .personAndProps else { return person }

        if !blendInstances {
            return Self.keepSubject(person: person, subject: subjectMask(frame), width: width, height: height)
        }
        if let observation = instances.results?.first, !observation.allInstances.isEmpty,
           let instanceMask = try? observation.generateMask(forInstances: observation.allInstances),
           let extra = props(personMask: mask, instanceMask: instanceMask) {
            combined.withUnsafeMutableBufferPointer { out in
                person.withUnsafeBufferPointer { p in
                    extra.withUnsafeBufferPointer { e in
                        for i in 0..<out.count { out[i] = max(p[i], e[i]) }
                    }
                }
            }
            return combined
        }
        return person
    }

    /// Vision's foreground subject ("lift subject") at matte size, or nil
    /// if it found none.
    private func subjectMask(_ frame: CVPixelBuffer) -> [UInt8]? {
        do {
            try VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:]).perform([subject])
        } catch {
            return nil
        }
        guard let observation = subject.results?.first, !observation.allInstances.isEmpty,
              let mask = try? observation.generateMask(forInstances: observation.allInstances) else { return nil }
        let maskWidth = CVPixelBufferGetWidth(mask), maskHeight = CVPixelBufferGetHeight(mask)
        var small = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        guard Self.floatMask(mask, into: &small) else { return nil }
        var out = [UInt8](repeating: 0, count: width * height)
        let error = Self.withImage(&small, maskWidth, maskHeight) { source in
            Self.withImage(&out, width, height) { destination in
                vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return error == kvImageNoError ? out : nil
    }

    /// The version 2 cutout from the person mask and the subject mask (both
    /// width x height, 0...255).
    ///
    /// The subject mask holds still from frame to frame and has the mic in
    /// it, but it misses a hand held away from the body; the person mask
    /// has the hand but shimmers, loses the mic and takes half-sure bits of
    /// desk and sofa. So:
    /// - the subject adds itself inside the person's hull, grown a little,
    ///   so something far from the person (a chair) stays out;
    /// - near the subject the person mask counts as it is;
    /// - away from it only confident person pixels count (`confident`).
    ///
    /// With no subject (Vision found none) it's the person mask.
    static func keepSubject(person: [UInt8], subject: [UInt8]?, width: Int, height: Int) -> [UInt8] {
        guard let subject, subject.count == person.count else { return person }

        // The hull, worked out at an eighth of the size.
        let smallWidth = max(1, width / 8), smallHeight = max(1, height / 8)
        var source = person
        var small = [UInt8](repeating: 0, count: smallWidth * smallHeight)
        withImage(&source, width, height) { input in
            withImage(&small, smallWidth, smallHeight) { output in
                _ = vImageScale_Planar8(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        func odd(_ size: Int) -> Int { size % 2 == 0 ? size + 1 : size }
        small = morphology(small, smallWidth, smallHeight, kernel: odd(max(1, Int(holeSize * Double(smallHeight)))), grow: true)
        small = morphology(small, smallWidth, smallHeight, kernel: odd(max(1, Int(holeSize * Double(smallHeight)))), grow: false)
        small = morphology(small, smallWidth, smallHeight, kernel: 2 * Int((hullGrowth * Double(smallHeight)).rounded()) + 1, grow: true)
        var hull = [UInt8](repeating: 0, count: width * height)
        withImage(&small, smallWidth, smallHeight) { input in
            withImage(&hull, width, height) { output in
                _ = vImageScale_Planar8(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        // In or out: resampling ripples would let a faint chair through.
        for i in 0..<hull.count { hull[i] = hull[i] >= 128 ? 255 : 0 }

        // Near the subject: its confident part, grown.
        let solid = subject.map { $0 > 128 ? UInt8(255) : 0 }
        let near = morphology(solid, width, height, kernel: 2 * max(1, Int((nearSubject * Double(height)).rounded())) + 1, grow: true)

        var out = [UInt8](repeating: 0, count: person.count)
        confident.withUnsafeBufferPointer { confident in
            person.withUnsafeBufferPointer { person in
                subject.withUnsafeBufferPointer { subject in
                    hull.withUnsafeBufferPointer { hull in
                        near.withUnsafeBufferPointer { near in
                            out.withUnsafeMutableBufferPointer { out in
                                for i in 0..<out.count {
                                    let own = near[i] != 0 ? person[i] : confident[Int(person[i])]
                                    out[i] = max(own, min(subject[i], hull[i]))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// A square max (grow) or min filter.
    static func morphology(_ plane: [UInt8], _ width: Int, _ height: Int, kernel: Int, grow: Bool) -> [UInt8] {
        guard kernel > 1 else { return plane }
        var source = plane
        var out = [UInt8](repeating: 0, count: plane.count)
        let size = vImagePixelCount(kernel)
        withImage(&source, width, height) { input in
            withImage(&out, width, height) { output in
                if grow {
                    _ = vImageMax_Planar8(&input, &output, nil, 0, 0, size, size, vImage_Flags(kvImageNoFlags))
                } else {
                    _ = vImageMin_Planar8(&input, &output, nil, 0, 0, size, size, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        return out
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

    static func tagBT709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }
}
