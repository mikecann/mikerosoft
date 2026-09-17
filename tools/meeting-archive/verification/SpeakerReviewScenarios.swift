import Foundation

private struct ScenarioFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ScenarioFailure(description: message) }
}

private actor ScenarioReviewService: SpeakerReviewServing {
    let response: SpeakerReviewResponse
    let identifyFails: Bool

    init(response: SpeakerReviewResponse, identifyFails: Bool = false) {
        self.response = response
        self.identifyFails = identifyFails
    }

    func load(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerReviewResponse {
        response
    }

    func identify(
        meetingID: UUID,
        revision: Int,
        speakerID: String,
        name: String,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerIdentificationResponse {
        if identifyFails { throw SpeakerReviewError.invalidResponse("fixture confirmation failed") }
        return SpeakerIdentificationResponse(
            schemaVersion: 1,
            confirmed: true,
            meetingID: meetingID,
            manifestRevision: revision,
            speakerID: speakerID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            voiceProfileEnrolled: false
        )
    }

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        destination
    }
}

private actor ControlledScenarioReviewService: SpeakerReviewServing {
    let response: SpeakerReviewResponse
    private var identifyStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(response: SpeakerReviewResponse) { self.response = response }

    func load(meetingID: UUID, revision: Int, configuration: ArchiveTransferConfiguration) async throws -> SpeakerReviewResponse {
        response
    }

    func identify(
        meetingID: UUID, revision: Int, speakerID: String, name: String,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerIdentificationResponse {
        identifyStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { finishContinuation = $0 }
        return SpeakerIdentificationResponse(
            schemaVersion: 1, confirmed: true, meetingID: meetingID,
            manifestRevision: revision, speakerID: speakerID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), voiceProfileEnrolled: false
        )
    }

    func waitUntilIdentifyStarted() async {
        if identifyStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishIdentify() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func fetchPlayback(
        meetingID: UUID, destination: URL, configuration: ArchiveTransferConfiguration
    ) async throws -> URL { destination }
}

@main
private enum SpeakerReviewScenarios {
    @MainActor
    static func main() async throws {
        let meetingID = UUID()
        let reopened = response(
            meetingID: meetingID,
            speakers: [speaker("saved", name: "Michael"), speaker("pending", suggestion: "Alex")]
        )
        var reviewChanges = 0
        let model = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: ScenarioReviewService(response: reopened),
            onReviewChanged: { reviewChanges += 1 }
        )
        try require(!model.canComplete, "review completed before a response loaded")
        await model.load()
        try require(model.confirmedSpeakerIDs == ["saved"], "saved name was not restored as confirmed")
        try require(model.remainingUnconfirmedCount == 1, "reopened pending count was wrong")

        model.setName("Mike", for: "saved")
        try require(model.remainingUnconfirmedCount == 2, "edit did not invalidate saved confirmation")
        let savedEdit = await model.confirm("saved")
        try require(savedEdit, "edited saved speaker did not confirm")
        try require(model.remainingUnconfirmedCount == 1, "successful confirmation did not clear one pending speaker")
        try require(reviewChanges == 1, "successful confirmation did not publish review change")

        let failed = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: ScenarioReviewService(response: response(meetingID: meetingID, speakers: [speaker("pending", suggestion: "Alex")]), identifyFails: true),
            onReviewChanged: { reviewChanges += 1 }
        )
        await failed.load()
        let failedSave = await failed.confirm("pending")
        try require(!failedSave, "failed identification reported success")
        try require(failed.remainingUnconfirmedCount == 1, "failed identification cleared pending review")
        try require(!failed.canComplete, "failed identification enabled completion")
        try require(reviewChanges == 1, "failed identification published a review change")

        let controlledClient = ControlledScenarioReviewService(
            response: response(meetingID: meetingID, speakers: [speaker("pending", suggestion: "Alex")])
        )
        let controlled = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: controlledClient,
            onReviewChanged: { reviewChanges += 1 }
        )
        await controlled.load()
        let inFlight = Task { await controlled.confirm("pending") }
        await controlledClient.waitUntilIdentifyStarted()
        try require(!controlled.canComplete, "in-flight confirmation enabled completion")
        controlled.setName("Alicia", for: "pending")
        await controlledClient.finishIdentify()
        let savedCurrentDraft = await inFlight.value
        try require(!savedCurrentDraft, "stale confirmation blessed a newer draft")
        try require(controlled.drafts["pending"]?.name == "Alicia", "stale confirmation overwrote the newer draft")
        try require(controlled.remainingUnconfirmedCount == 1 && !controlled.canComplete, "newer draft did not remain pending")
        try require(reviewChanges == 2, "successful remote confirmation did not publish its status change")

        let empty = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: ScenarioReviewService(response: response(meetingID: meetingID, speakers: []))
        )
        try require(!empty.canComplete, "empty review completed before loading")
        await empty.load()
        try require(empty.remainingUnconfirmedCount == 0 && empty.canComplete, "loaded zero-speaker review could not complete")

        _ = SpeakerReviewView(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            onComplete: {},
            onReviewChanged: {},
            onLater: {}
        )
        print("Speaker review reopen, edit, failure, callback, and zero-speaker scenarios passed")
    }

    private static func response(
        meetingID: UUID,
        speakers: [SpeakerReviewSpeaker]
    ) -> SpeakerReviewResponse {
        SpeakerReviewResponse(
            schemaVersion: 1,
            meetingID: meetingID,
            manifestRevision: 3,
            speakers: speakers,
            calendarCandidates: []
        )
    }

    private static func speaker(
        _ id: String,
        name: String? = nil,
        suggestion: String? = nil
    ) -> SpeakerReviewSpeaker {
        SpeakerReviewSpeaker(
            speakerID: id,
            name: name,
            suggestedName: suggestion,
            suggestionScore: nil,
            suggestionMargin: nil,
            embeddingAvailable: false,
            excerpts: []
        )
    }
}
