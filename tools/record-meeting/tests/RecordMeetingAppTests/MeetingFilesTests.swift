import Foundation
import Testing
@testable import RecordMeetingApp

@Suite("Meeting files")
struct MeetingFilesTests {
    @Test
    func defaultsToRecordedMeetingsInHomeDirectory() {
        let home = URL(fileURLWithPath: "/Users/mike", isDirectory: true)

        #expect(MeetingFiles.defaultDirectory(homeDirectory: home).path == "/Users/mike/RecordedMeetings")
    }

    @Test
    func makesStableSafeFileStem() {
        let date = Date(timeIntervalSince1970: 1_735_689_600)

        #expect(
            MeetingFiles.fileStem(
                title: "Weekly / product: catch-up?",
                startedAt: date,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ) == "2025-01-01-000000-weekly-product-catch-up"
        )
    }

    @Test
    func fallsBackToMeetingWhenTitleHasNoSafeCharacters() {
        let date = Date(timeIntervalSince1970: 1_735_689_600)

        #expect(
            MeetingFiles.fileStem(
                title: "  🎙️  ",
                startedAt: date,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ) == "2025-01-01-000000-meeting"
        )
    }
}
