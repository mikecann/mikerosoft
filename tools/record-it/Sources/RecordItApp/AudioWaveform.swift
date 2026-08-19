import AVFoundation
import Foundation

func normalizedAudioLevel(decibels: Float, floor: Float = -60) -> Float {
    guard decibels.isFinite, floor < 0 else { return 0 }
    let clamped = min(0, max(floor, decibels))
    return (clamped - floor) / -floor
}

func peakDecibels(in buffer: AVAudioPCMBuffer) -> Float {
    let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    var peak: Float = 0

    for audioBuffer in audioBuffers {
        guard let data = audioBuffer.mData else { continue }
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0 ..< count {
                peak = max(peak, abs(samples[index]))
            }
        case .pcmFormatFloat64:
            let samples = data.assumingMemoryBound(to: Double.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
            for index in 0 ..< count {
                peak = max(peak, Float(abs(samples[index])))
            }
        case .pcmFormatInt16:
            let samples = data.assumingMemoryBound(to: Int16.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
            for index in 0 ..< count {
                peak = max(peak, abs(Float(samples[index])) / Float(Int16.max))
            }
        case .pcmFormatInt32:
            let samples = data.assumingMemoryBound(to: Int32.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
            for index in 0 ..< count {
                peak = max(peak, abs(Float(samples[index])) / Float(Int32.max))
            }
        case .otherFormat:
            return -160
        @unknown default:
            return -160
        }
    }

    guard peak > 0 else { return -160 }
    return 20 * log10(min(1, peak))
}

func audioFingerprint(in buffer: AVAudioPCMBuffer) -> UInt64 {
    // FNV-1a is intentionally simple and deterministic. We only compare
    // fingerprints inside one recording to identify byte-for-byte replayed
    // PCM buffers, not to provide cryptographic integrity.
    var hash: UInt64 = 14_695_981_039_346_656_037
    let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    for audioBuffer in audioBuffers {
        guard let data = audioBuffer.mData else { continue }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<Int(audioBuffer.mDataByteSize) {
            hash ^= UInt64(bytes[index])
            hash &*= 1_099_511_628_211
        }
    }
    return hash
}

struct AudioWaveformBuffer: Equatable, Sendable {
    let capacity: Int
    private(set) var levels: [Float] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(decibels: Float) {
        levels.append(normalizedAudioLevel(decibels: decibels))
        if levels.count > capacity {
            levels.removeFirst(levels.count - capacity)
        }
    }
}
