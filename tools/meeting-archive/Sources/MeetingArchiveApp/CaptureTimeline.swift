import Foundation

enum MediaTrack: String, Codable, CaseIterable, Sendable {
    case video, microphone, incoming
}

struct TrackProgress: Codable, Sendable {
    let firstOffset: Double
    var lastOffset: Double
    var endOffset: Double
    var sampleCount: Int
}

struct CaptureTimeline: Sendable {
    let origin: Double
    private(set) var tracks: [MediaTrack: TrackProgress] = [:]
    var duration: Double { tracks.values.map(\.endOffset).max() ?? 0 }

    @discardableResult
    mutating func accept(track: MediaTrack, timestamp: Double, duration: Double) throws -> Double {
        let offset = timestamp - origin
        guard timestamp.isFinite, origin.isFinite, duration.isFinite, duration >= 0, offset >= 0 else {
            throw CaptureFailure.invalidTimestamp
        }
        if let previous = tracks[track], offset < previous.lastOffset {
            throw CaptureFailure.reversedTimestamp
        }
        var progress = tracks[track] ?? TrackProgress(firstOffset: offset, lastOffset: offset, endOffset: offset, sampleCount: 0)
        progress.lastOffset = offset
        progress.endOffset = max(progress.endOffset, offset + duration)
        progress.sampleCount += 1
        tracks[track] = progress
        return offset
    }
}

enum CaptureFailure: LocalizedError {
    case invalidTimestamp, reversedTimestamp
    case message(String)
    var errorDescription: String? {
        switch self {
        case .invalidTimestamp: return "Capture produced an invalid timestamp."
        case .reversedTimestamp: return "Capture timestamps moved backwards."
        case .message(let message): return message
        }
    }
}
