import Foundation

enum RoughCutProcessStage: String, CaseIterable, Identifiable {
    case review
    case visuals

    var id: String { rawValue }

    var label: String {
        switch self {
        case .review: return "1. Clips"
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
    var origin: RoughCutVisualOrigin

    static let unassigned = RoughCutVisualPlan(
        layout: .unassigned,
        detail: "",
        origin: .human
    )

    init(
        layout: RoughCutVisualLayout,
        detail: String,
        origin: RoughCutVisualOrigin = .human
    ) {
        self.layout = layout
        self.detail = detail
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case layout
        case detail
        case origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decode(RoughCutVisualLayout.self, forKey: .layout)
        detail = try container.decode(String.self, forKey: .detail)
        origin = try container.decodeIfPresent(
            RoughCutVisualOrigin.self,
            forKey: .origin
        ) ?? .human
    }

    var isAISuggested: Bool {
        layout != .unassigned && origin == .aiSuggested
    }

    var normalized: RoughCutVisualPlan {
        guard layout != .unassigned else { return .unassigned }
        return RoughCutVisualPlan(
            layout: layout,
            detail: layout.needsDetail ? detail : "",
            origin: origin
        )
    }
}

enum RoughCutVisualOrigin: String, Codable, Equatable {
    case human
    case aiSuggested = "ai_suggested"
}

enum RoughCutVisualEditor {
    static func plan(
        selecting layout: RoughCutVisualLayout,
        detail: String
    ) -> RoughCutVisualPlan {
        RoughCutVisualPlan(
            layout: layout,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            origin: .human
        ).normalized
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

struct RoughCutReviewHierarchyItem: Equatable, Identifiable {
    let id: String
    let regionIDs: [String]
    let groupID: String?

    var isJoinedParent: Bool {
        groupID != nil && regionIDs.count > 1
    }
}

enum RoughCutReviewHierarchy {
    static func items(
        regionIDsInSourceOrder: [String],
        visibleRegionIDs: [String],
        process: RoughCutProcessDocument
    ) -> [RoughCutReviewHierarchyItem] {
        let visibleRegionIDs = Set(visibleRegionIDs)
        let groupByRegionID = Dictionary(
            uniqueKeysWithValues: process.groups.flatMap { group in
                group.regionIDs.map { ($0, group) }
            }
        )
        var emittedGroupIDs = Set<String>()
        var items: [RoughCutReviewHierarchyItem] = []

        for regionID in regionIDsInSourceOrder where visibleRegionIDs.contains(regionID) {
            guard let group = groupByRegionID[regionID] else {
                items.append(RoughCutReviewHierarchyItem(
                    id: "region-\(regionID)",
                    regionIDs: [regionID],
                    groupID: nil
                ))
                continue
            }
            guard emittedGroupIDs.insert(group.id).inserted else { continue }
            items.append(RoughCutReviewHierarchyItem(
                id: "group-\(group.id)",
                regionIDs: group.regionIDs,
                groupID: group.id
            ))
        }
        return items
    }
}

enum RoughCutClipSelection {
    struct Update: Equatable {
        let selectedGroupIDs: Set<String>
        let focusedGroupID: String?
    }

    static func select(
        _ groupID: String,
        in currentSelection: Set<String>,
        additive: Bool
    ) -> Set<String> {
        additive ? currentSelection.union([groupID]) : [groupID]
    }

    static func toggle(
        _ groupID: String,
        in currentSelection: Set<String>,
        focusedGroupID: String?,
        orderedGroupIDs: [String]
    ) -> Update {
        var selection = currentSelection
        let newFocus: String?
        if selection.remove(groupID) != nil {
            newFocus = focusedGroupID == groupID
                ? orderedGroupIDs.first(where: selection.contains)
                : focusedGroupID
        } else {
            selection.insert(groupID)
            newFocus = focusedGroupID ?? groupID
        }
        return Update(
            selectedGroupIDs: selection,
            focusedGroupID: newFocus
        )
    }
}

enum RoughCutPlaybackStartBehavior {
    case explicitPlay
    case rowSelection(wasPlaying: Bool)

    var shouldAutoplay: Bool {
        switch self {
        case .explicitPlay:
            return true
        case let .rowSelection(wasPlaying):
            return wasPlaying
        }
    }
}

enum RoughCutPlaybackContinuation {
    static func shouldContinue(
        isPlayerPlaying: Bool,
        isAutoplayBuildPending: Bool
    ) -> Bool {
        isPlayerPlaying || isAutoplayBuildPending
    }
}

struct RoughCutPlaybackPositionUpdate: Equatable {
    let revision: UInt
    let playbackTime: Double

    static let initial = RoughCutPlaybackPositionUpdate(
        revision: 0,
        playbackTime: 0
    )
}

enum RoughCutAutoplayAuthorization {
    static func isCurrent(
        expectedGeneration: UInt,
        playbackGeneration: UInt,
        authorizedGeneration: UInt?
    ) -> Bool {
        expectedGeneration == playbackGeneration
            && authorizedGeneration == expectedGeneration
    }
}

enum RoughCutListPlayheadVisibility {
    static func showOnParent(isActive: Bool, isExpanded: Bool) -> Bool {
        isActive && !isExpanded
    }

    static func showOnChild(isActive: Bool) -> Bool {
        isActive
    }
}

enum RoughCutDisplayedPlaybackPosition {
    static func sourceTime(
        scrubbedSourceTime: Double?,
        clockSourceTime: Double
    ) -> Double {
        scrubbedSourceTime ?? clockSourceTime
    }
}

enum RoughCutTimelineGeometry {
    struct NormalizedRange {
        let start: Double
        let length: Double
    }

    static func normalizedPosition(time: Double, duration: Double) -> Double {
        max(0, min(1, time / max(duration, 0.001)))
    }

    static func normalizedRange(
        start: Double,
        end: Double,
        duration: Double
    ) -> NormalizedRange {
        let normalizedStart = normalizedPosition(time: start, duration: duration)
        let normalizedEnd = normalizedPosition(time: end, duration: duration)
        return NormalizedRange(
            start: normalizedStart,
            length: max(0, normalizedEnd - normalizedStart)
        )
    }
}

enum RoughCutVisualDraftPersistence {
    static func shouldPersist(
        isDirty: Bool,
        selectedGroupCount: Int
    ) -> Bool {
        isDirty && selectedGroupCount > 0
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

    func assigningSuggestedVisuals(
        _ visualsByGroupID: [String: RoughCutVisualPlan]
    ) -> RoughCutProcessDocument {
        var updated = self
        for index in updated.groups.indices {
            let group = updated.groups[index]
            guard group.visual.layout == .unassigned || group.visual.isAISuggested,
                  let suggestion = visualsByGroupID[group.id],
                  suggestion.isAISuggested else {
                continue
            }
            updated.groups[index].visual = suggestion.normalized
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
