import Foundation
import XCTest
@testable import MeetingArchiveCore

final class MeetingRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFinalizedMeetingDefaultsToAcceptanceAfterTwentySeconds() {
        let record = makeRecord()

        XCTAssertEqual(record.acceptance, .pending(deadline: start.addingTimeInterval(80)))
        XCTAssertNil(record.resolvingDeadline(at: start.addingTimeInterval(79)))
        XCTAssertEqual(
            record.resolvingDeadline(at: start.addingTimeInterval(80))?.acceptance,
            .accepted(at: start.addingTimeInterval(80), trigger: .deadline)
        )
    }

    func testClosingPromptAcceptsImmediately() {
        let record = makeRecord()
        XCTAssertEqual(
            record.resolvingAcceptance(.accept(trigger: .promptClosed), at: start.addingTimeInterval(65)).acceptance,
            .accepted(at: start.addingTimeInterval(65), trigger: .promptClosed)
        )
    }

    func testExplicitDiscardWinsDurablyOnce() {
        let discarded = makeRecord().resolvingAcceptance(.discard, at: start.addingTimeInterval(65))
        let lateAcceptance = discarded.resolvingAcceptance(.accept(trigger: .deadline), at: start.addingTimeInterval(80))

        XCTAssertEqual(lateAcceptance.acceptance, .discarded(at: start.addingTimeInterval(65)))
    }

    func testTitleUpdatesRemainIndependentOfAcceptance() {
        let accepted = makeRecord().resolvingAcceptance(.accept(trigger: .keepButton), at: start.addingTimeInterval(65))
        let renamed = accepted.updatingTitle("Architecture catch-up", at: start.addingTimeInterval(90))

        XCTAssertEqual(renamed.title, "Architecture catch-up")
        XCTAssertEqual(renamed.metadataRevision, accepted.metadataRevision + 1)
        XCTAssertEqual(renamed.acceptance, accepted.acceptance)
    }

    func testVersionedModelRoundTripsDatesInUTC() throws {
        let data = try ModelCodec.encoder.encode(makeRecord())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("Z\""), json)

        let decoded = try ModelCodec.decoder.decode(MeetingRecord.self, from: data)
        XCTAssertEqual(decoded, makeRecord())
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    private func makeRecord() -> MeetingRecord {
        MeetingRecord(
            id: UUID(uuidString: "3f679acb-96d4-4ee0-aa4e-36e96a1fe41d")!,
            title: "Weekly catch-up",
            sourceApplication: .init(bundleIdentifier: "us.zoom.xos", displayName: "Zoom", kind: .zoom),
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            timezoneIdentifier: "Australia/Perth",
            video: .init(surfaceID: "window-1", codec: "hevc", width: 1920, height: 1080),
            microphone: .init(deviceUID: "default-input", displayName: "Default microphone", sampleRate: 48_000, channels: 1),
            incomingAudio: .init(sourceApplicationBundleIdentifier: "us.zoom.xos", sampleRate: 48_000, channels: 2),
            finalizedAt: start.addingTimeInterval(60)
        )
    }
}
