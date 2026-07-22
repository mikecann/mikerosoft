import Foundation

enum RoughCutRegionKind: String, CaseIterable, Equatable {
    case valid = "Valid"
    case falseStart = "False start"
    case badTake = "Bad take"
    case needsReview = "Needs review"
}

struct RoughCutPlan: Decodable, Equatable {
    struct Source: Decodable, Equatable {
        let filename: String
        let durationSeconds: Double
    }

    let schemaVersion: Int
    let source: Source
    let regions: [RoughCutRegion]

    static func decode(from data: Data) throws -> RoughCutPlan {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RoughCutPlan.self, from: data)
    }
}

struct RoughCutRegion: Decodable, Equatable, Identifiable {
    let id: String
    let start: Double
    let end: Double
    let text: String
    let decision: String
    let confidence: Double
    let reason: String
    let duplicateOf: String?
    let hasTranscriptEvidence: Bool

    var duration: Double { max(0, end - start) }

    var kind: RoughCutRegionKind {
        if decision == "keep" { return .valid }
        if decision == "review" { return .needsReview }

        let duplicateReason = reason.contains("repeat")
            || reason.contains("false_start")
            || reason.contains("duplicate")
            || reason.contains("take_is_more_continuous")
        return duplicateOf != nil || duplicateReason ? .falseStart : .badTake
    }
}

enum RoughCutTimelineInteraction {
    static func seconds(x: Double, width: Double, duration: Double) -> Double {
        guard x.isFinite, width.isFinite, width > 0, duration.isFinite, duration > 0 else {
            return 0
        }
        return duration * max(0, min(1, x / width))
    }

    static func regionID(at seconds: Double, regions: [RoughCutRegion]) -> String? {
        guard seconds.isFinite else { return nil }
        if let matching = regions.first(where: {
            seconds >= $0.start && seconds < $0.end
        }) {
            return matching.id
        }

        // Keep the final section selected when the playhead reaches the exact end.
        guard let final = regions.max(by: { $0.end < $1.end }),
              abs(seconds - final.end) < 0.000_001 else { return nil }
        return final.id
    }
}

enum RoughCutAnalysisError: LocalizedError {
    case unsupportedVideo(URL)
    case sourceVideoMissing(URL)
    case destinationExists(URL)
    case plannerRepositoryMissing(URL)
    case pythonMissing(URL)
    case plannerFailed(Int32, String)
    case plannerOutputMissing(URL)
    case plannerSourceMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVideo(let url):
            return "\(url.lastPathComponent) is not a supported video file."
        case .sourceVideoMissing(let url):
            return "The source video no longer exists at \(url.path)."
        case .destinationExists(let url):
            return "\(url.lastPathComponent) already exists in the project source directory. Choose it from the list or rename the file before importing it."
        case .plannerRepositoryMissing(let url):
            return "The Filmora automation repository was not found at \(url.path). Set VIDEO_HQ_FILMORA_AUTOMATION_ROOT and rebuild Video HQ."
        case .pythonMissing(let url):
            return "The rough-cut Python environment was not found at \(url.path). Set VIDEO_HQ_ROUGH_CUT_PYTHON to a Python executable with faster-whisper installed."
        case .plannerFailed(let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Rough-cut analysis failed with exit code \(status)."
                : "Rough-cut analysis failed with exit code \(status):\n\(detail)"
        case .plannerOutputMissing(let url):
            return "Rough-cut analysis finished without creating \(url.lastPathComponent)."
        case .plannerSourceMismatch(let expected, let actual):
            return "The saved rough-cut plan belongs to \(actual), not \(expected)."
        }
    }
}

struct RoughCutSourceLibrary {
    let projectDirectoryURL: URL
    var fileManager = FileManager.default

    var sourceDirectoryURL: URL {
        projectDirectoryURL.appendingPathComponent("source", isDirectory: true)
    }

    func videos() throws -> [URL] {
        guard fileManager.fileExists(atPath: sourceDirectoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: sourceDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            VideoFile.isSupported(url)
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        .sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    func importVideo(at sourceURL: URL) throws -> URL {
        guard VideoFile.isSupported(sourceURL) else {
            throw RoughCutAnalysisError.unsupportedVideo(sourceURL)
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RoughCutAnalysisError.sourceVideoMissing(sourceURL)
        }

        try fileManager.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        let destinationURL = sourceDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return destinationURL
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw RoughCutAnalysisError.destinationExists(destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}

struct RoughCutAnalysis: Equatable {
    let directoryURL: URL
    let planURL: URL
    let plan: RoughCutPlan
    let transcriptURL: URL
    let reviewURL: URL
    let createdAt: Date
}

private struct RoughCutSourceFingerprint: Codable, Equatable {
    let fileSize: Int64
    let modificationTime: TimeInterval

    static func read(from url: URL) throws -> RoughCutSourceFingerprint {
        // FileManager reads fresh attributes after an in-place source replacement.
        // URL resource values can remain cached briefly, which risks reusing a stale transcript.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return RoughCutSourceFingerprint(
            fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
    }
}

private struct RoughCutAnalysisManifest: Codable {
    let schemaVersion: Int
    let sourceFilename: String
    let sourceFingerprint: RoughCutSourceFingerprint
    let createdAt: Date
}

struct RoughCutAnalysisStore {
    let projectDirectoryURL: URL
    var fileManager = FileManager.default

    func newRunDirectoryURL(
        for sourceVideoURL: URL,
        now: Date = Date(),
        identifier: String = UUID().uuidString
    ) throws -> URL {
        let root = analysisRootURL(for: sourceVideoURL)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let runName = "\(formatter.string(from: now))-\(sanitized(identifier))"
        return root.appendingPathComponent(runName, isDirectory: true)
    }

    func recordCompletedRun(
        at outputDirectoryURL: URL,
        sourceVideoURL: URL,
        now: Date = Date()
    ) throws -> RoughCutAnalysis {
        let planURL = outputDirectoryURL.appendingPathComponent("rough-cut-plan.json")
        let plan = try RoughCutPlan.decode(from: Data(contentsOf: planURL))
        guard plan.source.filename == sourceVideoURL.lastPathComponent else {
            throw RoughCutAnalysisError.plannerSourceMismatch(
                expected: sourceVideoURL.lastPathComponent,
                actual: plan.source.filename
            )
        }

        let transcriptURL = outputDirectoryURL.appendingPathComponent("transcript.json")
        guard fileManager.fileExists(atPath: transcriptURL.path) else {
            throw RoughCutAnalysisError.plannerOutputMissing(transcriptURL)
        }
        let manifest = RoughCutAnalysisManifest(
            schemaVersion: 1,
            sourceFilename: sourceVideoURL.lastPathComponent,
            sourceFingerprint: try RoughCutSourceFingerprint.read(from: sourceVideoURL),
            createdAt: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: outputDirectoryURL.appendingPathComponent("video-hq-analysis.json"),
            options: .atomic
        )
        return try loadAnalysis(at: outputDirectoryURL, sourceVideoURL: sourceVideoURL)
    }

    func latestAnalysis(for sourceVideoURL: URL) throws -> RoughCutAnalysis? {
        let root = analysisRootURL(for: sourceVideoURL)
        guard fileManager.fileExists(atPath: root.path) else { return nil }
        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { left, right in
            let leftDate = try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rightDate = try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
        }

        for directory in directories {
            if let analysis = try? loadAnalysis(at: directory, sourceVideoURL: sourceVideoURL) {
                return analysis
            }
        }
        return nil
    }

    func reusableTranscriptURL(for sourceVideoURL: URL) throws -> URL? {
        if let latest = try latestAnalysis(for: sourceVideoURL) {
            return latest.transcriptURL
        }
        let sidecarURL = VideoSidecars.transcriptURL(for: sourceVideoURL)
        return fileManager.fileExists(atPath: sidecarURL.path) ? sidecarURL : nil
    }

    private func loadAnalysis(
        at directoryURL: URL,
        sourceVideoURL: URL
    ) throws -> RoughCutAnalysis {
        let manifestURL = directoryURL.appendingPathComponent("video-hq-analysis.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            RoughCutAnalysisManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.sourceFilename == sourceVideoURL.lastPathComponent,
              manifest.sourceFingerprint == (try RoughCutSourceFingerprint.read(from: sourceVideoURL)) else {
            throw RoughCutAnalysisError.plannerSourceMismatch(
                expected: sourceVideoURL.lastPathComponent,
                actual: manifest.sourceFilename
            )
        }

        let planURL = directoryURL.appendingPathComponent("rough-cut-plan.json")
        let transcriptURL = directoryURL.appendingPathComponent("transcript.json")
        let reviewURL = directoryURL.appendingPathComponent("review.txt")
        guard fileManager.fileExists(atPath: planURL.path) else {
            throw RoughCutAnalysisError.plannerOutputMissing(planURL)
        }
        guard fileManager.fileExists(atPath: transcriptURL.path) else {
            throw RoughCutAnalysisError.plannerOutputMissing(transcriptURL)
        }
        let plan = try RoughCutPlan.decode(from: Data(contentsOf: planURL))
        guard plan.source.filename == sourceVideoURL.lastPathComponent else {
            throw RoughCutAnalysisError.plannerSourceMismatch(
                expected: sourceVideoURL.lastPathComponent,
                actual: plan.source.filename
            )
        }
        return RoughCutAnalysis(
            directoryURL: directoryURL.resolvingSymlinksInPath(),
            planURL: planURL.resolvingSymlinksInPath(),
            plan: plan,
            transcriptURL: transcriptURL.resolvingSymlinksInPath(),
            reviewURL: reviewURL.resolvingSymlinksInPath(),
            createdAt: manifest.createdAt
        )
    }

    private func analysisRootURL(for sourceVideoURL: URL) -> URL {
        let sourceKey = sanitized(sourceVideoURL.lastPathComponent)
        return projectDirectoryURL
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("video-hq-rough-cut", isDirectory: true)
            .appendingPathComponent(sourceKey, isDirectory: true)
    }

    private func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(result).replacingOccurrences(of: "--", with: "-")
    }
}

struct FilmoraRoughCutRunner {
    let automationRootURL: URL
    let pythonExecutableURL: URL
    var fileManager = FileManager.default

    static func arguments(
        videoURL: URL,
        outputDirectoryURL: URL,
        transcriptURL: URL?
    ) -> [String] {
        var result = [
            "-m", "filmora_wfp", "rough-cut-plan",
            videoURL.path,
            outputDirectoryURL.path,
            "--json",
        ]
        if let transcriptURL {
            result.append(contentsOf: ["--transcript", transcriptURL.path])
        }
        return result
    }

    func run(
        videoURL: URL,
        outputDirectoryURL: URL,
        transcriptURL: URL?
    ) throws -> RoughCutPlan {
        guard fileManager.fileExists(
            atPath: automationRootURL.appendingPathComponent("filmora_wfp", isDirectory: true).path
        ) else {
            throw RoughCutAnalysisError.plannerRepositoryMissing(automationRootURL)
        }
        guard fileManager.isExecutableFile(atPath: pythonExecutableURL.path) else {
            throw RoughCutAnalysisError.pythonMissing(pythonExecutableURL)
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = pythonExecutableURL
        process.arguments = Self.arguments(
            videoURL: videoURL,
            outputDirectoryURL: outputDirectoryURL,
            transcriptURL: transcriptURL
        )
        process.currentDirectoryURL = automationRootURL
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            currentPath,
        ].joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw RoughCutAnalysisError.plannerFailed(process.terminationStatus, output)
        }

        let planURL = outputDirectoryURL.appendingPathComponent("rough-cut-plan.json")
        guard fileManager.fileExists(atPath: planURL.path) else {
            throw RoughCutAnalysisError.plannerOutputMissing(planURL)
        }
        return try RoughCutPlan.decode(from: Data(contentsOf: planURL))
    }
}

struct RoughCutMissingScriptParagraph: Equatable, Identifiable {
    let index: Int
    let text: String
    let coverage: Double

    var id: Int { index }
}

struct RoughCutScriptCoverageReport: Equatable {
    let regionScores: [String: Double]
    let mismatchedRegionIDs: Set<String>
    let missingParagraphs: [RoughCutMissingScriptParagraph]

    func score(for regionID: String) -> Double? {
        regionScores[regionID]
    }
}

enum RoughCutScriptCoverage {
    static func analyze(
        script: String,
        regions: [RoughCutRegion]
    ) -> RoughCutScriptCoverageReport {
        let paragraphs = TeleprompterScriptParser.parse(script).compactMap { block -> String? in
            guard case .spoken(let text) = block else { return nil }
            return text
        }
        let scriptTokens = paragraphs.flatMap(tokens(in:))
        let retainedRegions = regions.filter { $0.decision != "drop" }
        let retainedTranscriptTokens = retainedRegions.flatMap { tokens(in: $0.text) }

        var scores: [String: Double] = [:]
        var mismatches = Set<String>()
        for region in regions {
            let regionTokens = tokens(in: region.text)
            guard !regionTokens.isEmpty, !scriptTokens.isEmpty else { continue }
            let score = orderedCoverage(of: regionTokens, within: scriptTokens)
            scores[region.id] = score
            if region.decision != "drop", regionTokens.count >= 4, score < 0.55 {
                mismatches.insert(region.id)
            }
        }

        let missing = paragraphs.enumerated().compactMap { index, paragraph -> RoughCutMissingScriptParagraph? in
            let paragraphTokens = tokens(in: paragraph)
            guard !paragraphTokens.isEmpty else { return nil }
            let coverage = orderedCoverage(of: paragraphTokens, within: retainedTranscriptTokens)
            let threshold = paragraphTokens.count < 4 ? 0.9 : 0.65
            guard coverage < threshold else { return nil }
            return RoughCutMissingScriptParagraph(index: index, text: paragraph, coverage: coverage)
        }

        return RoughCutScriptCoverageReport(
            regionScores: scores,
            mismatchedRegionIDs: mismatches,
            missingParagraphs: missing
        )
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func orderedCoverage(of needle: [String], within haystack: [String]) -> Double {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: haystack.count + 1)
        for needleToken in needle {
            var current = Array(repeating: 0, count: haystack.count + 1)
            for index in haystack.indices {
                if needleToken == haystack[index] {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(previous[index + 1], current[index])
                }
            }
            previous = current
        }
        return Double(previous[haystack.count]) / Double(needle.count)
    }
}
