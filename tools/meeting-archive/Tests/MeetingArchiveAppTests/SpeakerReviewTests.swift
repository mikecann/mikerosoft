import AVFoundation
import AVKit
import Foundation
import XCTest
@testable import MeetingArchiveApp

final class SpeakerReviewTests: XCTestCase {
    func testReviewResponseDecodesNullablePredictionsCandidatesAndPlayback() throws {
        let meetingID = UUID()
        let data = Data("""
        {
          "schema_version": 1,
          "meeting_id": "\(meetingID.uuidString.lowercased())",
          "manifest_revision": 3,
          "speakers": [
            {
              "speaker_id": "SPEAKER_00",
              "name": null,
              "suggested_name": "Alex Chen",
              "suggestion_score": 0.87,
              "suggestion_margin": null,
              "embedding_available": true,
              "excerpts": [
                {
                  "start": 12.5,
                  "end": 18.25,
                  "text": "I can take that action.",
                  "channel_origin": "system",
                  "playback_path": "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/id/playback/meeting.mp4"
                }
              ]
            },
            {
              "speaker_id": "SPEAKER_01",
              "name": "Michael",
              "suggested_name": null,
              "suggestion_score": null,
              "suggestion_margin": null,
              "embedding_available": false,
              "excerpts": []
            }
          ],
          "calendar_candidates": [
            {"name":"Alex Chen","email":"alex@example.com","response_status":"accepted","source":"calendar"}
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(SpeakerReviewResponse.self, from: data)

        XCTAssertEqual(response.meetingID, meetingID)
        XCTAssertEqual(response.speakers[0].suggestedName, "Alex Chen")
        XCTAssertEqual(response.speakers[0].excerpts[0].start, 12.5)
        XCTAssertEqual(response.speakers[1].name, "Michael")
        XCTAssertEqual(response.calendarCandidates.first?.email, "alex@example.com")
    }

    func testDraftsAutofillExistingNameThenPredictionAndMarkOnlyPrediction() {
        let speakers = [
            SpeakerReviewSpeaker(
                speakerID: "known",
                name: "Michael",
                suggestedName: "Mike",
                suggestionScore: 0.9,
                suggestionMargin: 0.2,
                embeddingAvailable: true,
                excerpts: []
            ),
            SpeakerReviewSpeaker(
                speakerID: "predicted",
                name: nil,
                suggestedName: "Alex",
                suggestionScore: 0.8,
                suggestionMargin: 0.1,
                embeddingAvailable: true,
                excerpts: []
            ),
            SpeakerReviewSpeaker(
                speakerID: "unknown",
                name: nil,
                suggestedName: nil,
                suggestionScore: nil,
                suggestionMargin: nil,
                embeddingAvailable: false,
                excerpts: []
            ),
        ]

        let drafts = SpeakerReviewDraft.make(speakers: speakers)

        XCTAssertEqual(drafts["known"]?.name, "Michael")
        XCTAssertEqual(drafts["known"]?.isPredicted, false)
        XCTAssertEqual(drafts["predicted"]?.name, "Alex")
        XCTAssertEqual(drafts["predicted"]?.isPredicted, true)
        XCTAssertEqual(drafts["unknown"]?.name, "")
        XCTAssertEqual(drafts["unknown"]?.isPredicted, false)
    }

    func testRemoteShellQuotesArbitraryNamesAsOneLiteralArgument() {
        let name = "D'Angelo $(touch /tmp/nope); `whoami`\nSecond line"

        let quoted = RemoteShellCommand.quote(name)

        XCTAssertEqual(quoted, "'D'\"'\"'Angelo $(touch /tmp/nope); `whoami`\nSecond line'")
    }

    func testIdentifyRequestQuotesEveryRemoteArgument() throws {
        let meetingID = UUID()
        var configuration = ArchiveTransferConfiguration.bruce
        configuration.host = "test-host"
        let request = try SpeakerReviewCommandBuilder.identify(
            meetingID: meetingID,
            revision: 4,
            speakerID: "SPEAKER_00",
            name: "D'Angelo; echo bad",
            configuration: configuration
        )

        XCTAssertEqual(request.executable.path, "/usr/bin/ssh")
        XCTAssertEqual(request.arguments.dropLast().suffix(1), ["test-host"])
        let command = try XCTUnwrap(request.arguments.last)
        XCTAssertTrue(command.contains("'identify'"))
        XCTAssertTrue(command.contains("'--name' 'D'\"'\"'Angelo; echo bad'"))
        XCTAssertFalse(command.contains("--name D'Angelo"))
        XCTAssertEqual(request.timeout, configuration.commandTimeout)
    }

    func testReviewRequestUsesResolvedArchiveDirectoryAndWorkerTimeout() throws {
        let path = "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/meeting-id"
        let request = try SpeakerReviewCommandBuilder.review(
            archivePath: path,
            revision: 7,
            configuration: .bruce
        )
        let command = try XCTUnwrap(request.arguments.last)

        XCTAssertEqual(command.components(separatedBy: "'review-speakers'").count - 1, 1)
        XCTAssertTrue(command.contains("'--archive-dir' '\(path)'"))
        XCTAssertTrue(command.contains("'--revision' '7'"))
        XCTAssertEqual(request.timeout, ArchiveTransferConfiguration.bruce.workerTimeout)
    }

    func testReviewRequiresSafeLocatedArchiveAndExpectedIdentity() throws {
        let meetingID = UUID()
        let valid = LocatedSpeakerArchive(
            schemaVersion: 1,
            meetingID: meetingID,
            archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/\(meetingID.uuidString.lowercased())"
        )
        XCTAssertNoThrow(try valid.validate(meetingID: meetingID, configuration: .bruce))

        let traversal = LocatedSpeakerArchive(
            schemaVersion: 1,
            meetingID: meetingID,
            archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/../incoming/bad"
        )
        XCTAssertThrowsError(try traversal.validate(meetingID: meetingID, configuration: .bruce))
    }

    func testPlaybackRangeRejectsInvalidAndClampsNegativeStart() {
        XCTAssertEqual(SpeakerPlaybackRange(start: -2, end: 4)?.start, 0)
        XCTAssertEqual(SpeakerPlaybackRange(start: -2, end: 4)?.end, 4)
        XCTAssertNil(SpeakerPlaybackRange(start: 4, end: 4))
        XCTAssertNil(SpeakerPlaybackRange(start: .nan, end: 5))
    }

    @MainActor
    func testNativePlayerSurfaceAttachesAndDetachesPlayer() {
        let player = AVPlayer()
        let view = SpeakerPlayerSurface.make(player: player)

        XCTAssertTrue(view.player === player)
        XCTAssertEqual(view.controlsStyle, .inline)

        SpeakerPlayerSurface.dismantle(view)

        XCTAssertNil(view.player)
        XCTAssertEqual(player.rate, 0)
    }

    @MainActor
    func testLatePlaybackFetchCannotStartAfterReviewStops() async {
        let meetingID = UUID()
        let client = ControlledPlaybackReviewClient(meetingID: meetingID)
        let model = makeModel(meetingID: meetingID, client: client)
        let excerpt = SpeakerReviewExcerpt(
            start: 0,
            end: 1,
            text: "fixture",
            channelOrigin: "system",
            playbackPath: "playback/meeting.mp4"
        )

        let play = Task { await model.play(excerpt, speakerID: "pending") }
        await client.waitUntilFetchStarted()
        model.stopPlayback()
        await client.finishFetch()
        await play.value

        XCTAssertNil(model.player)
        XCTAssertNil(model.playbackStatus)
        XCTAssertFalse(model.isFetchingPlayback)
    }

    @MainActor
    func testLoadedSavedNamesRemainConfirmedOnReopen() async {
        let meetingID = UUID()
        let response = makeResponse(
            meetingID: meetingID,
            speakers: [makeSpeaker(id: "saved", name: "Michael"), makeSpeaker(id: "pending")]
        )
        let model = makeModel(meetingID: meetingID, client: StubSpeakerReviewClient(response: response))

        await model.load()

        XCTAssertEqual(model.confirmedSpeakerIDs, Set(["saved"]))
        XCTAssertEqual(model.remainingUnconfirmedCount, 1)
        XCTAssertFalse(model.canComplete)
    }

    @MainActor
    func testEditingSavedNameInvalidatesConfirmationUntilSuccessfulSave() async {
        let meetingID = UUID()
        let response = makeResponse(meetingID: meetingID, speakers: [makeSpeaker(id: "saved", name: "Michael")])
        var changedCount = 0
        let model = makeModel(
            meetingID: meetingID,
            client: StubSpeakerReviewClient(response: response),
            onReviewChanged: { changedCount += 1 }
        )
        await model.load()
        XCTAssertTrue(model.canComplete)

        model.setName("Mike", for: "saved")

        XCTAssertFalse(model.confirmedSpeakerIDs.contains("saved"))
        XCTAssertEqual(model.remainingUnconfirmedCount, 1)
        XCTAssertFalse(model.canComplete)
        let saved = await model.confirm("saved")
        XCTAssertTrue(saved)
        XCTAssertEqual(model.remainingUnconfirmedCount, 0)
        XCTAssertTrue(model.canComplete)
        XCTAssertEqual(changedCount, 1)
    }

    @MainActor
    func testFailedConfirmationNeverClearsPendingReviewOrCallsChangeCallback() async {
        let meetingID = UUID()
        let response = makeResponse(meetingID: meetingID, speakers: [makeSpeaker(id: "pending", suggestion: "Alex")])
        var changedCount = 0
        let client = StubSpeakerReviewClient(response: response, identifyFails: true)
        let model = makeModel(meetingID: meetingID, client: client, onReviewChanged: { changedCount += 1 })
        await model.load()

        let saved = await model.confirm("pending")
        XCTAssertFalse(saved)

        XCTAssertEqual(model.remainingUnconfirmedCount, 1)
        XCTAssertFalse(model.confirmedSpeakerIDs.contains("pending"))
        XCTAssertFalse(model.canComplete)
        XCTAssertNotNil(model.failure)
        XCTAssertEqual(changedCount, 0)
    }

    @MainActor
    func testZeroSpeakerResponseCanCompleteOnlyAfterItLoads() async {
        let meetingID = UUID()
        let response = makeResponse(meetingID: meetingID, speakers: [])
        let model = makeModel(meetingID: meetingID, client: StubSpeakerReviewClient(response: response))

        XCTAssertEqual(model.remainingUnconfirmedCount, 0)
        XCTAssertFalse(model.canComplete)

        await model.load()

        XCTAssertEqual(model.remainingUnconfirmedCount, 0)
        XCTAssertTrue(model.canComplete)
    }

    @MainActor
    func testPendingSpeakerBlocksCompletionUntilSuccessfulConfirmation() async {
        let meetingID = UUID()
        let response = makeResponse(meetingID: meetingID, speakers: [makeSpeaker(id: "pending", suggestion: "Alex")])
        let model = makeModel(meetingID: meetingID, client: StubSpeakerReviewClient(response: response))
        await model.load()

        XCTAssertFalse(model.canComplete)
        let saved = await model.confirm("pending")
        XCTAssertTrue(saved)
        XCTAssertTrue(model.canComplete)
    }

    @MainActor
    func testEditDuringConfirmationPreservesNewDraftAndKeepsCompletionPending() async {
        let meetingID = UUID()
        let response = makeResponse(meetingID: meetingID, speakers: [makeSpeaker(id: "pending", suggestion: "Alex")])
        let client = ControlledSpeakerReviewClient(response: response)
        var changedCount = 0
        let model = makeModel(meetingID: meetingID, client: client, onReviewChanged: { changedCount += 1 })
        await model.load()

        let confirmation = Task { await model.confirm("pending") }
        await client.waitUntilIdentifyStarted()
        XCTAssertFalse(model.canComplete)
        model.setName("Alicia", for: "pending")
        await client.finishIdentify()
        let savedCurrentDraft = await confirmation.value

        XCTAssertFalse(savedCurrentDraft)
        XCTAssertEqual(model.drafts["pending"]?.name, "Alicia")
        XCTAssertFalse(model.confirmedSpeakerIDs.contains("pending"))
        XCTAssertEqual(model.remainingUnconfirmedCount, 1)
        XCTAssertFalse(model.canComplete)
        XCTAssertEqual(changedCount, 1)
    }

    @MainActor
    private func makeModel(
        meetingID: UUID,
        client: any SpeakerReviewServing,
        onReviewChanged: @escaping () -> Void = {}
    ) -> SpeakerReviewModel {
        SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: client,
            onReviewChanged: onReviewChanged
        )
    }

    private func makeResponse(
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

    private func makeSpeaker(
        id: String,
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

private actor StubSpeakerReviewClient: SpeakerReviewServing {
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
        if identifyFails {
            throw SpeakerReviewError.invalidResponse("confirmation failed")
        }
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

private actor ControlledSpeakerReviewClient: SpeakerReviewServing {
    let response: SpeakerReviewResponse
    private var identifyStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(response: SpeakerReviewResponse) {
        self.response = response
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
        identifyStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { finishContinuation = $0 }
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

    func waitUntilIdentifyStarted() async {
        if identifyStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishIdentify() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        destination
    }
}

private actor ControlledPlaybackReviewClient: SpeakerReviewServing {
    let meetingID: UUID
    private var fetchStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchContinuation: CheckedContinuation<URL, Error>?

    init(meetingID: UUID) { self.meetingID = meetingID }

    func load(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerReviewResponse {
        SpeakerReviewResponse(
            schemaVersion: 1,
            meetingID: meetingID,
            manifestRevision: revision,
            speakers: [],
            calendarCandidates: []
        )
    }

    func identify(
        meetingID: UUID,
        revision: Int,
        speakerID: String,
        name: String,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerIdentificationResponse {
        throw SpeakerReviewError.invalidResponse("identify is not part of this fixture")
    }

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
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
