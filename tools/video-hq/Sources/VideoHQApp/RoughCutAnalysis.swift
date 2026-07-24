import Foundation

enum RoughCutRegionKind: String, CaseIterable, Equatable {
    case valid = "Valid"
    case falseStart = "False start"
    case badTake = "Bad take"
    case noTranscriptSkip = "No transcript skip"
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
        if reason == "no_transcript_skip" { return .noTranscriptSkip }

        let duplicateReason = reason.contains("repeat")
            || reason.contains("false_start")
            || reason.contains("duplicate")
            || reason.contains("take_is_more_continuous")
        return duplicateOf != nil || duplicateReason ? .falseStart : .badTake
    }
}

enum RoughCutReasonPresentation {
    static func text(for reason: String) -> String {
        var value = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("codex_"),
           let separator = value.range(of: ":") {
            value = String(value[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            value = value.replacingOccurrences(of: "_", with: " ")
        }
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
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
            "-m", "filmora_wfp", "rough-cut-inputs",
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
    ) throws -> URL {
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

        let inputURL = outputDirectoryURL.appendingPathComponent("rough-cut-input.json")
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw RoughCutAnalysisError.plannerOutputMissing(inputURL)
        }
        return inputURL
    }
}

enum CodexRoughCutAnalysisError: LocalizedError {
    case executableMissing
    case failed(Int32, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "Codex CLI was not found. Install it or set VIDEO_HQ_CODEX_CLI to its path."
        case .failed(let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Codex rough-cut analysis failed with exit code \(status)."
                : "Codex rough-cut analysis failed with exit code \(status):\n\(detail)"
        case .invalidResponse(let detail):
            return "Codex returned an invalid rough-cut analysis: \(detail)"
        }
    }
}

private struct CodexRoughCutDecisionResponse: Decodable {
    let decisions: [CodexRoughCutDecision]
    let joinSuggestions: [RoughCutJoinSuggestion]

    private enum CodingKeys: String, CodingKey {
        case decisions
        case joinSuggestions = "join_suggestions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisions = try container.decode([CodexRoughCutDecision].self, forKey: .decisions)
        joinSuggestions = try container.decodeIfPresent(
            [RoughCutJoinSuggestion].self,
            forKey: .joinSuggestions
        ) ?? []
    }
}

private struct CodexRoughCutDecision: Decodable {
    enum Classification: String, Decodable {
        case valid
        case falseStart = "false_start"
        case badTake = "bad_take"
        case needsReview = "needs_review"
    }

    let regionID: String
    let classification: Classification
    let confidence: Double
    let reason: String
    let duplicateOf: String?

    private enum CodingKeys: String, CodingKey {
        case regionID = "region_id"
        case classification
        case confidence
        case reason
        case duplicateOf = "duplicate_of"
    }
}

struct CodexRoughCutAnalysisResult {
    let planData: Data
    let plan: RoughCutPlan
    let joinSuggestions: [RoughCutJoinSuggestion]
}

struct CodexRoughCutAnalysisRunner {
    var fileManager = FileManager.default
    var environment = ProcessInfo.processInfo.environment

    static func arguments(
        schemaURL: URL,
        outputURL: URL,
        workingDirectoryURL: URL
    ) -> [String] {
        [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "-C", workingDirectoryURL.path,
            "--output-schema", schemaURL.path,
            "-o", outputURL.path,
            Self.prompt,
        ]
    }

    func run(
        inputURL: URL,
        transcriptURL: URL,
        script: String?,
        outputPlanURL: URL,
        workingDirectoryURL: URL
    ) throws -> CodexRoughCutAnalysisResult {
        guard let executableURL = executableURL() else {
            throw CodexRoughCutAnalysisError.executableMissing
        }

        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("video-hq-codex-review-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectoryURL) }

        let schemaURL = temporaryDirectoryURL.appendingPathComponent("rough-cut-schema.json")
        let responseURL = temporaryDirectoryURL.appendingPathComponent("rough-cut-response.json")
        try Self.outputSchema.write(to: schemaURL, options: .atomic)

        let inputData = try Data(contentsOf: inputURL)
        let transcriptData = try Data(contentsOf: transcriptURL)
        let processInput = try Self.requestData(
            inputData: inputData,
            transcriptData: transcriptData,
            script: script
        )

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = Self.arguments(
            schemaURL: schemaURL,
            outputURL: responseURL,
            workingDirectoryURL: workingDirectoryURL
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = environment

        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: processInput)
        try inputPipe.fileHandleForWriting.close()
        let processOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CodexRoughCutAnalysisError.failed(
                process.terminationStatus,
                String(decoding: processOutput, as: UTF8.self)
            )
        }
        guard fileManager.fileExists(atPath: responseURL.path) else {
            throw CodexRoughCutAnalysisError.invalidResponse("the output file was not created")
        }

        let result = try Self.classifiedResult(
            inputData: inputData,
            responseData: Data(contentsOf: responseURL)
        )
        try result.planData.write(to: outputPlanURL, options: .atomic)
        return result
    }

    static func requestData(
        inputData: Data,
        transcriptData: Data,
        script: String?
    ) throws -> Data {
        var payload: [String: Any] = [
            "detected_sections": try JSONSerialization.jsonObject(with: inputData),
            "complete_transcript": try JSONSerialization.jsonObject(with: transcriptData),
        ]
        if let script = script?.trimmingCharacters(in: .whitespacesAndNewlines),
           !script.isEmpty {
            payload["reference_script"] = script
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func classifiedPlanData(
        inputData: Data,
        responseData: Data
    ) throws -> Data {
        try classifiedResult(
            inputData: inputData,
            responseData: responseData
        ).planData
    }

    static func classifiedResult(
        inputData: Data,
        responseData: Data
    ) throws -> CodexRoughCutAnalysisResult {
        guard var payload = try JSONSerialization.jsonObject(with: inputData) as? [String: Any],
              var regions = payload["regions"] as? [[String: Any]] else {
            throw CodexRoughCutAnalysisError.invalidResponse(
                "the detected section input is malformed"
            )
        }

        let response: CodexRoughCutDecisionResponse
        do {
            response = try JSONDecoder().decode(
                CodexRoughCutDecisionResponse.self,
                from: responseData
            )
        } catch {
            throw CodexRoughCutAnalysisError.invalidResponse(error.localizedDescription)
        }

        let regionIDs = regions.compactMap { $0["id"] as? String }
        guard regionIDs.count == regions.count else {
            throw CodexRoughCutAnalysisError.invalidResponse(
                "one or more detected sections has no id"
            )
        }
        let validIDs = Set(regionIDs)
        var decisionsByID: [String: CodexRoughCutDecision] = [:]
        for decision in response.decisions {
            guard validIDs.contains(decision.regionID) else {
                throw CodexRoughCutAnalysisError.invalidResponse(
                    "unknown section id \(decision.regionID)"
                )
            }
            guard decisionsByID[decision.regionID] == nil else {
                throw CodexRoughCutAnalysisError.invalidResponse(
                    "section \(decision.regionID) was classified more than once"
                )
            }
            guard decision.confidence.isFinite,
                  (0...1).contains(decision.confidence),
                  !decision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodexRoughCutAnalysisError.invalidResponse(
                    "section \(decision.regionID) has invalid confidence or reasoning"
                )
            }
            if let duplicateOf = decision.duplicateOf, !validIDs.contains(duplicateOf) {
                throw CodexRoughCutAnalysisError.invalidResponse(
                    "section \(decision.regionID) refers to unknown duplicate \(duplicateOf)"
                )
            }
            decisionsByID[decision.regionID] = decision
        }
        guard decisionsByID.count == regions.count else {
            let missing = regionIDs.filter { decisionsByID[$0] == nil }
            throw CodexRoughCutAnalysisError.invalidResponse(
                "Codex omitted sections: \(missing.joined(separator: ", "))"
            )
        }

        var keepRanges: [[String: Double]] = []
        var dropRanges: [[String: Double]] = []
        for index in regions.indices {
            let regionID = regionIDs[index]
            guard let decision = decisionsByID[regionID] else { continue }
            let start = (regions[index]["start"] as? NSNumber)?.doubleValue
            let end = (regions[index]["end"] as? NSNumber)?.doubleValue
            let hasTranscriptEvidence =
                (regions[index]["has_transcript_evidence"] as? Bool) == true
            let transcriptText = (regions[index]["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let shouldSkipWithoutTranscript =
                (start.flatMap { regionStart in
                    end.map { $0 - regionStart < 5 }
                } ?? false)
                && (!hasTranscriptEvidence || transcriptText.isEmpty)

            if shouldSkipWithoutTranscript {
                regions[index]["decision"] = "drop"
                regions[index]["confidence"] = 1.0
                regions[index]["reason"] = "no_transcript_skip"
                regions[index]["duplicate_of"] = NSNull()
            } else {
                let prefix: String
                switch decision.classification {
                case .valid:
                    regions[index]["decision"] = "keep"
                    prefix = "codex_valid"
                case .falseStart:
                    regions[index]["decision"] = "drop"
                    prefix = "codex_false_start"
                case .badTake:
                    regions[index]["decision"] = "drop"
                    prefix = "codex_bad_take"
                case .needsReview:
                    regions[index]["decision"] = "review"
                    prefix = "codex_needs_review"
                }
                regions[index]["confidence"] = decision.confidence
                regions[index]["reason"] = "\(prefix): \(decision.reason)"
                regions[index]["duplicate_of"] = decision.classification == .falseStart
                    ? (decision.duplicateOf ?? NSNull())
                    : NSNull()
            }

            guard let start, let end else { continue }
            let range = ["start": start, "end": end]
            if (regions[index]["decision"] as? String) == "drop" {
                dropRanges.append(range)
            } else {
                keepRanges.append(range)
            }
        }

        payload["regions"] = regions
        payload["keep_ranges"] = keepRanges
        payload["duplicate_drop_ranges"] = dropRanges
        payload["non_speech_drop_ranges"] = []
        payload["review_required"] = regions.contains {
            ($0["decision"] as? String) != "keep"
        }
        payload["codex_analysis"] = [
            "schema_version": 1,
            "scope": "complete_transcript",
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw CodexRoughCutAnalysisError.invalidResponse(
                "the classified plan is not valid JSON"
            )
        }
        let planData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let plan = try RoughCutPlan.decode(from: planData)
        let acceptedRegionIDs = plan.regions
            .filter { $0.decision == "keep" }
            .map(\.id)
        return CodexRoughCutAnalysisResult(
            planData: planData,
            plan: plan,
            joinSuggestions: RoughCutJoinSuggestionValidator.validated(
                response.joinSuggestions,
                acceptedRegionIDs: acceptedRegionIDs
            )
        )
    }

    private func executableURL() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            environment["VIDEO_HQ_CODEX_CLI"].map(URL.init(fileURLWithPath:)),
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static let prompt = """
    You are the editorial reviewer for Step 1 of a spoken-to-camera rough-cut process.
    Read the complete ordered transcript and every detected section supplied on stdin.
    Classify every section exactly once as valid, false_start, bad_take, or needs_review.

    A false_start is an abandoned or incomplete attempt that is restarted or superseded
    later. Set duplicate_of to the later completed section when there is a clear match.
    A bad_take is material that should not appear in the edit, such as recording
    directions, isolated filler, accidental speech, or an explicitly rejected attempt.
    Valid material is the intended narrative even when a sentence continues into the
    next section. Use needs_review when the transcript alone cannot support a confident
    editorial call, including audible sections with no useful transcription.

    Judge sections in the context of the entire narrative, not by word overlap alone.
    A reference script may be supplied as supporting context for intended wording and
    narrative order. The recording transcript remains the source of truth. Do not mark
    an unscripted but useful recorded line as bad merely because it differs from the script.

    In the same response, suggest likely joins where two or more clips classified as
    valid form one interrupted sentence or thought after excluded clips are removed.
    Suggest a join only when the first clip ends mid-clause or mid-thought and the next
    valid clip clearly continues it. Do not join complete sentences just because their
    topics are related. Return no more than 20 high-confidence join suggestions.
    Do not classify a section as bad merely because it is short, informal, or not a
    complete sentence. Return exact region_id values and concise reasoning.
    """

    private static let outputSchema = Data(
        """
        {
          "type": "object",
          "properties": {
            "decisions": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "region_id": {"type": "string"},
                  "classification": {
                    "type": "string",
                    "enum": ["valid", "false_start", "bad_take", "needs_review"]
                  },
                  "confidence": {"type": "number"},
                  "reason": {"type": "string"},
                  "duplicate_of": {"type": ["string", "null"]}
                },
                "required": [
                  "region_id", "classification", "confidence", "reason", "duplicate_of"
                ],
                "additionalProperties": false
              }
            },
            "join_suggestions": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "region_ids": {
                    "type": "array",
                    "items": {"type": "string"}
                  },
                  "confidence": {"type": "number"},
                  "reason": {"type": "string"}
                },
                "required": ["region_ids", "confidence", "reason"],
                "additionalProperties": false
              }
            }
          },
          "required": ["decisions", "join_suggestions"],
          "additionalProperties": false
        }
        """.utf8
    )
}
