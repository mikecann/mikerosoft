import Foundation

func normalizedAudioLevel(decibels: Float, floor: Float = -60) -> Float {
    guard decibels.isFinite, floor < 0 else { return 0 }
    let clamped = min(0, max(floor, decibels))
    return (clamped - floor) / -floor
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
