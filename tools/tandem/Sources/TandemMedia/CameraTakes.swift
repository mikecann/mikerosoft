import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis
import TandemCore
import Vision

/// Finds camera takes that aren't named like one: a phone video of Mike
/// talking to the camera (`source/IMG_0151.MOV`) rather than record-it's
/// `-camera.mov`. Such a video used to be `other`, so it had no transcript
/// until someone set its role by hand.
///
/// A new video whose name and folder don't say what it is becomes the
/// camera take when all three hold:
///
/// - It's a recording, not a render: its metadata names the camera that
///   shot it (phones and cameras write their make and model), or it's in
///   `source/`, where takes go. A render of an edit has a voice and a face
///   too, and Mike's older folders keep renders beside the project.
/// - It has a voice: Apple's sound classifier hears speech in at least a
///   quarter of a few seconds sampled across it. record-it takes, with
///   typing and pauses between sentences, score 30 to 70%.
/// - It shows a face: Vision finds one at least a tenth of the frame high
///   in two of six frames. That keeps out narrated screen recordings and
///   phone footage of hands at work with a voice over it.
public enum CameraTakes {
    /// Shorter videos aren't takes (a Live Photo's movie is about 3 s).
    static let minimumDuration = 4.0
    /// Stretches of sound sampled across a file, and their length. A file
    /// shorter than all of them together is heard whole.
    static let listenStretches = 6
    static let stretchSeconds = 3.0
    /// The classifier's window: shorter than its 3 s default, so a stretch
    /// gives several verdicts.
    static let classifierWindow = 1.5
    static let speechConfidence = 0.5
    /// Frames looked at for a face.
    static let faceFrames = 6
    /// Smaller faces are a webcam bubble in a screen recording, or someone
    /// in the background.
    static let minimumFaceHeight = 0.1

    /// Why `item`, a file just found, is a camera take, or nil when it isn't
    /// one (or its name or folder already said what it is).
    public static func reason(for item: MediaItem, at url: URL) async -> String? {
        guard isCandidate(item), let duration = item.duration?.seconds else { return nil }
        let source: String
        if let camera = await cameraName(of: url) {
            source = "\(article(for: camera)) \(camera) video"
        } else if isInTakesFolder(item.path) {
            source = "a video in source/"
        } else {
            return nil
        }
        guard let confidences = try? await speechConfidences(in: url, duration: duration), heardSpeech(confidences) else { return nil }
        guard let heights = try? await faceHeights(in: url, duration: duration), sawFace(heights) else { return nil }
        return "\(source) with speech and a face in it"
    }

    /// Videos worth a look and a listen: nothing about their name or folder
    /// said what they are, and they have a picture, sound and some length.
    static func isCandidate(_ item: MediaItem) -> Bool {
        item.kind == .video && item.role == .other && item.hasVideo && item.hasAudio
            && item.undecodableCodec == nil && (item.duration?.seconds ?? 0) >= minimumDuration
    }

    /// True for a path in the project folder's `source/`, where record-it
    /// and Mike put takes, at any depth.
    static func isInTakesFolder(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        return path.split(separator: "/").dropLast().contains { $0.lowercased() == "source" }
    }

    // MARK: - What made it

    /// The camera a file's metadata names ("Apple iPhone XS Max"), if any.
    static func cameraName(of url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        func string(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else { return nil }
            return try? await item.load(.stringValue)
        }
        return cameraName(make: await string(.commonIdentifierMake), model: await string(.commonIdentifierModel))
    }

    static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if make.isEmpty { return model.isEmpty ? nil : model }
        if model.isEmpty { return make }
        // Some cameras repeat the make in the model ("Canon EOS R6").
        return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
    }

    static func article(for word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }

    // MARK: - Listening

    /// Speech in two or more of the classifier's windows, and in at least a
    /// quarter of them.
    static func heardSpeech(_ confidences: [Double]) -> Bool {
        let heard = confidences.filter { $0 >= speechConfidence }.count
        return heard >= 2 && Double(heard) >= Double(confidences.count) / 4
    }

    /// Where to listen: the whole file when it's short, otherwise stretches
    /// spread evenly across it.
    static func listeningRanges(duration: Double) -> [CMTimeRange] {
        func range(_ start: Double, _ length: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        }
        guard duration > Double(listenStretches) * stretchSeconds else { return [range(0, duration)] }
        return (0..<listenStretches).map { index in
            let middle = duration * (Double(index) + 0.5) / Double(listenStretches)
            return range(middle - stretchSeconds / 2, stretchSeconds)
        }
    }

    /// How sure the classifier is of speech in each of its windows over the
    /// sampled stretches.
    static func speechConfidences(in url: URL, duration: Double) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let ranges = listeningRanges(duration: duration)
        return try await Blocking.run {
            // The classifier works at 16 kHz; the reader resamples to it.
            let sampleRate = 16_000.0
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return [] }
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: classifierWindow, preferredTimescale: 48_000)
            request.overlapFactor = 0.5
            let observer = SpeechObserver()
            try analyzer.add(request, withObserver: observer)
            // The stretches go in back to back, as if they were one recording.
            var position: AVAudioFramePosition = 0
            for range in ranges {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = range
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true,
                    AVLinearPCMIsBigEndianKey: false
                ])
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? MediaError.unreadable(url.lastPathComponent, "can't read its sound") }
                while let sample = output.copyNextSampleBuffer() {
                    let frames = CMSampleBufferGetNumSamples(sample)
                    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { continue }
                    analyzer.analyze(buffer, atAudioFramePosition: position)
                    position += AVAudioFramePosition(frames)
                }
                reader.cancelReading()
            }
            analyzer.completeAnalysis()
            return observer.confidences
        }
    }

    /// Collects the classifier's speech confidence for each window.
    private final class SpeechObserver: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        var confidences: [Double] { lock.withLock { values } }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let speech = result.classification(forIdentifier: "speech")?.confidence ?? 0
            lock.withLock { values.append(speech) }
        }
    }

    // MARK: - Looking

    /// A face at least a tenth of the frame high, in two frames or more.
    static func sawFace(_ heights: [Double]) -> Bool {
        heights.filter { $0 >= minimumFaceHeight }.count >= 2
    }

    /// The height of the biggest face Vision finds in each of six frames
    /// spread across the file, as a fraction of the frame's height (0 for
    /// none). Frames come upright, with the file's rotation applied.
    static func faceHeights(in url: URL, duration: Double) async throws -> [Double] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        // The nearest keyframe will do, and is much quicker to decode.
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var heights: [Double] = []
        for index in 0..<faceFrames {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(faceFrames), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else {
                heights.append(0)
                continue
            }
            heights.append(try await Blocking.run {
                let request = VNDetectFaceRectanglesRequest()
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                return (request.results ?? []).map { Double($0.boundingBox.height) }.max() ?? 0
            })
        }
        return heights
    }
}
