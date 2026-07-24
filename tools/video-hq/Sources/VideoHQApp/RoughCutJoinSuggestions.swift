import AVFoundation
import Foundation

struct RoughCutTranscript: Decodable, Equatable {
    struct Segment: Decodable, Equatable {
        let start: Double
        let end: Double
        let text: String
        let words: [Word]
    }

    struct Word: Decodable, Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    let schemaVersion: Int
    let segments: [Segment]

    var words: [Word] {
        segments.flatMap(\.words).sorted { $0.start < $1.start }
    }

    static func decode(from data: Data) throws -> RoughCutTranscript {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RoughCutTranscript.self, from: data)
    }
}

struct RoughCutRegionPair: Codable, Equatable, Hashable {
    let left: String
    let right: String
}

struct RoughCutPlaybackClip: Equatable {
    let regionID: String
    let sourceStart: Double
    let sourceEnd: Double
    let crossfadeAfter: Double

    var duration: Double { max(0, sourceEnd - sourceStart) }
}

struct RoughCutPlaybackPlan: Equatable {
    let clips: [RoughCutPlaybackClip]

    var duration: Double {
        clips.reduce(0) { $0 + $1.duration - $1.crossfadeAfter }
    }
}

enum RoughCutSpeechJoinPlanner {
    static let incomingSpeechHandle = 0.06
    static let outgoingSpeechHandle = 0.08
    static let crossfadeDuration = 0.04

    static func plan(
        regions: [RoughCutRegion],
        words: [RoughCutTranscript.Word],
        joinedPairs: Set<RoughCutRegionPair>
    ) -> RoughCutPlaybackPlan {
        let incomingRegionIDs = Set(joinedPairs.map(\.right))

        let clips = regions.enumerated().map { index, region in
            let regionWords = words.filter {
                $0.end > region.start && $0.start < region.end
            }
            let sourceStart: Double
            if incomingRegionIDs.contains(region.id), let firstWord = regionWords.first {
                sourceStart = max(region.start, firstWord.start - incomingSpeechHandle)
            } else {
                sourceStart = region.start
            }

            // Tighten the tail to the final spoken word. The small handle retains
            // room tone and lets the crossfade happen outside the consonant itself.
            let sourceEnd = min(
                region.end,
                (regionWords.last?.end).map { $0 + outgoingSpeechHandle } ?? region.end
            )
            let nextID = regions.indices.contains(index + 1) ? regions[index + 1].id : nil
            let isJoinedToNext = nextID.map {
                joinedPairs.contains(RoughCutRegionPair(left: region.id, right: $0))
            } ?? false
            let availableDuration = max(0, sourceEnd - sourceStart)
            let crossfade = isJoinedToNext
                ? min(crossfadeDuration, availableDuration / 4)
                : 0

            return RoughCutPlaybackClip(
                regionID: region.id,
                sourceStart: sourceStart,
                sourceEnd: max(sourceStart, sourceEnd),
                crossfadeAfter: crossfade
            )
        }

        return RoughCutPlaybackPlan(clips: clips)
    }
}

enum RoughCutJoinDecision: String, Codable, CaseIterable, Identifiable {
    case pending
    case approved
    case rejected

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pending: return "Not decided"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        }
    }
}

struct RoughCutJoinSuggestion: Codable, Equatable, Identifiable {
    let regionIDs: [String]
    let confidence: Double
    let reason: String
    var decision: RoughCutJoinDecision

    var id: String { regionIDs.joined(separator: "|") }

    private enum CodingKeys: String, CodingKey {
        case regionIDs = "region_ids"
        case confidence
        case reason
        case decision
    }

    init(
        regionIDs: [String],
        confidence: Double,
        reason: String,
        decision: RoughCutJoinDecision = .pending
    ) {
        self.regionIDs = regionIDs
        self.confidence = confidence
        self.reason = reason
        self.decision = decision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regionIDs = try container.decode([String].self, forKey: .regionIDs)
        confidence = try container.decode(Double.self, forKey: .confidence)
        reason = try container.decode(String.self, forKey: .reason)
        decision = try container.decodeIfPresent(
            RoughCutJoinDecision.self,
            forKey: .decision
        ) ?? .pending
    }
}

struct RoughCutJoinSuggestionResponse: Codable, Equatable {
    let suggestions: [RoughCutJoinSuggestion]
}

struct RoughCutJoinSectionIndicator: Equatable {
    let suggestionID: String
    let proposalNumber: Int
    let clipNumber: Int
    let clipCount: Int
    let reason: String
    let decision: RoughCutJoinDecision

    var showsInlineAction: Bool {
        clipNumber == clipCount
    }

    static func byRegionID(
        suggestions: [RoughCutJoinSuggestion]
    ) -> [String: [RoughCutJoinSectionIndicator]] {
        var result: [String: [RoughCutJoinSectionIndicator]] = [:]
        for (proposalIndex, suggestion) in suggestions.enumerated() {
            for (clipIndex, regionID) in suggestion.regionIDs.enumerated() {
                result[regionID, default: []].append(
                    RoughCutJoinSectionIndicator(
                        suggestionID: suggestion.id,
                        proposalNumber: proposalIndex + 1,
                        clipNumber: clipIndex + 1,
                        clipCount: suggestion.regionIDs.count,
                        reason: suggestion.reason,
                        decision: suggestion.decision
                    )
                )
            }
        }
        return result
    }
}

enum RoughCutJoinSuggestionValidator {
    static func validated(
        _ suggestions: [RoughCutJoinSuggestion],
        acceptedRegionIDs: [String]
    ) -> [RoughCutJoinSuggestion] {
        let indices = Dictionary(
            uniqueKeysWithValues: acceptedRegionIDs.enumerated().map { ($1, $0) }
        )
        var seen: Set<String> = []

        return suggestions.filter { suggestion in
            guard suggestion.regionIDs.count >= 2,
                  suggestion.confidence.isFinite,
                  (0...1).contains(suggestion.confidence),
                  !suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(suggestion.regionIDs).count == suggestion.regionIDs.count else {
                return false
            }
            let positions = suggestion.regionIDs.compactMap { indices[$0] }
            guard positions.count == suggestion.regionIDs.count,
                  zip(positions, positions.dropFirst()).allSatisfy({
                      $1 == $0 + 1
                  }),
                  seen.insert(suggestion.id).inserted else {
                return false
            }
            return true
        }
        .sorted {
            if $0.regionIDs.first != $1.regionIDs.first {
                return (indices[$0.regionIDs[0]] ?? .max)
                    < (indices[$1.regionIDs[0]] ?? .max)
            }
            return $0.confidence > $1.confidence
        }
    }
}

enum RoughCutJoinSuggestionReconciler {
    static func reconcile(
        refreshed: [RoughCutJoinSuggestion],
        previous: [RoughCutJoinSuggestion],
        acceptedRegionIDs: [String]
    ) -> [RoughCutJoinSuggestion] {
        let validPrevious = RoughCutJoinSuggestionValidator.validated(
            previous,
            acceptedRegionIDs: acceptedRegionIDs
        )
        let validRefreshed = RoughCutJoinSuggestionValidator.validated(
            refreshed,
            acceptedRegionIDs: acceptedRegionIDs
        )
        let previousByID = Dictionary(uniqueKeysWithValues: validPrevious.map { ($0.id, $0) })
        let refreshedByID = Dictionary(uniqueKeysWithValues: validRefreshed.map { ($0.id, $0) })
        let orderedIDs = validPrevious.map(\.id)
            + validRefreshed.map(\.id).filter { previousByID[$0] == nil }

        return orderedIDs.compactMap { id in
            if let latest = refreshedByID[id], let old = previousByID[id] {
                return RoughCutJoinSuggestion(
                    regionIDs: latest.regionIDs,
                    confidence: latest.confidence,
                    reason: latest.reason,
                    decision: old.decision
                )
            }
            return previousByID[id] ?? refreshedByID[id]
        }
        .sorted {
            let left = acceptedRegionIDs.firstIndex(of: $0.regionIDs[0]) ?? .max
            let right = acceptedRegionIDs.firstIndex(of: $1.regionIDs[0]) ?? .max
            if left != right { return left < right }
            return $0.confidence > $1.confidence
        }
    }
}

struct RoughCutJoinDecisionResult: Equatable {
    let proposal: RoughCutJoinSuggestion
    let process: RoughCutProcessDocument
}

enum RoughCutJoinDecisionWorkflow {
    static func apply(
        _ decision: RoughCutJoinDecision,
        to proposal: RoughCutJoinSuggestion,
        process: RoughCutProcessDocument
    ) throws -> RoughCutJoinDecisionResult {
        let proposalIDs = Set(proposal.regionIDs)
        let matchingGroups = process.groups.filter {
            !proposalIDs.isDisjoint(with: $0.regionIDs)
        }
        guard matchingGroups.flatMap(\.regionIDs) == proposal.regionIDs else {
            throw RoughCutProcessError.selectionMustBeContiguous
        }

        let updatedProcess: RoughCutProcessDocument
        switch decision {
        case .approved:
            if matchingGroups.count == 1 {
                updatedProcess = process
            } else {
                updatedProcess = try process.merging(
                    groupIDs: Set(matchingGroups.map(\.id))
                )
            }
        case .pending, .rejected:
            if matchingGroups.count == 1, matchingGroups[0].regionIDs.count > 1 {
                updatedProcess = process.unmerging(groupIDs: [matchingGroups[0].id])
            } else {
                updatedProcess = process
            }
        }

        var updatedProposal = proposal
        updatedProposal.decision = decision
        return RoughCutJoinDecisionResult(
            proposal: updatedProposal,
            process: updatedProcess
        )
    }
}

struct RoughCutJoinCandidate: Encodable {
    let regionID: String
    let start: Double
    let end: Double
    let transcript: String

    private enum CodingKeys: String, CodingKey {
        case regionID = "region_id"
        case start
        case end
        case transcript
    }
}

enum CodexJoinSuggestionError: LocalizedError {
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
                ? "Codex join suggestions failed with exit code \(status)."
                : "Codex join suggestions failed with exit code \(status):\n\(detail)"
        case .invalidResponse(let detail):
            return "Codex returned invalid join suggestions: \(detail)"
        }
    }
}

struct CodexJoinSuggestionRunner {
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
        candidates: [RoughCutJoinCandidate],
        acceptedRegionIDs: [String],
        workingDirectoryURL: URL
    ) throws -> [RoughCutJoinSuggestion] {
        guard let executableURL = executableURL() else {
            throw CodexJoinSuggestionError.executableMissing
        }

        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("video-hq-codex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectoryURL) }

        let schemaURL = temporaryDirectoryURL.appendingPathComponent("join-schema.json")
        let outputURL = temporaryDirectoryURL.appendingPathComponent("join-output.json")
        try Self.outputSchema.write(to: schemaURL, options: .atomic)

        let input = try JSONEncoder().encode([
            "clips": candidates
        ])
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
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
        try inputPipe.fileHandleForWriting.close()
        let processOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CodexJoinSuggestionError.failed(
                process.terminationStatus,
                String(decoding: processOutput, as: UTF8.self)
            )
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw CodexJoinSuggestionError.invalidResponse("the output file was not created")
        }
        do {
            let response = try JSONDecoder().decode(
                RoughCutJoinSuggestionResponse.self,
                from: Data(contentsOf: outputURL)
            )
            return RoughCutJoinSuggestionValidator.validated(
                response.suggestions,
                acceptedRegionIDs: acceptedRegionIDs
            )
        } catch let error as CodexJoinSuggestionError {
            throw error
        } catch {
            throw CodexJoinSuggestionError.invalidResponse(error.localizedDescription)
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

    private static let prompt = """
    You are identifying likely edit joins in a spoken-to-camera video.
    Use only the ordered clip JSON supplied on stdin. Do not inspect files or run tools.
    Suggest a join only when two or more adjacent clips clearly form one interrupted
    sentence or thought, such as a clip ending mid-clause and the next continuing it.
    Do not suggest joining complete sentences merely because their topics are related.
    Return no more than 20 high-confidence suggestions. Use exact region_id values,
    preserve their order, and explain the grammatical evidence briefly.
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
          "required": ["suggestions"],
          "additionalProperties": false
        }
        """.utf8
    )
}

struct RoughCutJoinSuggestionStore {
    let analysisDirectoryURL: URL

    var suggestionsURL: URL {
        analysisDirectoryURL.appendingPathComponent("video-hq-join-suggestions.json")
    }

    func load() throws -> [RoughCutJoinSuggestion] {
        guard FileManager.default.fileExists(atPath: suggestionsURL.path) else { return [] }
        return try JSONDecoder().decode(
            RoughCutJoinSuggestionResponse.self,
            from: Data(contentsOf: suggestionsURL)
        ).suggestions
    }

    func save(_ suggestions: [RoughCutJoinSuggestion]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            RoughCutJoinSuggestionResponse(suggestions: suggestions)
        ).write(to: suggestionsURL, options: .atomic)
    }
}

struct RoughCutPlaybackComposition {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix?
}

enum RoughCutPlaybackCompositionBuilder {
    static func build(
        sourceURL: URL,
        plan: RoughCutPlaybackPlan
    ) async throws -> RoughCutPlaybackComposition {
        let asset = AVURLAsset(url: sourceURL)
        let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        let videoTrack = sourceVideo.flatMap { _ in
            composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        if let sourceVideo {
            videoTrack?.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }

        let audioTracks = sourceAudio == nil ? [] : (0..<2).compactMap { _ in
            composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        let audioParameters = audioTracks.map(AVMutableAudioMixInputParameters.init(track:))

        var destinationStart = CMTime.zero
        var incomingCrossfade = 0.0
        for (index, clip) in plan.clips.enumerated() {
            let sourceStart = CMTime(seconds: clip.sourceStart, preferredTimescale: 600)
            let sourceDuration = CMTime(seconds: clip.duration, preferredTimescale: 600)
            let sourceRange = CMTimeRange(start: sourceStart, duration: sourceDuration)

            if let sourceVideo, let videoTrack {
                let videoDuration = max(0, clip.duration - clip.crossfadeAfter)
                try videoTrack.insertTimeRange(
                    CMTimeRange(
                        start: sourceStart,
                        duration: CMTime(seconds: videoDuration, preferredTimescale: 600)
                    ),
                    of: sourceVideo,
                    at: destinationStart
                )
            }

            if let sourceAudio, !audioTracks.isEmpty {
                let audioTrackIndex = index % audioTracks.count
                try audioTracks[audioTrackIndex].insertTimeRange(
                    sourceRange,
                    of: sourceAudio,
                    at: destinationStart
                )
                let parameters = audioParameters[audioTrackIndex]
                if incomingCrossfade > 0 {
                    parameters.setVolumeRamp(
                        fromStartVolume: 0,
                        toEndVolume: 1,
                        timeRange: CMTimeRange(
                            start: destinationStart,
                            duration: CMTime(
                                seconds: incomingCrossfade,
                                preferredTimescale: 600
                            )
                        )
                    )
                } else {
                    parameters.setVolume(1, at: destinationStart)
                }
                if clip.crossfadeAfter > 0 {
                    let fadeStart = destinationStart + CMTime(
                        seconds: clip.duration - clip.crossfadeAfter,
                        preferredTimescale: 600
                    )
                    parameters.setVolumeRamp(
                        fromStartVolume: 1,
                        toEndVolume: 0,
                        timeRange: CMTimeRange(
                            start: fadeStart,
                            duration: CMTime(
                                seconds: clip.crossfadeAfter,
                                preferredTimescale: 600
                            )
                        )
                    )
                }
            }

            destinationStart = destinationStart + CMTime(
                seconds: clip.duration - clip.crossfadeAfter,
                preferredTimescale: 600
            )
            incomingCrossfade = clip.crossfadeAfter
        }

        let audioMix: AVAudioMix?
        if audioParameters.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParameters
            audioMix = mix
        }
        return RoughCutPlaybackComposition(
            composition: composition,
            audioMix: audioMix
        )
    }
}
