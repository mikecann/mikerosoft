import Foundation

enum RoughCutProcessStage: String, CaseIterable, Identifiable {
    case review
    case visuals

    var id: String { rawValue }

    var label: String {
        switch self {
        case .review: return "1. Review"
        case .visuals: return "2. Visuals"
        }
    }
}

enum RoughCutVisualLayout: String, Codable, CaseIterable, Identifiable {
    case unassigned
    case talkingHeadFullScreen
    case cameraCutoutCorner
    case bRollFullScreen
    case screenRecordingFullScreen
    case aiBRollFullScreen
    case screencastWithCamera

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unassigned: return "Not planned"
        case .talkingHeadFullScreen: return "Talking head"
        case .cameraCutoutCorner: return "Camera cutout in corner"
        case .bRollFullScreen: return "B-roll full screen"
        case .screenRecordingFullScreen: return "Screen recording"
        case .aiBRollFullScreen: return "AI B-roll"
        case .screencastWithCamera: return "Screencast + camera"
        }
    }

    var systemImage: String {
        switch self {
        case .unassigned: return "questionmark.square.dashed"
        case .talkingHeadFullScreen: return "person.crop.rectangle"
        case .cameraCutoutCorner: return "person.crop.square"
        case .bRollFullScreen: return "film.stack"
        case .screenRecordingFullScreen: return "display"
        case .aiBRollFullScreen: return "sparkles.rectangle.stack"
        case .screencastWithCamera: return "rectangle.inset.filled.and.person.filled"
        }
    }

    var needsDetail: Bool {
        switch self {
        case .bRollFullScreen, .screenRecordingFullScreen, .aiBRollFullScreen,
             .screencastWithCamera:
            return true
        case .unassigned, .talkingHeadFullScreen, .cameraCutoutCorner:
            return false
        }
    }
}

struct RoughCutVisualPlan: Codable, Equatable {
    var layout: RoughCutVisualLayout
    var detail: String

    static let unassigned = RoughCutVisualPlan(layout: .unassigned, detail: "")

    var normalized: RoughCutVisualPlan {
        RoughCutVisualPlan(
            layout: layout,
            detail: layout.needsDetail ? detail : ""
        )
    }
}

struct RoughCutStoryBeat: Codable, Equatable, Identifiable {
    let id: String
    var regionIDs: [String]
    var visual: RoughCutVisualPlan

    private enum CodingKeys: String, CodingKey {
        case id
        case regionIDs = "region_ids"
        case legacyRegionIDs = "region_i_ds"
        case visual
    }

    init(id: String, regionIDs: [String], visual: RoughCutVisualPlan) {
        self.id = id
        self.regionIDs = regionIDs
        self.visual = visual
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        regionIDs = try container.decodeIfPresent([String].self, forKey: .regionIDs)
            ?? container.decode([String].self, forKey: .legacyRegionIDs)
        visual = try container.decode(RoughCutVisualPlan.self, forKey: .visual)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(regionIDs, forKey: .regionIDs)
        try container.encode(visual, forKey: .visual)
    }
}

enum RoughCutProcessError: LocalizedError {
    case selectAtLeastTwo
    case selectionMustBeContiguous

    var errorDescription: String? {
        switch self {
        case .selectAtLeastTwo:
            return "Select at least two adjacent story beats to merge."
        case .selectionMustBeContiguous:
            return "Only adjacent story beats can be merged."
        }
    }
}

struct RoughCutProcessDocument: Codable, Equatable {
    let schemaVersion: Int
    var groups: [RoughCutStoryBeat]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case groups
    }

    static func initial(acceptedRegionIDs: [String]) -> RoughCutProcessDocument {
        RoughCutProcessDocument(
            schemaVersion: 1,
            groups: acceptedRegionIDs.map(singletonBeat)
        )
    }

    func reconciled(acceptedRegionIDs: [String]) -> RoughCutProcessDocument {
        let accepted = Set(acceptedRegionIDs)
        let priorByRegion = Dictionary(
            uniqueKeysWithValues: groups.flatMap { group in
                group.regionIDs.map { ($0, group) }
            }
        )

        struct Run {
            let originalGroupID: String?
            var regionIDs: [String]
            let visual: RoughCutVisualPlan
        }

        var runs: [Run] = []
        for regionID in acceptedRegionIDs where accepted.contains(regionID) {
            let prior = priorByRegion[regionID]
            let originalGroupID = prior?.id
            if runs.last?.originalGroupID == originalGroupID,
               originalGroupID != nil {
                runs[runs.count - 1].regionIDs.append(regionID)
            } else {
                runs.append(Run(
                    originalGroupID: originalGroupID,
                    regionIDs: [regionID],
                    visual: prior?.visual.normalized ?? .unassigned
                ))
            }
        }

        return RoughCutProcessDocument(
            schemaVersion: schemaVersion,
            groups: runs.map { run in
                RoughCutStoryBeat(
                    id: run.regionIDs.count == 1
                        ? run.regionIDs[0]
                        : Self.storyBeatID(for: run.regionIDs),
                    regionIDs: run.regionIDs,
                    visual: run.visual
                )
            }
        )
    }

    func merging(groupIDs: Set<String>) throws -> RoughCutProcessDocument {
        let selectedIndices = groups.indices.filter { groupIDs.contains(groups[$0].id) }
        guard selectedIndices.count >= 2 else {
            throw RoughCutProcessError.selectAtLeastTwo
        }
        guard zip(selectedIndices, selectedIndices.dropFirst()).allSatisfy({
            $1 == $0 + 1
        }) else {
            throw RoughCutProcessError.selectionMustBeContiguous
        }

        let firstIndex = selectedIndices[0]
        let selectedGroups = selectedIndices.map { groups[$0] }
        let regionIDs = selectedGroups.flatMap(\.regionIDs)
        let commonVisual = selectedGroups.dropFirst().allSatisfy({
            $0.visual == selectedGroups[0].visual
        }) ? selectedGroups[0].visual : .unassigned
        let merged = RoughCutStoryBeat(
            id: Self.storyBeatID(for: regionIDs),
            regionIDs: regionIDs,
            visual: commonVisual
        )

        var updated = groups
        for index in selectedIndices.reversed() {
            updated.remove(at: index)
        }
        updated.insert(merged, at: firstIndex)
        return RoughCutProcessDocument(schemaVersion: schemaVersion, groups: updated)
    }

    func unmerging(groupIDs: Set<String>) -> RoughCutProcessDocument {
        let updated = groups.flatMap { group -> [RoughCutStoryBeat] in
            guard groupIDs.contains(group.id), group.regionIDs.count > 1 else {
                return [group]
            }
            return group.regionIDs.map { regionID in
                RoughCutStoryBeat(
                    id: regionID,
                    regionIDs: [regionID],
                    visual: group.visual
                )
            }
        }
        return RoughCutProcessDocument(schemaVersion: schemaVersion, groups: updated)
    }

    func assigningVisual(
        _ visual: RoughCutVisualPlan,
        toGroupIDs groupIDs: Set<String>
    ) -> RoughCutProcessDocument {
        var updated = self
        let normalizedVisual = visual.normalized
        for index in updated.groups.indices where groupIDs.contains(updated.groups[index].id) {
            updated.groups[index].visual = normalizedVisual
        }
        return updated
    }

    private static func singletonBeat(regionID: String) -> RoughCutStoryBeat {
        RoughCutStoryBeat(
            id: regionID,
            regionIDs: [regionID],
            visual: .unassigned
        )
    }

    private static func storyBeatID(for regionIDs: [String]) -> String {
        guard let first = regionIDs.first, let last = regionIDs.last else {
            return "empty-story-beat"
        }
        return "beat-\(first)-through-\(last)"
    }
}

struct RoughCutProcessStore {
    let analysisDirectoryURL: URL

    var processURL: URL {
        analysisDirectoryURL.appendingPathComponent("video-hq-process.json")
    }

    func load() throws -> RoughCutProcessDocument {
        let decoder = JSONDecoder()
        return try decoder.decode(
            RoughCutProcessDocument.self,
            from: Data(contentsOf: processURL)
        )
    }

    func loadOrCreate(acceptedRegionIDs: [String]) throws -> RoughCutProcessDocument {
        guard FileManager.default.fileExists(atPath: processURL.path) else {
            return .initial(acceptedRegionIDs: acceptedRegionIDs)
        }
        return try load().reconciled(acceptedRegionIDs: acceptedRegionIDs)
    }

    func save(_ process: RoughCutProcessDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(process).write(to: processURL, options: .atomic)
    }
}
