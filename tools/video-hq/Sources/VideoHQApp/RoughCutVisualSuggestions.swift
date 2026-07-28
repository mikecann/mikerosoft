import Foundation

struct RoughCutVisualSuggestionClip: Equatable {
    let groupID: String
    let clipNumber: Int
    let transcript: String
    let currentVisual: RoughCutVisualPlan
}

struct RoughCutVisualSuggestion: Codable, Equatable {
    let groupID: String
    let layout: RoughCutVisualLayout
    let detail: String

    private enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case layout
        case detail
    }
}

private struct RoughCutVisualSuggestionResponse: Codable {
    let suggestions: [RoughCutVisualSuggestion]
}

enum RoughCutVisualSuggestionValidator {
    static func validated(
        _ suggestions: [RoughCutVisualSuggestion],
        targetGroupIDs: Set<String>
    ) -> [String: RoughCutVisualPlan] {
        var result: [String: RoughCutVisualPlan] = [:]
        for suggestion in suggestions {
            let detail = suggestion.detail.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard targetGroupIDs.contains(suggestion.groupID),
                  result[suggestion.groupID] == nil,
                  suggestion.layout != .unassigned,
                  !suggestion.layout.needsDetail || !detail.isEmpty else {
                continue
            }
            result[suggestion.groupID] = RoughCutVisualPlan(
                layout: suggestion.layout,
                detail: detail,
                origin: .aiSuggested
            ).normalized
        }
        return result
    }
}

enum CodexVisualSuggestionError: LocalizedError {
    case executableMissing
    case failed(Int32, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "Codex CLI is not installed or could not be found."
        case let .failed(status, output):
            return "Codex visual suggestions failed with status \(status): \(output)"
        case let .invalidResponse(reason):
            return "Codex returned invalid visual suggestions: \(reason)"
        }
    }
}

struct CodexVisualSuggestionRunner {
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
            prompt,
        ]
    }

    static func requestData(clips: [RoughCutVisualSuggestionClip]) throws -> Data {
        let encodedClips: [[String: Any]] = clips.map { clip in
            let currentVisual: Any
            if clip.currentVisual.layout == .unassigned {
                currentVisual = NSNull()
            } else {
                currentVisual = [
                    "layout": clip.currentVisual.layout.rawValue,
                    "detail": clip.currentVisual.detail,
                    "origin": clip.currentVisual.origin.rawValue,
                ]
            }
            return [
                "group_id": clip.groupID,
                "clip_number": clip.clipNumber,
                "transcript": clip.transcript,
                "current_visual": currentVisual,
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["clips": encodedClips],
            options: [.sortedKeys]
        )
    }

    func run(
        clips: [RoughCutVisualSuggestionClip],
        targetGroupIDs: Set<String>,
        workingDirectoryURL: URL
    ) throws -> [String: RoughCutVisualPlan] {
        guard let executableURL = executableURL() else {
            throw CodexVisualSuggestionError.executableMissing
        }

        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "video-hq-codex-visuals-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectoryURL) }

        let schemaURL = temporaryDirectoryURL.appendingPathComponent(
            "visual-suggestions-schema.json"
        )
        let outputURL = temporaryDirectoryURL.appendingPathComponent(
            "visual-suggestions-output.json"
        )
        try Self.outputSchema.write(to: schemaURL, options: .atomic)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = Self.arguments(
            schemaURL: schemaURL,
            outputURL: outputURL,
            workingDirectoryURL: workingDirectoryURL
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = environment

        try process.run()
        try inputPipe.fileHandleForWriting.write(
            contentsOf: Self.requestData(clips: clips)
        )
        try inputPipe.fileHandleForWriting.close()
        let processOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CodexVisualSuggestionError.failed(
                process.terminationStatus,
                String(decoding: processOutput, as: UTF8.self)
            )
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw CodexVisualSuggestionError.invalidResponse(
                "the output file was not created"
            )
        }

        do {
            let response = try JSONDecoder().decode(
                RoughCutVisualSuggestionResponse.self,
                from: Data(contentsOf: outputURL)
            )
            return RoughCutVisualSuggestionValidator.validated(
                response.suggestions,
                targetGroupIDs: targetGroupIDs
            )
        } catch let error as CodexVisualSuggestionError {
            throw error
        } catch {
            throw CodexVisualSuggestionError.invalidResponse(
                error.localizedDescription
            )
        }
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

    static let prompt = """
    You are planning the visuals for a conversational spoken-to-camera technical video.
    Use only the ordered clip JSON supplied on stdin. Do not inspect files or run tools.

    The clips whose current_visual origin is human are the strongest evidence for the
    creator's style. An ai_suggested origin is a previous suggestion, not human evidence.
    Preserve every existing choice. Return one suggestion for every clip whose
    current_visual is null, using its exact group_id. The production rules below override
    any inconsistent layout labels in the human examples.

    Continue this visual language:
    - Use talking head for connective dialogue, emphasis, rhetorical questions, section
      transitions, and moments where no additional visual would genuinely help.
    - Use real docs, websites, product pages, screen recordings, or existing videos when
      the dialogue references something concrete or externally verifiable.
    - Use AI B-roll for abstract concepts, visual metaphors, humour, and ideas that would
      be difficult to source or film literally.
    - Use camera cutout or screencast with camera when a walkthrough benefits from keeping
      the presenter visibly connected to the explanation.
    - Do not change visual treatment merely because a new clip begins. Create coherent
      short runs, then return to talking head to reset the viewer.
    - Prefer a straightforward talking-head suggestion over generic or decorative B-roll.

    Apply these production rules:
    - A screen recording is anything browsed or operated live: documentation, repositories,
      product pages, dashboards, terminals, application UI, or the creator's own video page.
      B-roll means prerecorded self-captured footage, licensed stock, publisher-approved
      branded footage, or creator-owned archive. AI B-roll means generated imagery.
    - Never invent product UI, product behaviour, warnings, notifications, pages, commands,
      or capabilities. A product-behaviour suggestion must name a real reproduction plan:
      the real project or page, the genuine trigger, and any required prepared data. If a
      real reproduction plan is not credible, use real documentation or talking head.
    - Do not name a page or URL unless it is known from the dialogue or human examples.
      When uncertain, describe how to navigate from the real official documentation rather
      than hallucinating a destination.
    - Consecutive screenRecordingFullScreen or screencastWithCamera clips that cover one
      walkthrough must be one continuous recording session. State the session setup and
      prerequisites in the first detail, then say "Continue the same session" and preserve
      cursor, application, account, project, deployment, and seeded-data continuity.
    - Consecutive AI B-roll clips for one concept must use a shared visual system. Define
      that system in the first detail, then explicitly continue and evolve it in later clips
      instead of switching metaphors or art direction.
    - For branded or third-party B-roll, include a sourcing note in the detail such as
      self-captured, creator-owned, licensed stock, or publisher-approved footage. Never
      suggest grabbing arbitrary footage from another creator.
    - When referring to one of the creator's own videos, prefer talking head with a thumbnail
      overlay or a screen recording of the real video page rather than classifying it as B-roll.
    - If one long clip contains several visual beats, provide a short ordered shot sequence
      and the preparation required. Keep it within one coherent production approach rather
      than combining unrelated source types.

    For layouts that need detail, provide a concise but production-ready description of
    exactly what should be shown, how it connects to adjacent clips, and any prerequisite
    assets or setup. For talking head or camera cutout, return an empty detail string.
    Allowed layouts are talkingHeadFullScreen, cameraCutoutCorner, bRollFullScreen,
    screenRecordingFullScreen, aiBRollFullScreen, and screencastWithCamera.
    """

    private static let outputSchema = Data(
        """
        {
          "type": "object",
          "properties": {
            "suggestions": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "group_id": {"type": "string"},
                  "layout": {
                    "type": "string",
                    "enum": [
                      "talkingHeadFullScreen",
                      "cameraCutoutCorner",
                      "bRollFullScreen",
                      "screenRecordingFullScreen",
                      "aiBRollFullScreen",
                      "screencastWithCamera"
                    ]
                  },
                  "detail": {"type": "string"}
                },
                "required": ["group_id", "layout", "detail"],
                "additionalProperties": false
              }
            }
          },
          "required": ["suggestions"],
          "additionalProperties": false
        }
        """.utf8
    )
}
