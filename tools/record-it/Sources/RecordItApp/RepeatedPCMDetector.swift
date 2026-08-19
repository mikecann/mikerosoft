import AVFoundation
import Foundation

struct PCMByteChunk: Sendable {
    let data: Data
    let frameCount: Int
    let sampleRate: Double
    let bytesPerFrame: Int
}

func pcmByteChunk(from buffer: AVAudioPCMBuffer) -> PCMByteChunk? {
    let frameCount = Int(buffer.frameLength)
    let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    guard frameCount > 0, !audioBuffers.isEmpty else { return nil }

    if audioBuffers.count == 1, let pointer = audioBuffers[0].mData {
        let byteCount = Int(audioBuffers[0].mDataByteSize)
        guard byteCount > 0, byteCount.isMultiple(of: frameCount) else { return nil }
        return PCMByteChunk(
            data: Data(bytes: pointer, count: byteCount),
            frameCount: frameCount,
            sampleRate: buffer.format.sampleRate,
            bytesPerFrame: byteCount / frameCount
        )
    }

    // Non-interleaved PCM arrives as one buffer per channel. Normalize it to
    // frame-interleaved bytes so callback boundaries cannot affect matching.
    let bytesPerChannelFrame = audioBuffers.compactMap { audioBuffer -> Int? in
        guard audioBuffer.mData != nil else { return nil }
        let byteCount = Int(audioBuffer.mDataByteSize)
        return byteCount.isMultiple(of: frameCount) ? byteCount / frameCount : nil
    }
    guard bytesPerChannelFrame.count == audioBuffers.count else { return nil }
    let bytesPerFrame = bytesPerChannelFrame.reduce(0, +)
    var data = Data(capacity: frameCount * bytesPerFrame)
    for frame in 0 ..< frameCount {
        for (index, audioBuffer) in audioBuffers.enumerated() {
            guard let pointer = audioBuffer.mData else { return nil }
            let width = bytesPerChannelFrame[index]
            data.append(pointer.assumingMemoryBound(to: UInt8.self) + frame * width, count: width)
        }
    }
    return PCMByteChunk(
        data: data,
        frameCount: frameCount,
        sampleRate: buffer.format.sampleRate,
        bytesPerFrame: bytesPerFrame
    )
}

struct RepeatedPCMDetector {
    private let minimumPeriod: TimeInterval
    private let maximumPeriod: TimeInterval
    private let requiredMatchDuration: TimeInterval
    private let retainedDuration: TimeInterval
    private let analysisInterval: TimeInterval
    private let needleFrameCount: Int

    private var history = Data()
    private var historyStartFrame: Int64 = 0
    private var totalFrames: Int64 = 0
    private var lastAnalysisFrame: Int64 = 0
    private var sampleRate: Double?
    private var bytesPerFrame: Int?

    init(
        minimumPeriod: TimeInterval = 0.5,
        maximumPeriod: TimeInterval = 30,
        requiredMatchDuration: TimeInterval = 3,
        retainedDuration: TimeInterval = 40,
        analysisInterval: TimeInterval = 1,
        needleFrameCount: Int = 4_096
    ) {
        self.minimumPeriod = minimumPeriod
        self.maximumPeriod = maximumPeriod
        self.requiredMatchDuration = requiredMatchDuration
        self.retainedDuration = retainedDuration
        self.analysisInterval = analysisInterval
        self.needleFrameCount = needleFrameCount
    }

    mutating func append(_ chunk: PCMByteChunk) -> TimeInterval? {
        guard
            chunk.frameCount > 0,
            chunk.sampleRate > 0,
            chunk.bytesPerFrame > 0,
            chunk.data.count == chunk.frameCount * chunk.bytesPerFrame
        else { return nil }

        if sampleRate != chunk.sampleRate || bytesPerFrame != chunk.bytesPerFrame {
            reset(sampleRate: chunk.sampleRate, bytesPerFrame: chunk.bytesPerFrame)
        }
        history.append(chunk.data)
        totalFrames += Int64(chunk.frameCount)

        let intervalFrames = Int64(max(1, Int(chunk.sampleRate * analysisInterval)))
        guard totalFrames - lastAnalysisFrame >= intervalFrames else { return nil }
        lastAnalysisFrame = totalFrames
        trimHistory()
        return findRepeatedPeriod()
    }

    private mutating func reset(sampleRate: Double, bytesPerFrame: Int) {
        history.removeAll(keepingCapacity: true)
        historyStartFrame = 0
        totalFrames = 0
        lastAnalysisFrame = 0
        self.sampleRate = sampleRate
        self.bytesPerFrame = bytesPerFrame
    }

    private mutating func trimHistory() {
        guard let sampleRate, let bytesPerFrame else { return }
        let retainedFrames = Int64(sampleRate * retainedDuration)
        let framesToRemove = max(0, totalFrames - historyStartFrame - retainedFrames)
        guard framesToRemove > 0 else { return }
        history.removeFirst(Int(framesToRemove) * bytesPerFrame)
        historyStartFrame += framesToRemove
    }

    private func findRepeatedPeriod() -> TimeInterval? {
        guard let sampleRate, let bytesPerFrame else { return nil }
        let confirmFrames = Int64(sampleRate * requiredMatchDuration)
        let minimumPeriodFrames = Int64(sampleRate * minimumPeriod)
        let maximumPeriodFrames = Int64(sampleRate * maximumPeriod)
        let needleFrames = Int64(min(needleFrameCount, Int(confirmFrames)))
        guard totalFrames - historyStartFrame >= confirmFrames + minimumPeriodFrames,
              needleFrames > 0
        else { return nil }

        let needleStartFrame = totalFrames - needleFrames
        let candidateStartFrame = max(historyStartFrame, needleStartFrame - maximumPeriodFrames)
        let candidateEndFrame = needleStartFrame - minimumPeriodFrames
        guard candidateStartFrame <= candidateEndFrame else { return nil }

        let needle = dataSlice(from: needleStartFrame, frameCount: needleFrames)
        guard !allFramesAreIdentical(in: needle, bytesPerFrame: bytesPerFrame) else { return nil }

        let searchStartOffset = byteOffset(for: candidateStartFrame)
        let searchEndOffset = min(
            byteOffset(for: candidateEndFrame + needleFrames),
            history.count
        )
        let searchStart = history.index(history.startIndex, offsetBy: searchStartOffset)
        let searchEnd = history.index(history.startIndex, offsetBy: searchEndOffset)
        var remainingRange = searchStart ..< searchEnd
        var shortestConfirmedPeriod: Int64?

        while remainingRange.count >= needle.count,
              let match = history.range(of: needle, options: [], in: remainingRange) {
            let matchedByteOffset = history.distance(from: history.startIndex, to: match.lowerBound)
            if matchedByteOffset.isMultiple(of: bytesPerFrame) {
                let matchedFrame = historyStartFrame + Int64(matchedByteOffset / bytesPerFrame)
                let periodFrames = needleStartFrame - matchedFrame
                if periodFrames >= minimumPeriodFrames,
                   periodFrames <= maximumPeriodFrames,
                   confirmsCurrentAudioRepeats(periodFrames: periodFrames, frameCount: confirmFrames) {
                    shortestConfirmedPeriod = min(shortestConfirmedPeriod ?? periodFrames, periodFrames)
                }
            }
            let next = history.index(after: match.lowerBound)
            guard next < remainingRange.upperBound else { break }
            remainingRange = next ..< remainingRange.upperBound
        }

        return shortestConfirmedPeriod.map { TimeInterval($0) / sampleRate }
    }

    private func confirmsCurrentAudioRepeats(periodFrames: Int64, frameCount: Int64) -> Bool {
        let currentStart = totalFrames - frameCount
        let previousStart = currentStart - periodFrames
        guard previousStart >= historyStartFrame else { return false }
        return dataSlice(from: currentStart, frameCount: frameCount)
            == dataSlice(from: previousStart, frameCount: frameCount)
    }

    private func dataSlice(from startFrame: Int64, frameCount: Int64) -> Data.SubSequence {
        let start = history.index(
            history.startIndex,
            offsetBy: byteOffset(for: startFrame)
        )
        let end = history.index(
            start,
            offsetBy: Int(frameCount) * (bytesPerFrame ?? 0)
        )
        return history[start ..< end]
    }

    private func byteOffset(for frame: Int64) -> Int {
        Int(frame - historyStartFrame) * (bytesPerFrame ?? 0)
    }

    private func allFramesAreIdentical(
        in data: Data.SubSequence,
        bytesPerFrame: Int
    ) -> Bool {
        guard data.count > bytesPerFrame else { return true }
        let firstFrame = data.prefix(bytesPerFrame)
        var offset = bytesPerFrame
        while offset < data.count {
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: bytesPerFrame)
            if data[start ..< end] != firstFrame { return false }
            offset += bytesPerFrame
        }
        return true
    }
}

final class RepeatedPCMMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.mikerosoft.record-it.audio-repeat-detector",
        qos: .utility
    )
    private var detector = RepeatedPCMDetector()
    private var hasReportedFailure = false
    private let onRepeatedAudio: @Sendable (TimeInterval) -> Void

    init(onRepeatedAudio: @escaping @Sendable (TimeInterval) -> Void) {
        self.onRepeatedAudio = onRepeatedAudio
    }

    func append(_ chunk: PCMByteChunk) {
        queue.async { [self] in
            guard !hasReportedFailure, let period = detector.append(chunk) else { return }
            hasReportedFailure = true
            onRepeatedAudio(period)
        }
    }
}
