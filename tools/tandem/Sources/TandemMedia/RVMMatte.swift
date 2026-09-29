import Accelerate
import AVFoundation
import CoreML
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

/// Robust Video Matting as a matte method (`MatteModel.robustVideoMatting`).
///
/// RVM (Lin et al. 2021, https://github.com/PeterL1n/RobustVideoMatting) is
/// a video matting network with a recurrent state: each frame's matte is
/// made knowing the frames before it, so it holds still where Vision's
/// per-frame masks flicker, with no smoothing afterwards. Tandem uses the
/// project's own Core ML export of the MobileNetV3 model with 1280x720
/// input and the downsample ratio 0.375 built in: the network sees 480x270
/// and its refiner brings the matte back to 1280x720, scaled up to the
/// matte box. The 1920x1080 export scored the same on Mike's takes and
/// looked the same at 1:1, but ran at 22 to 30 fps against 35 to 37. On
/// his takes it keeps the handheld mic like version 2 does (docs/MEDIA.md
/// has the scores).
///
/// Licence: the RVM repository is GPL-3.0. The model file's own metadata
/// says Apache 2.0; Tandem goes by the repository. So the weights are never
/// committed or bundled: `RVMModelStore` downloads them from the official
/// v1.0.0 release on first use, into
/// ~/Library/Application Support/Tandem/Models/rvm/, and checks the SHA-256.
enum RVMMatte {
    /// Bump when RVM mattes change; it's in their cache key, apart from
    /// Vision's.
    static let version = 1
    static let modelFile = "rvm_mobilenetv3_1280x720_s0.375_fp16.mlmodel"
    static let modelURL = URL(string: "https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3_1280x720_s0.375_fp16.mlmodel")!
    static let modelSHA256 = "b1b60ff93d57ba4c3c0eeedd1d38590ccbd498144d4ddcdaf8624dbe69e901ad"
    static let inputWidth = 1280
    static let inputHeight = 720

    /// Where a width x height frame lands in the model's input when it's
    /// scaled to fit (letterboxed or pillarboxed, centred).
    static func contentRect(width: Int, height: Int, inputWidth: Int = inputWidth, inputHeight: Int = inputHeight) -> CGRect {
        guard width > 0, height > 0 else { return CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight) }
        let scale = min(Double(inputWidth) / Double(width), Double(inputHeight) / Double(height))
        let fittedWidth = min(inputWidth, Int((Double(width) * scale).rounded()))
        let fittedHeight = min(inputHeight, Int((Double(height) * scale).rounded()))
        return CGRect(x: (inputWidth - fittedWidth) / 2, y: (inputHeight - fittedHeight) / 2, width: fittedWidth, height: fittedHeight)
    }

    /// Makes `matte.mov` like `MatteJob`, frame by frame in order (the
    /// recurrent state needs them in order, so there is one worker).
    static func run(source: URL, settings: AnalysisSettings, into folder: URL, context: JobContext, timeRange: CMTimeRange?, store: RVMModelStore) async throws {
        context.progress(0, message: "Loading RVM")
        let loaded: (model: MLModel, compiled: URL)
        do {
            loaded = try await store.loadModel()
        } catch {
            throw MediaError.failed("The RVM model isn't available: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: loaded.compiled) }
        let reader = try await VideoFrameReader(url: source, timeRange: timeRange)
        let width = Int(reader.size.width), height = Int(reader.size.height)
        let size = fittedSize(width: width, height: height, maxWidth: settings.matteMaxWidth, maxHeight: settings.matteMaxHeight)
        let writer = try MatteJob.makeWriter(reader: reader, width: size.width, height: size.height, folder: folder)
        let runner = try RVMRunner(model: loaded.model, sourceWidth: width, sourceHeight: height, outputWidth: size.width, outputHeight: size.height)
        let frames = FramePrefetcher(reader: reader)
        frames.start()
        defer { frames.stop() }
        await context.acquireEncoder()
        do {
            while true {
                let more = try await Blocking.run(qos: context.qos) { try runner.step(frames: 15, from: frames, into: writer) }
                var message = "Frame \(runner.done) of \(reader.frameCount) (RVM)"
                if runner.failures > 0 { message += ", \(runner.failures) held from the frame before" }
                context.progress(Double(runner.done) / Double(max(1, reader.frameCount)), message: message)
                if !more { break }
                try await context.checkpoint()
            }
            try await writer.finish(endTime: reader.endTime)
        } catch {
            reader.cancel()
            writer.cancel()
            throw error
        }
    }
}

/// Where the RVM model lives and how it gets there: downloaded on first use
/// (or when the file there doesn't match its checksum), checked, then
/// compiled for this Mac for each job.
struct RVMModelStore: Sendable {
    var folder: URL
    var fileName: String
    var remote: URL
    var sha256: String
    /// Downloads `remote` to a temporary file the store may delete. Tests
    /// swap in a copy so they never touch the network.
    var fetch: @Sendable (URL) async throws -> URL

    static let standard = RVMModelStore(
        folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tandem/Models/rvm", isDirectory: true),
        fileName: RVMMatte.modelFile,
        remote: RVMMatte.modelURL,
        sha256: RVMMatte.modelSHA256,
        fetch: { try await download($0) }
    )

    static func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw MediaError.failed("Downloading \(url.lastPathComponent) failed (HTTP \(http.statusCode))")
        }
        // URLSession's file goes when this call returns.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-rvm-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    static func checksum(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The model file, fetched first if it's missing or damaged.
    func modelFile() async throws -> URL {
        let target = folder.appendingPathComponent(fileName)
        if (try? Self.checksum(of: target)) == sha256 { return target }
        let downloaded = try await fetch(remote)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard try Self.checksum(of: downloaded) == sha256 else {
            throw MediaError.failed("The RVM model download didn't match its checksum")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Staged next to the target and swapped in, so a half-written model
        // is never where the next job looks.
        let staged = folder.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        try FileManager.default.copyItem(at: downloaded, to: staged)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
        return target
    }

    /// The model compiled for this Mac (about a second) and loaded for the
    /// GPU, the fastest here: 18 ms a frame against 30 on the Neural Engine.
    /// The caller deletes `compiled` when it's done with the model.
    func loadModel() async throws -> (model: MLModel, compiled: URL) {
        let compiled = try await MLModel.compileModel(at: try await modelFile())
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        return (try MLModel(contentsOf: compiled, configuration: configuration), compiled)
    }
}

/// Runs frames through RVM in order, carrying its recurrent state.
final class RVMRunner: @unchecked Sendable {
    private let model: MLModel
    private let session: VTPixelTransferSession
    private let inputPool: CVPixelBufferPool
    private let outputPool: CVPixelBufferPool
    private let content: CGRect
    private let outputWidth: Int
    private let outputHeight: Int
    private var state: [String: MLMultiArray] = [:]
    private var last: [UInt8]?
    private(set) var done = 0
    private(set) var failures = 0

    init(model: MLModel, sourceWidth: Int, sourceHeight: Int, outputWidth: Int, outputHeight: Int) throws {
        self.model = model
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        // The official exports have a fixed input size (1280x720 here).
        let input = model.modelDescription.inputDescriptionsByName["src"]?.imageConstraint
        let inputWidth = input?.pixelsWide ?? RVMMatte.inputWidth, inputHeight = input?.pixelsHigh ?? RVMMatte.inputHeight
        var created: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created)
        guard let created else { throw MediaError.failed("VideoToolbox couldn't start a scaler") }
        session = created
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        inputPool = try makePixelBufferPool(width: inputWidth, height: inputHeight, pixelFormat: kCVPixelFormatType_32BGRA)
        outputPool = try makePixelBufferPool(width: outputWidth, height: outputHeight, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        content = RVMMatte.contentRect(width: sourceWidth, height: sourceHeight, inputWidth: inputWidth, inputHeight: inputHeight)
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    /// Mattes up to `count` frames into `writer`. Returns false at the end.
    func step(frames count: Int, from source: FramePrefetcher, into writer: EncodedMovieWriter) throws -> Bool {
        for _ in 0..<count {
            guard let frame = try source.next() else { return false }
            let matte: [UInt8]
            if let made = autoreleasepool(invoking: { self.matte(for: frame.buffer) }) {
                matte = made
            } else {
                // Core ML failed on this frame: hold the one before.
                failures += 1
                matte = last ?? [UInt8](repeating: 0, count: outputWidth * outputHeight)
            }
            last = matte
            var output: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &output)
            guard let output else { throw MediaError.failed("Out of memory for matte frames") }
            MatteBlender.copy(matte, width: outputWidth, height: outputHeight, into: output)
            try writer.append(output, at: frame.time)
            done += 1
        }
        return true
    }

    /// One frame: fitted into the model's input, the alpha cropped back out
    /// and scaled to the matte size. Nil if Core ML failed.
    func matte(for frame: CVPixelBuffer) -> [UInt8]? {
        var input: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, inputPool, &input)
        guard let input else { return nil }
        // The source's colour tags say how to turn its YCbCr into RGB.
        CVBufferPropagateAttachments(frame, input)
        guard VTPixelTransferSessionTransferImage(session, from: frame, to: input) == noErr else { return nil }
        var features: [String: MLFeatureValue] = ["src": MLFeatureValue(pixelBuffer: input)]
        for (name, value) in state { features[name] = MLFeatureValue(multiArray: value) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: features),
              let result = try? model.prediction(from: provider),
              let alpha = result.featureValue(for: "pha")?.imageBufferValue,
              CVPixelBufferGetPixelFormatType(alpha) == kCVPixelFormatType_OneComponent8 else { return nil }
        for index in 1...4 {
            if let next = result.featureValue(for: "r\(index)o")?.multiArrayValue { state["r\(index)i"] = next }
        }
        CVPixelBufferLockBaseAddress(alpha, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(alpha, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(alpha) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(alpha)
        var source = vImage_Buffer(
            data: base + Int(content.minY) * stride + Int(content.minX), height: vImagePixelCount(content.height),
            width: vImagePixelCount(content.width), rowBytes: stride
        )
        var out = [UInt8](repeating: 0, count: outputWidth * outputHeight)
        if Int(content.width) == outputWidth, Int(content.height) == outputHeight {
            // The usual case (16:9 into a 1080p matte): rows straight across.
            out.withUnsafeMutableBytes { raw in
                for row in 0..<outputHeight {
                    memcpy(raw.baseAddress! + row * outputWidth, source.data + row * stride, outputWidth)
                }
            }
            return out
        }
        let error = MatteBlender.withImage(&out, outputWidth, outputHeight) { destination in
            vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        return error == kvImageNoError ? out : nil
    }
}

/// Decodes a few frames ahead on its own thread, so decoding the next frame
/// overlaps the model working on this one.
final class FramePrefetcher: @unchecked Sendable {
    private let reader: VideoFrameReader
    private let depth: Int
    private let condition = NSCondition()
    private var queue: [(buffer: CVPixelBuffer, time: CMTime)] = []
    private var finished = false
    private var stopped = false
    private var failure: Error?

    init(reader: VideoFrameReader, depth: Int = 3) {
        self.reader = reader
        self.depth = depth
    }

    func start() {
        let thread = Thread { [self] in decodeLoop() }
        thread.name = "tandem.rvm.decode"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func decodeLoop() {
        while true {
            let frame: (buffer: CVPixelBuffer, time: CMTime)?
            do {
                frame = try autoreleasepool { try reader.next() }
            } catch {
                condition.lock()
                failure = error
                finished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            condition.lock()
            while queue.count >= depth, !stopped { condition.wait() }
            guard let frame, !stopped else {
                finished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            queue.append(frame)
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The next frame in order, nil at the end.
    func next() throws -> (buffer: CVPixelBuffer, time: CMTime)? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty, !finished { condition.wait() }
        if !queue.isEmpty {
            condition.broadcast()
            return queue.removeFirst()
        }
        if let failure { throw failure }
        return nil
    }

    func stop() {
        condition.lock()
        stopped = true
        queue.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}
