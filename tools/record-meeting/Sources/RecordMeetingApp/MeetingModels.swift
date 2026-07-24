import Foundation

enum MeetingFiles {
    static func defaultDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent("RecordedMeetings", isDirectory: true)
    }

    static func fileStem(
        title: String,
        startedAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let safe = folded
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = safe.isEmpty ? "meeting" : String(safe.prefix(70))
        return "\(formatter.string(from: startedAt))-\(suffix)"
    }
}

struct TranscriptSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
}

struct DetectedSpeaker: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let samplePath: String

    enum CodingKeys: String, CodingKey {
        case id
        case samplePath = "sample_path"
    }
}

struct TranscriptDocument: Codable, Equatable, Sendable {
    let segments: [TranscriptSegment]
    let speakers: [DetectedSpeaker]

    static func displayName(for speaker: String?, names: [String: String]) -> String {
        guard let speaker else { return "Unknown speaker" }
        if let name = names[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if let suffix = speaker.split(separator: "_").last,
           let index = Int(suffix) {
            return "Speaker \(index + 1)"
        }
        return speaker
    }

    func markdown(
        title: String,
        description: String,
        startedAt: Date,
        endedAt: Date,
        speakerNames: [String: String],
        timeZone: TimeZone = .current
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "d MMMM yyyy 'at' h:mm a zzz"

        let duration = max(0, endedAt.timeIntervalSince(startedAt))
        var lines = [
            "# \(title)",
            "",
            "- Started: \(dateFormatter.string(from: startedAt))",
            "- Duration: \(Self.durationString(duration))",
            "- Speakers: \(speakers.map { Self.displayName(for: $0.id, names: speakerNames) }.joined(separator: ", "))",
        ]
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty {
            lines += ["", "## Description", "", trimmedDescription]
        }
        lines += ["", "## Transcript", ""]

        for segment in segments {
            let name = Self.displayName(for: segment.speaker, names: speakerNames)
            lines += [
                "**\(name) [\(Self.timestamp(segment.start))]**",
                "",
                segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                "",
            ]
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    static func durationString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }
}

struct MeetingMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let description: String
    let startedAt: Date
    let endedAt: Date
    let audioFile: String
    let transcriptFile: String
    let speakers: [String]

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

struct ProcessedMeeting: Identifiable, Sendable {
    let document: TranscriptDocument
    let rawCaptureURL: URL
    let audioURL: URL
    let transcriptJSONURL: URL
    let transcriptMarkdownURL: URL
    let metadataURL: URL
    let startedAt: Date
    let endedAt: Date
    let title: String
    let description: String
    let waveformSamples: [Double]

    var id: String { audioURL.path }
}
