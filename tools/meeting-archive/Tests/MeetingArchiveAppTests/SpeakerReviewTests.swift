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
}
