import Foundation
import Testing
@testable import RecordMeetingApp

@Suite("Transcript formatting")
struct TranscriptTests {
    @Test
    func speakerNamesReplaceMachineLabels() throws {
        let document = TranscriptDocument(
            segments: [
                .init(start: 0, end: 1.2, text: "Hello there.", speaker: "SPEAKER_00"),
                .init(start: 1.2, end: 3.4, text: "Hi Michael.", speaker: "SPEAKER_01")
            ],
            speakers: [
                .init(id: "SPEAKER_00", samplePath: "/tmp/one.mp3"),
                .init(id: "SPEAKER_01", samplePath: "/tmp/two.mp3")
            ]
        )

        let markdown = document.markdown(
            title: "Product catch-up",
            description: "Weekly planning",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 4),
            speakerNames: ["SPEAKER_00": "Michael", "SPEAKER_01": "Alex"],
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(markdown.contains("**Michael [00:00]**"))
        #expect(markdown.contains("**Alex [00:01]**"))
        #expect(markdown.contains("Weekly planning"))
        #expect(!markdown.contains("SPEAKER_00"))
    }

    @Test
    func unnamedSpeakerGetsFriendlyFallback() {
        #expect(TranscriptDocument.displayName(for: "SPEAKER_00", names: [:]) == "Speaker 1")
        #expect(TranscriptDocument.displayName(for: "SPEAKER_11", names: [:]) == "Speaker 12")
        #expect(TranscriptDocument.displayName(for: nil, names: [:]) == "Unknown speaker")
    }
}
