import Foundation
import XCTest
@testable import MeetingArchiveCore

final class SQLiteMeetingStoreTests: XCTestCase {
    func testRecorderStateAndGlobalPauseSurviveReopen() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        var state = RecorderState()
        state.isPaused = true
        state.currentSession = ActiveMeetingSession(
            descriptor: meetingSession(id: "persisted"),
            phase: .suppressed(.paused),
            firstObservedAt: Date(timeIntervalSince1970: 1_800_000_000),
            meetingID: nil
        )
        try SQLiteMeetingStore(url: databaseURL).saveRecorderState(state)

        let restored = try SQLiteMeetingStore(url: databaseURL).loadRecorderState()
        XCTAssertEqual(restored, state)
    }

    func testAcceptanceResolutionIsAtomicAndDiscardCannotBeOverwritten() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord()
        try store.insertMeeting(record)

        let discarded = try store.resolveAcceptance(
            meetingID: record.id,
            resolution: .discard,
            at: record.endedAt.addingTimeInterval(1)
        )
        let afterTimeout = try store.resolveAcceptance(
            meetingID: record.id,
            resolution: .accept(trigger: .deadline),
            at: record.endedAt.addingTimeInterval(20)
        )

        XCTAssertEqual(discarded.acceptance, afterTimeout.acceptance)
        XCTAssertEqual(try store.fetchMeeting(id: record.id), afterTimeout)
    }

    func testMeetingAndJobAreInsertedInOneTransactionAndLeaseRecovers() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord().resolvingAcceptance(.accept(trigger: .keepButton), at: Date())
        let job = ArchiveJob(meetingID: record.id, manifestRevision: 1, createdAt: Date(timeIntervalSince1970: 1_800_000_000))

        try store.insertAcceptedMeeting(record, job: job)
        let firstLease = try XCTUnwrap(store.claimNextJob(now: Date(timeIntervalSince1970: 1_800_000_001), leaseDuration: 30))
        XCTAssertEqual(firstLease.id, job.id)
        XCTAssertNil(try store.claimNextJob(now: Date(timeIntervalSince1970: 1_800_000_010), leaseDuration: 30))
        XCTAssertEqual(
            try store.claimNextJob(now: Date(timeIntervalSince1970: 1_800_000_032), leaseDuration: 30)?.id,
            job.id
        )
    }

    func testExistingPendingMeetingAcceptsAndEnqueuesIdempotentlyInOneTransaction() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord()
        let job = ArchiveJob(meetingID: record.id, manifestRevision: 1, createdAt: record.endedAt)
        try store.insertMeeting(record)

        let accepted = try store.resolveAcceptanceAndEnqueue(
            id: record.id,
            resolution: .accept(trigger: .deadline),
            at: record.endedAt.addingTimeInterval(20),
            job: job
        )
        _ = try store.resolveAcceptanceAndEnqueue(
            id: record.id,
            resolution: .accept(trigger: .deadline),
            at: record.endedAt.addingTimeInterval(21),
            job: job
        )

        XCTAssertFalse(accepted.acceptance.isPending)
        XCTAssertEqual(try store.listJobs().map(\.id), [job.id])
    }

    func testRetryAndSuccessfulAcknowledgementRemainDurable() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord().resolvingAcceptance(.accept(trigger: .keepButton), at: Date())
        let job = ArchiveJob(meetingID: record.id, manifestRevision: 1, createdAt: record.endedAt)
        try store.insertAcceptedMeeting(record, job: job)

        try store.scheduleRetry(jobID: job.id, availableAt: record.endedAt.addingTimeInterval(60), error: "Bruce unavailable")
        XCTAssertEqual(try store.fetchJob(id: job.id)?.status, .retryScheduled)
        XCTAssertEqual(try store.fetchJob(id: job.id)?.lastError, "Bruce unavailable")

        let acknowledgement = ArchiveAcknowledgement(
            meetingID: record.id,
            manifestRevision: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            archivePath: "/Volumes/CannMedia/MeetingArchive/test",
            acceptedAt: record.endedAt.addingTimeInterval(90),
            verifiedFiles: [],
            queueJobID: job.id.uuidString.lowercased(),
            cleanupAllowed: true
        )
        try store.acknowledgeJob(id: job.id, acknowledgement: acknowledgement)
        XCTAssertEqual(try store.fetchJob(id: job.id)?.status, .succeeded)
        XCTAssertEqual(try store.fetchJob(id: job.id)?.acknowledgement, acknowledgement)
    }

    private func temporaryDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("meeting-archive.sqlite3")
    }

    private func meetingSession(id: String) -> MeetingSessionDescriptor {
        MeetingSessionDescriptor(
            id: id,
            sourceApplication: .init(bundleIdentifier: "com.google.Chrome", displayName: "Chrome", kind: .googleMeet),
            surface: .init(id: "window-1", title: "Meet", kind: .meeting),
            attribution: .positive
        )
    }

    private func meetingRecord() -> MeetingRecord {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return MeetingRecord(
            id: UUID(),
            title: "Meeting",
            sourceApplication: .init(bundleIdentifier: "com.google.Chrome", displayName: "Chrome", kind: .googleMeet),
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            timezoneIdentifier: "Australia/Perth",
            video: .init(surfaceID: "window-1", codec: "hevc", width: 1920, height: 1080),
            microphone: .init(deviceUID: "default", displayName: "Default", sampleRate: 48_000, channels: 1),
            incomingAudio: .init(sourceApplicationBundleIdentifier: "com.google.Chrome", sampleRate: 48_000, channels: 2),
            finalizedAt: start.addingTimeInterval(60)
        )
    }
}
