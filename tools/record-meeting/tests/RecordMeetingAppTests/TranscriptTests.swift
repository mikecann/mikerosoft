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

    @Test
    func activeSegmentTracksPlaybackAndHandlesGaps() {
        let segments = [
            TranscriptSegment(start: 0, end: 1.5, text: "First", speaker: "SPEAKER_00"),
            TranscriptSegment(start: 2, end: 4, text: "Second", speaker: "SPEAKER_01"),
        ]

        #expect(TranscriptTimeline.activeSegmentIndex(at: 0.5, segments: segments) == 0)
        #expect(TranscriptTimeline.activeSegmentIndex(at: 1.75, segments: segments) == nil)
        #expect(TranscriptTimeline.activeSegmentIndex(at: 3.25, segments: segments) == 1)
        #expect(TranscriptTimeline.activeSegmentIndex(at: 5, segments: segments) == nil)
    }

    @Test
    func waveformResamplingKeepsPeaksAndRequestedWidth() {
        let samples = [0.1, 0.8, 0.2, 0.4, 1.4, -0.3]

        let resampled = WaveformMath.resample(samples, targetCount: 3)

        #expect(resampled == [0.8, 0.4, 1.0])
        #expect(WaveformMath.resample([], targetCount: 4) == [])
        #expect(WaveformMath.resample(samples, targetCount: 0) == [])
    }

    @Test
    func audioPowerIsClampedAndMakesQuietAudioVisible() {
        #expect(WaveformMath.normalizedPower(meanSquare: 0) == 0)
        #expect(WaveformMath.normalizedPower(meanSquare: 1) == 1)
        #expect(WaveformMath.normalizedPower(meanSquare: 4) == 1)
        #expect(WaveformMath.normalizedPower(meanSquare: 0.0001) > 0)
    }
}
