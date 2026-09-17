import Foundation

@main
enum MeetingFollowUpScenarios {
    static func main() throws {
        let first = SpeakerAttentionCandidate(meetingID: UUID(), revision: 2, remainingCount: 1)
        let second = SpeakerAttentionCandidate(meetingID: UUID(), revision: 1, remainingCount: 2)
        var tracker = SpeakerAttentionTracker()
        precondition(!SpeakerAttentionTracker.interactionIsSafe(noSupportedMeeting: false, cameraActive: nil))
        precondition(!SpeakerAttentionTracker.interactionIsSafe(noSupportedMeeting: false, cameraActive: true))
        precondition(SpeakerAttentionTracker.interactionIsSafe(noSupportedMeeting: false, cameraActive: false))
        precondition(SpeakerAttentionTracker.interactionIsSafe(noSupportedMeeting: true, cameraActive: nil))
        precondition(tracker.nextPresentation(from: [first], interactionBlocked: true) == nil,
                     "A new meeting or naming prompt must defer attention")
        precondition(tracker.nextPresentation(from: [first], interactionBlocked: false) == first)
        tracker.markPresented(first)
        precondition(tracker.nextPresentation(from: [first], interactionBlocked: false) == nil,
                     "Later must not reopen the same review every poll")
        precondition(tracker.nextPresentation(from: [first, second], interactionBlocked: false) == second,
                     "Deferring one review must not suppress another meeting")
        let restored = try JSONDecoder().decode(SpeakerAttentionTracker.self, from: JSONEncoder().encode(tracker))
        precondition(restored.nextPresentation(from: [first], interactionBlocked: false) == nil,
                     "Restart must preserve the one-time popup decision")
        let revised = SpeakerAttentionCandidate(meetingID: first.meetingID, revision: 3, remainingCount: 1)
        precondition(restored.nextPresentation(from: [revised], interactionBlocked: false) == revised)
        let complete = SpeakerAttentionCandidate(meetingID: first.meetingID, revision: 2, remainingCount: 0)
        precondition(tracker.nextPresentation(from: [complete], interactionBlocked: false) == nil)
        precondition(MeetingFollowUpPhase.transferring.isBusy)
        precondition(MeetingFollowUpPhase.processing.isBusy)
        precondition(MeetingFollowUpPhase.checking.isBusy)
        precondition(!MeetingFollowUpPhase.waiting("Bruce is offline").isBusy)
        precondition(!MeetingFollowUpPhase.needsNames(1).isBusy)
        precondition(!MeetingFollowUpPhase.complete.isBusy)
        precondition(MeetingFollowUpPhase.needsNames(1).detail == "1 speaker needs a name")
        precondition(MeetingFollowUpPhase.needsNames(2).detail == "2 speakers need names")
        func archived(revision: Int? = 2, succeeded: Bool = true, count: Int? = nil, error: String? = nil) -> MeetingFollowUpPhase {
            MeetingFollowUpPhase.afterArchive(expectedRevision: 2, workerRevision: revision,
                processingSucceeded: succeeded, remainingNames: count, processingError: nil, connectionError: error)
        }
        precondition(archived(count: 0) == .complete)
        precondition(archived(count: 1) == .needsNames(1))
        precondition(archived(succeeded: false) == .processing)
        precondition(archived() == .checking, "Missing analysis must not mean complete")
        precondition(archived(revision: 1, count: 0) == .checking, "Old revision must not clear new review")
        precondition(archived(revision: nil, count: 0) == .checking)
        precondition(archived(count: -1) == .checking)
        precondition(!archived(revision: nil, error: "Offline").isBusy, "Offline must not show an endless active spinner")
        print("Meeting follow-up progress, deferred attention, revision, and restart scenarios passed")
    }
}
