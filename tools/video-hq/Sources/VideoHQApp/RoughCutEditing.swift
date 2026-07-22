import Foundation

enum RoughCutManualDecision: String, Codable, CaseIterable, Equatable {
    case automatic
    case keep
    case cut

    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .keep: return "Keep"
        case .cut: return "Cut"
        }
    }
}

extension RoughCutRegion {
    func applyingManualDecision(_ manualDecision: RoughCutManualDecision?) -> RoughCutRegion {
        guard let manualDecision, manualDecision != .automatic else { return self }
        return RoughCutRegion(
            id: id,
            start: start,
            end: end,
            text: text,
            decision: manualDecision == .keep ? "keep" : "drop",
            confidence: 1,
            reason: manualDecision == .keep ? "manual_keep" : "manual_cut",
            duplicateOf: manualDecision == .keep ? nil : duplicateOf,
            hasTranscriptEvidence: hasTranscriptEvidence
        )
    }
}

private struct RoughCutOverrideDocument: Codable {
    let schemaVersion: Int
    let decisions: [String: RoughCutManualDecision]
}

struct RoughCutOverrideStore {
    let analysisDirectoryURL: URL

    var overridesURL: URL {
        analysisDirectoryURL.appendingPathComponent("video-hq-overrides.json")
    }

    func load() throws -> [String: RoughCutManualDecision] {
        guard FileManager.default.fileExists(atPath: overridesURL.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            RoughCutOverrideDocument.self,
            from: Data(contentsOf: overridesURL)
        ).decisions
    }

    func save(
        _ decisions: [String: RoughCutManualDecision],
        validRegionIDs: [String]
    ) throws {
        let validIDs = Set(validRegionIDs)
        let persisted = decisions.filter { regionID, decision in
            validIDs.contains(regionID) && decision != .automatic
        }
        let document = RoughCutOverrideDocument(schemaVersion: 1, decisions: persisted)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: overridesURL, options: .atomic)
    }
}

enum RoughCutEditingError: LocalizedError {
    case invalidPlan(String)
    case outputExists(URL)
    case invalidSeed([String])
    case invalidCommandOutput(String)
    case commandFailed(String, Int32, String)
    case noMatchingSeed(URL)

    var errorDescription: String? {
        switch self {
        case .invalidPlan(let detail):
            return "The reviewed rough-cut plan could not be created: \(detail)"
        case .outputExists(let url):
            return "Refusing to overwrite \(url.lastPathComponent). Choose a new Filmora project name."
        case .invalidSeed(let issues):
            return "That Filmora project is not a clean rough-cut seed: \(issues.joined(separator: "; "))"
        case .invalidCommandOutput(let command):
            return "Filmora automation returned an unreadable result for \(command)."
        case .commandFailed(let command, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Filmora \(command) failed with exit code \(status)."
                : "Filmora \(command) failed with exit code \(status):\n\(detail)"
        case .noMatchingSeed(let sourceVideoURL):
            return "Video HQ could not find a clean Filmora project for \(sourceVideoURL.lastPathComponent) in this project folder. Create one once in Filmora with only that recording on the timeline, then Video HQ can find and reuse it automatically."
        }
    }
}

struct RoughCutReviewedPlanWriter {
    func write(
        sourcePlanURL: URL,
        outputURL: URL,
        overrides: [String: RoughCutManualDecision],
        filmoraSourceDurationSeconds: Double? = nil
    ) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RoughCutEditingError.outputExists(outputURL)
        }
        guard var payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: sourcePlanURL)
        ) as? [String: Any],
              var regions = payload["regions"] as? [[String: Any]] else {
            throw RoughCutEditingError.invalidPlan("regions is missing or malformed")
        }

        var appliedOverrides: [[String: Any]] = []
        for index in regions.indices {
            guard let regionID = regions[index]["id"] as? String,
                  let manualDecision = overrides[regionID],
                  manualDecision != .automatic else { continue }
            let originalDecision = regions[index]["decision"] as? String ?? "unknown"
            let originalReason = regions[index]["reason"] as? String ?? "unknown"
            regions[index]["video_hq_original_decision"] = originalDecision
            regions[index]["video_hq_original_reason"] = originalReason
            regions[index]["video_hq_manual_decision"] = manualDecision.rawValue
            regions[index]["decision"] = manualDecision == .keep ? "keep" : "drop"
            regions[index]["reason"] = manualDecision == .keep ? "manual_keep" : "manual_cut"
            regions[index]["confidence"] = 1.0
            if manualDecision == .keep {
                regions[index]["duplicate_of"] = NSNull()
            }
            appliedOverrides.append([
                "region_id": regionID,
                "decision": manualDecision.rawValue,
                "original_decision": originalDecision,
            ])
        }

        var reviewMetadata: [String: Any] = [
            "schema_version": 1,
            "manual_override_count": appliedOverrides.count,
            "manual_overrides": appliedOverrides,
            "source_plan": sourcePlanURL.lastPathComponent,
        ]
        if let filmoraSourceDurationSeconds {
            guard filmoraSourceDurationSeconds.isFinite, filmoraSourceDurationSeconds > 0,
                  var source = payload["source"] as? [String: Any],
                  let plannerDuration = number(source["duration_seconds"]),
                  abs(plannerDuration - filmoraSourceDurationSeconds) <= 0.25 else {
                throw RoughCutEditingError.invalidPlan(
                    "the Filmora seed duration differs from the planner by more than 0.25 seconds"
                )
            }
            source["duration_seconds"] = filmoraSourceDurationSeconds
            payload["source"] = source
            reviewMetadata["planner_source_duration_seconds"] = plannerDuration
            reviewMetadata["filmora_source_duration_seconds"] = filmoraSourceDurationSeconds
        }

        payload["regions"] = regions
        payload["keep_ranges"] = try rebuiltKeepRanges(
            from: regions,
            maximumSourceDuration: filmoraSourceDurationSeconds
        )
        payload["review_required"] = true
        payload["video_hq_review"] = reviewMetadata

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw RoughCutEditingError.invalidPlan("the edited JSON is not serializable")
        }
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .withoutOverwriting)
    }

    private func rebuiltKeepRanges(
        from regions: [[String: Any]],
        maximumSourceDuration: Double?
    ) throws -> [[String: Double]] {
        let retained = try regions.compactMap { region -> (Double, Double)? in
            guard (region["decision"] as? String) != "drop" else { return nil }
            guard let start = number(region["start"]), var end = number(region["end"]), end > start else {
                throw RoughCutEditingError.invalidPlan("a retained region has invalid start or end")
            }
            if let maximumSourceDuration, end > maximumSourceDuration {
                guard end - maximumSourceDuration <= 0.25, start < maximumSourceDuration else {
                    throw RoughCutEditingError.invalidPlan(
                        "a retained region extends beyond the Filmora source duration"
                    )
                }
                end = maximumSourceDuration
            }
            return (start, end)
        }
        .sorted { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }

        var merged: [(Double, Double)] = []
        for range in retained {
            if let previous = merged.last, range.0 <= previous.1 + 0.000_001 {
                merged[merged.count - 1] = (previous.0, max(previous.1, range.1))
            } else {
                merged.append(range)
            }
        }
        return merged.map { ["start": $0.0, "end": $0.1] }
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

struct FilmoraRoughCutExportResult: Equatable {
    let outputURL: URL
    let outputPairCount: Int
    let outputDurationSeconds: Double
}

struct FilmoraRoughCutSeed: Equatable {
    let projectURL: URL
    let sourceVideoURL: URL
    let sourceFilename: String
    let sourceDurationSeconds: Double
    let sha256: String
}

struct FilmoraRoughCutExportRunner {
    let automationRootURL: URL
    let pythonExecutableURL: URL
    var fileManager = FileManager.default

    static func seedArguments(seedURL: URL) -> [String] {
        ["-m", "filmora_wfp", "rough-cut-seed", seedURL.path, "--json"]
    }

    static func inspectionArguments(seedURL: URL) -> [String] {
        ["-m", "filmora_wfp", "inspect", seedURL.path, "--reveal-paths", "--json"]
    }

    static func projectArguments(
        seedURL: URL,
        planURL: URL,
        outputURL: URL,
        expectedSHA256: String
    ) -> [String] {
        [
            "-m", "filmora_wfp", "rough-cut-project", seedURL.path, planURL.path,
            outputURL.path, "--expect-sha256", expectedSHA256, "--json",
        ]
    }

    static func validationArguments(outputURL: URL) -> [String] {
        ["-m", "filmora_wfp", "validate", outputURL.path, "--check-media", "--json"]
    }

    static func bestMatchingSeed(
        _ seeds: [FilmoraRoughCutSeed],
        sourceVideoURL: URL,
        plannedDurationSeconds: Double
    ) throws -> FilmoraRoughCutSeed {
        let source = sourceVideoURL.resolvingSymlinksInPath().standardizedFileURL
        let matching = seeds.filter { seed in
            seed.sourceVideoURL.resolvingSymlinksInPath().standardizedFileURL == source
                && seed.sourceFilename == sourceVideoURL.lastPathComponent
                && abs(seed.sourceDurationSeconds - plannedDurationSeconds) <= 0.25
        }
        .sorted { left, right in
            let leftDelta = abs(left.sourceDurationSeconds - plannedDurationSeconds)
            let rightDelta = abs(right.sourceDurationSeconds - plannedDurationSeconds)
            if leftDelta != rightDelta { return leftDelta < rightDelta }
            let leftIsNamedSeed = left.projectURL.lastPathComponent.localizedCaseInsensitiveContains("seed")
            let rightIsNamedSeed = right.projectURL.lastPathComponent.localizedCaseInsensitiveContains("seed")
            if leftIsNamedSeed != rightIsNamedSeed { return leftIsNamedSeed }
            return left.projectURL.path.localizedCaseInsensitiveCompare(right.projectURL.path) == .orderedAscending
        }
        guard let best = matching.first else {
            throw RoughCutEditingError.noMatchingSeed(sourceVideoURL)
        }
        return best
    }

    func discoverMatchingSeed(
        projectDirectoryURL: URL,
        sourceVideoURL: URL,
        plannedDurationSeconds: Double
    ) throws -> FilmoraRoughCutSeed {
        let projectURLs = try filmoraProjectURLs(in: projectDirectoryURL)
        var seeds: [FilmoraRoughCutSeed] = []
        for projectURL in projectURLs.prefix(100) {
            if let seed = try inspectSeed(at: projectURL) {
                seeds.append(seed)
            }
        }
        return try Self.bestMatchingSeed(
            seeds,
            sourceVideoURL: sourceVideoURL,
            plannedDurationSeconds: plannedDurationSeconds
        )
    }

    func run(
        seedURL: URL,
        planURL: URL,
        outputURL: URL
    ) throws -> FilmoraRoughCutExportResult {
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw RoughCutEditingError.outputExists(outputURL)
        }

        let seedPayload = try JSONSerialization.jsonObject(
            with: runCommand(Self.seedArguments(seedURL: seedURL), allowFailure: true)
        ) as? [String: Any]
        guard let seedPayload else {
            throw RoughCutEditingError.invalidCommandOutput("rough-cut-seed")
        }
        let validSeed = seedPayload["valid_seed_shape"] as? Bool ?? false
        let writerAvailable = seedPayload["filmora_writer_available"] as? Bool ?? false
        guard validSeed, writerAvailable else {
            let issues = seedPayload["issues"] as? [String] ?? []
            throw RoughCutEditingError.invalidSeed(
                issues.isEmpty ? ["the seed checker rejected this project"] : issues
            )
        }
        guard let source = seedPayload["source"] as? [String: Any],
              let sha256 = source["sha256"] as? String,
              !sha256.isEmpty else {
            throw RoughCutEditingError.invalidCommandOutput("rough-cut-seed")
        }

        // Catch missing external media before creating a new project on disk.
        _ = try runCommand(Self.validationArguments(outputURL: seedURL))
        let projectData = try runCommand(Self.projectArguments(
            seedURL: seedURL,
            planURL: planURL,
            outputURL: outputURL,
            expectedSHA256: sha256
        ))
        guard let projectPayload = try JSONSerialization.jsonObject(with: projectData) as? [String: Any],
              let pairCount = (projectPayload["output_pair_count"] as? NSNumber)?.intValue,
              let duration = (projectPayload["output_duration_seconds"] as? NSNumber)?.doubleValue else {
            throw RoughCutEditingError.invalidCommandOutput("rough-cut-project")
        }
        _ = try runCommand(Self.validationArguments(outputURL: outputURL))
        return FilmoraRoughCutExportResult(
            outputURL: outputURL,
            outputPairCount: pairCount,
            outputDurationSeconds: duration
        )
    }

    private func filmoraProjectURLs(in directoryURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "wfp" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
        }
        return result.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func inspectSeed(at projectURL: URL) throws -> FilmoraRoughCutSeed? {
        guard let seedPayload = try JSONSerialization.jsonObject(
            with: runCommand(Self.seedArguments(seedURL: projectURL), allowFailure: true)
        ) as? [String: Any],
              seedPayload["valid_seed_shape"] as? Bool == true,
              seedPayload["filmora_writer_available"] as? Bool == true,
              let source = seedPayload["source"] as? [String: Any],
              let sha256 = source["sha256"] as? String,
              let seed = seedPayload["seed"] as? [String: Any],
              let sourceFilename = seed["source_filename"] as? String,
              let durationTicks = (seed["duration_ticks"] as? NSNumber)?.doubleValue else {
            return nil
        }

        guard let inspection = try JSONSerialization.jsonObject(
            with: runCommand(Self.inspectionArguments(seedURL: projectURL))
        ) as? [String: Any],
              let resources = inspection["resources"] as? [[String: Any]],
              resources.count == 1,
              let rawFilename = resources[0]["filename"] as? String,
              let sourceVideoURL = Self.videoURL(fromFilmoraFilename: rawFilename) else {
            return nil
        }
        return FilmoraRoughCutSeed(
            projectURL: projectURL,
            sourceVideoURL: sourceVideoURL,
            sourceFilename: sourceFilename,
            sourceDurationSeconds: durationTicks / 10_000_000,
            sha256: sha256
        )
    }

    private static func videoURL(fromFilmoraFilename filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        var path = filename.hasPrefix("file://") ? String(filename.dropFirst(7)) : filename
        if !path.hasPrefix("/") { path = "/" + path }
        return URL(fileURLWithPath: path)
    }

    private func runCommand(_ arguments: [String], allowFailure: Bool = false) throws -> Data {
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
        process.arguments = arguments
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
        guard allowFailure || process.terminationStatus == 0 else {
            let command = arguments.dropFirst(2).first ?? "command"
            throw RoughCutEditingError.commandFailed(
                command,
                process.terminationStatus,
                String(decoding: outputData, as: UTF8.self)
            )
        }
        return outputData
    }
}
