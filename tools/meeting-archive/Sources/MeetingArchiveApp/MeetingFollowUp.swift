import Foundation

enum MeetingFollowUpPhase: Equatable {
    case transferring
    case processing
    case checking
    case waiting(String)
    case needsNames(Int)
    case complete

    static func afterArchive(
        expectedRevision: Int, workerRevision: Int?, processingSucceeded: Bool,
        remainingNames: Int?, processingError: String?, connectionError: String?
    ) -> Self {
        guard workerRevision == expectedRevision else {
            return connectionError.map { .waiting("Bruce is unavailable. Processing will continue when connected. \($0)") } ?? .checking
        }
        if processingSucceeded {
            guard let count = remainingNames, count >= 0 else { return .checking }
            return count == 0 ? .complete : .needsNames(count)
        }
        if let processingError { return .waiting(processingError) }
        if let connectionError { return .waiting("Bruce status unavailable: \(connectionError)") }
        return .processing
    }

    var isBusy: Bool {
        switch self {
        case .transferring, .processing, .checking: true
        case .waiting, .needsNames, .complete: false
        }
    }

    var detail: String {
        switch self {
        case .transferring: "Saving recording to Bruce"
        case .processing: "Transcribing audio and identifying speaker voices on Bruce"
        case .checking: "Checking speaker analysis on Bruce"
        case .waiting(let reason): reason
        case .needsNames(let count): count == 1 ? "1 speaker needs a name" : "\(count) speakers need names"
        case .complete: "Speaker review complete"
        }
    }
}

struct SpeakerAttentionCandidate: Equatable {
    var meetingID: UUID
    var revision: Int
    var remainingCount: Int

    var key: String { "\(meetingID.uuidString.lowercased()):\(revision)" }
}

/// Dismissing a prompt only suppresses its automatic presentation. The worker's
/// confirmed speaker assignments remain the source of truth for completion.
struct SpeakerAttentionTracker: Codable, Equatable {
    private(set) var presentedKeys: Set<String> = []

    static func interactionIsSafe(noSupportedMeeting: Bool, cameraActive: Bool?) -> Bool {
        noSupportedMeeting || cameraActive == false
    }

    func nextPresentation(
        from candidates: [SpeakerAttentionCandidate],
        interactionBlocked: Bool
    ) -> SpeakerAttentionCandidate? {
        guard !interactionBlocked else { return nil }
        return candidates.first { $0.remainingCount > 0 && !presentedKeys.contains($0.key) }
    }

    mutating func markPresented(_ candidate: SpeakerAttentionCandidate) {
        presentedKeys.insert(candidate.key)
    }
}
