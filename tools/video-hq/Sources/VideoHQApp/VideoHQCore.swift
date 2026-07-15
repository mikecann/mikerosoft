import Foundation

enum VideoFile {
    private static let supportedExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "wmv", "webm", "m4v", "mpg",
        "mpeg", "ts", "mts", "m2ts", "flv", "f4v",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

struct VideoSidecarSnapshot: Equatable {
    let transcript: String
    let description: String
    let transcriptURL: URL
    let descriptionURL: URL
}

enum VideoSidecars {
    private static let legacySeparator = "------------------------------------------------------------"

    static func transcriptURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("srt")
    }

    static func descriptionURL(for videoURL: URL) -> URL {
        let stem = videoURL.deletingPathExtension().lastPathComponent
        return videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-description.txt")
    }

    static func load(for videoURL: URL) throws -> VideoSidecarSnapshot {
        let transcriptURL = transcriptURL(for: videoURL)
        let descriptionURL = descriptionURL(for: videoURL)
        let transcriptSRT = try readIfPresent(transcriptURL)
        let descriptionFile = try readIfPresent(descriptionURL)

        return VideoSidecarSnapshot(
            transcript: displayTranscript(fromSRT: transcriptSRT),
            description: latestDescription(in: descriptionFile),
            transcriptURL: transcriptURL,
            descriptionURL: descriptionURL
        )
    }

    static func displayTranscript(fromSRT content: String) -> String {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var result: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard let arrowRange = line.range(of: " --> ") else {
                index += 1
                continue
            }

            let rawTimestamp = String(line[..<arrowRange.lowerBound])
            let timestamp = rawTimestamp.components(separatedBy: ",").first ?? rawTimestamp
            index += 1

            var text: [String] = []
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty { break }
                text.append(next)
                index += 1
            }

            if !text.isEmpty {
                result.append("[\(timestamp)] \(text.joined(separator: " "))")
            }
        }

        return result.joined(separator: "\n")
    }

    static func latestDescription(in content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let replies = normalized.components(separatedBy: legacySeparator).compactMap { block -> String? in
            guard let marker = block.range(of: "Gemini:\n") else { return nil }
            let reply = block[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return reply.isEmpty ? nil : reply
        }
        return replies.last ?? normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func appendDescription(
        _ reply: String,
        for videoURL: URL,
        now: Date = Date()
    ) throws {
        let destination = descriptionURL(for: videoURL)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let entry = """

        [\(formatter.string(from: now))]
        You: Please generate a YouTube description for this video.

        Gemini:
        \(reply.trimmingCharacters(in: .whitespacesAndNewlines))

        \(legacySeparator)
        """

        if FileManager.default.fileExists(atPath: destination.path) {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } else {
            try entry.write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private static func readIfPresent(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

enum VideoHQError: LocalizedError {
    case missingTranscriber(URL)
    case transcriberFailed(Int32, String)
    case transcriptWasNotCreated(URL)
    case transcriptRequired(URL)
    case descriptionRequestFailed(Int, String)
    case invalidDescriptionResponse
    case missingOpenRouterAPIKey(URL)

    var errorDescription: String? {
        switch self {
        case .missingTranscriber(let url):
            return "Transcribe launcher not found at \(url.path)."
        case .transcriberFailed(let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Transcription failed with exit code \(status)."
                : "Transcription failed with exit code \(status):\n\(detail)"
        case .transcriptWasNotCreated(let url):
            return "Transcription finished but did not create \(url.lastPathComponent)."
        case .transcriptRequired(let url):
            return "Generate a transcript before creating a description for \(url.lastPathComponent)."
        case .descriptionRequestFailed(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Video description request failed with HTTP \(status)."
                : "Video description request failed with HTTP \(status):\n\(detail)"
        case .invalidDescriptionResponse:
            return "OpenRouter returned a response without a video description."
        case .missingOpenRouterAPIKey(let dotenvURL):
            return "OPENROUTER_API_KEY is not set. Add it to \(dotenvURL.path), then try again."
        }
    }
}

struct VideoTranscriber {
    let executableURL: URL

    func transcribe(videoURL: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw VideoHQError.missingTranscriber(executableURL)
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [videoURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(currentPath)"
        process.environment = environment

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: outputData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw VideoHQError.transcriberFailed(process.terminationStatus, output)
        }

        let snapshot = try VideoSidecars.load(for: videoURL)
        guard !snapshot.transcript.isEmpty else {
            throw VideoHQError.transcriptWasNotCreated(snapshot.transcriptURL)
        }
        return snapshot.transcript
    }
}

protocol VideoDescriptionGenerating {
    func generate(transcript: String) async throws -> String
}

struct VideoDescriptionWorkflow {
    let generator: any VideoDescriptionGenerating

    func generate(for videoURL: URL) async throws -> String {
        let sidecars = try VideoSidecars.load(for: videoURL)
        guard !sidecars.transcript.isEmpty else {
            throw VideoHQError.transcriptRequired(videoURL)
        }

        let reply = try await generator.generate(transcript: sidecars.transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try VideoSidecars.appendDescription(reply, for: videoURL)
        return reply
    }
}
