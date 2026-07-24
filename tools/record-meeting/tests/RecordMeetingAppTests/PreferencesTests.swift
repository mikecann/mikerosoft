import Foundation
import Testing
@testable import RecordMeetingApp

@Suite("Preferences")
struct PreferencesTests {
    @Test
    @MainActor
    func settingsRoundTrip() throws {
        let suite = "RecordMeetingTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = RecordMeetingPreferences(defaults: defaults)
        first.saveDirectory = "/tmp/meetings"
        first.notionParentPage = "abc"
        first.notionDataSourceID = "def"
        first.whisperModel = "large-v3"
        first.autoPublishToNotion = false

        let second = RecordMeetingPreferences(defaults: defaults)
        #expect(second.saveDirectory == "/tmp/meetings")
        #expect(second.notionParentPage == "abc")
        #expect(second.notionDataSourceID == "def")
        #expect(second.whisperModel == "large-v3")
        #expect(second.autoPublishToNotion == false)
    }
}
