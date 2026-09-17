import AppKit
import AVFoundation
import AVKit
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
    private var identifyCalls = 0

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
        identifyCalls += 1
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

    func identifyCallCount() -> Int { identifyCalls }
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

private actor ControlledScenarioPlaybackService: SpeakerReviewServing {
    let meetingID: UUID
    private var fetchStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchContinuation: CheckedContinuation<URL, Error>?

    init(meetingID: UUID) { self.meetingID = meetingID }

    func load(meetingID: UUID, revision: Int, configuration: ArchiveTransferConfiguration) async throws -> SpeakerReviewResponse {
        SpeakerReviewResponse(
            schemaVersion: 1, meetingID: meetingID, manifestRevision: revision,
            speakers: [], calendarCandidates: []
        )
    }

    func identify(
        meetingID: UUID, revision: Int, speakerID: String, name: String,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerIdentificationResponse {
        throw SpeakerReviewError.invalidResponse("identify is not part of this fixture")
    }

    func fetchPlayback(
        meetingID: UUID, destination: URL, configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        fetchStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { fetchContinuation = $0 }
    }

    func waitUntilFetchStarted() async {
        if fetchStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishFetch() {
        fetchContinuation?.resume(returning: URL(fileURLWithPath: "/private/tmp/late-playback-fixture.mp4"))
        fetchContinuation = nil
    }
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

        let evidence = SpeakerEvidenceLabel(
            name: "Michael Cann",
            timestamps: [12.5, 42],
            source: "video_text"
        )
        let automaticResponse = response(
            meetingID: meetingID,
            speakers: [
                speaker(
                    "automatic",
                    suggestion: "Tentative fallback",
                    automaticName: "Mike Cann",
                    suggestionKind: "strong",
                    confirmationCount: 3
                ),
                speaker(
                    "tentative",
                    suggestion: "Alex Chen",
                    suggestionKind: "tentative",
                    evidenceLabels: [evidence]
                ),
            ]
        )
        let automaticService = ScenarioReviewService(response: automaticResponse)
        let automatic = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: automaticService
        )
        await automatic.load()
        try require(
            automatic.drafts["automatic"] == SpeakerReviewDraft(name: "Mike Cann", isPredicted: false),
            "strong automatic voice did not take priority over a tentative suggestion"
        )
        try require(automatic.confirmedSpeakerIDs.contains("automatic"), "strong automatic voice was not complete-capable")
        try require(
            automatic.drafts["tentative"] == SpeakerReviewDraft(name: "Alex Chen", isPredicted: true),
            "tentative suggestion was not presented as pending"
        )
        let unchangedAutomaticSave = await automatic.confirm("automatic")
        let callsAfterUnchangedAutomatic = await automaticService.identifyCallCount()
        try require(!unchangedAutomaticSave, "unchanged automatic voice tried to enroll again")
        try require(callsAfterUnchangedAutomatic == 0, "unchanged automatic voice called identify")

        automatic.setName("Michael Cann", for: "automatic")
        try require(!automatic.canComplete, "editing an automatic voice left review complete")
        let editedAutomaticSave = await automatic.confirm("automatic")
        let callsAfterEditedAutomatic = await automaticService.identifyCallCount()
        try require(editedAutomaticSave, "edited automatic voice could not be confirmed")
        try require(callsAfterEditedAutomatic == 1, "edited automatic voice did not call identify exactly once")
        try require(
            automatic.response?.speakers.first(where: { $0.speakerID == "automatic" })?.name == "Michael Cann",
            "explicit edit remained classified as an automatic match"
        )

        automatic.selectEvidence(evidence, for: "tentative")
        try require(automatic.drafts["tentative"]?.name == "Michael Cann", "visible label did not fill the draft")
        try require(
            !automatic.confirmedSpeakerIDs.contains("tentative") && !automatic.canComplete,
            "visible label evidence confirmed a speaker without user confirmation"
        )

        let oldResponse = try JSONDecoder().decode(
            SpeakerReviewResponse.self,
            from: Data("""
            {
              "schema_version": 1,
              "meeting_id": "\(meetingID.uuidString.lowercased())",
              "manifest_revision": 3,
              "speakers": [{
                "speaker_id": "old",
                "name": null,
                "suggested_name": null,
                "suggestion_score": null,
                "suggestion_margin": null,
                "embedding_available": false,
                "excerpts": []
              }],
              "calendar_candidates": []
            }
            """.utf8)
        )
        try require(oldResponse.speakers.first?.automaticName == nil, "old response did not decode without automatic fields")

        let invalidEvidenceResponse = response(
            meetingID: meetingID,
            speakers: [
                speaker(
                    "invalid-evidence",
                    evidenceLabels: [SpeakerEvidenceLabel(name: "", timestamps: [-1], source: "video_text")]
                ),
            ]
        )
        do {
            try invalidEvidenceResponse.validate(meetingID: meetingID, revision: 3)
            throw ScenarioFailure(description: "malformed visible label evidence passed validation")
        } catch is SpeakerReviewError {
            // Expected: visible labels must have a bounded name and valid time.
        }

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
        let playbackClient = ControlledScenarioPlaybackService(meetingID: meetingID)
        let stopped = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: playbackClient
        )
        let excerpt = SpeakerReviewExcerpt(
            start: 0, end: 1, text: "fixture", channelOrigin: "system",
            playbackPath: "playback/meeting.mp4"
        )
        let latePlayback = Task { await stopped.play(excerpt, speakerID: "pending") }
        await playbackClient.waitUntilFetchStarted()
        stopped.stopPlayback()
        await playbackClient.finishFetch()
        await latePlayback.value
        try require(stopped.player == nil && stopped.playbackStatus == nil, "late fetch restarted stopped playback")
        try require(!stopped.isFetchingPlayback, "late fetch left playback loading")

        try await verifyNativePlaybackSurface()
        print("Speaker review state, in-flight edit, and native playback surface scenarios passed")
    }

    @MainActor
    private static func verifyNativePlaybackSurface() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-speaker-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("valid.wav")
        try writeValidAudio(to: mediaURL)

        let player = AVPlayer(url: mediaURL)
        let view = SpeakerPlayerSurface.make(player: player)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        try require(view.player === player, "native player view did not retain the player")
        player.play()
        try await Task.sleep(for: .milliseconds(350))
        try require(player.currentTime().seconds > 0, "valid local media did not begin playback")

        SpeakerPlayerSurface.dismantle(view)
        window.contentView = nil
        try require(view.player == nil && player.rate == 0, "native player teardown did not stop playback")
    }

    private static func writeValidAudio(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let seconds: UInt32 = 2
        let dataSize = sampleRate * seconds * 2
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        try data.write(to: url)
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
        suggestion: String? = nil,
        automaticName: String? = nil,
        suggestionKind: String? = nil,
        confirmationCount: Int? = nil,
        evidenceLabels: [SpeakerEvidenceLabel]? = nil
    ) -> SpeakerReviewSpeaker {
        SpeakerReviewSpeaker(
            speakerID: id,
            name: name,
            suggestedName: suggestion,
            suggestionScore: nil,
            suggestionMargin: nil,
            embeddingAvailable: false,
            excerpts: [],
            automaticName: automaticName,
            suggestionKind: suggestionKind,
            confirmationCount: confirmationCount,
            evidenceLabels: evidenceLabels
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
