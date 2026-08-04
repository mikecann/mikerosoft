import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum RoughCutPlaybackShortcut {
    static func shouldHandle(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isEditingText: Bool
    ) -> Bool {
        guard keyCode == 49, !isEditingText else { return false }
        let meaningfulModifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return meaningfulModifiers.isEmpty
    }
}

@MainActor
final class RoughCutReviewModel: ObservableObject {
    let project: VideoProject

    @Published private(set) var sourceVideos: [URL] = []
    @Published private(set) var selectedVideoURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var joinReviewPlayer: AVPlayer?
    @Published private(set) var analysis: RoughCutAnalysis?
    @Published private(set) var manualDecisions: [String: RoughCutManualDecision] = [:]
    @Published private(set) var process = RoughCutProcessDocument.initial(
        acceptedRegionIDs: []
    )
    @Published var selectedGroupIDs = Set<String>()
    @Published var focusedGroupID: String?
    @Published var expandedGroupIDs = Set<String>()
    @Published var editorVisualLayout: RoughCutVisualLayout = .unassigned
    @Published var editorVisualDetail = ""
    @Published var isEditorVisualDirty = false
    @Published var stage: RoughCutProcessStage = .review
    @Published private(set) var regionFilterSelection = RoughCutRegionFilterSelection.all
    @Published private(set) var joinSuggestions: [RoughCutJoinSuggestion] = []
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var isImporting = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isExporting = false
    @Published private(set) var isSuggestingJoins = false
    @Published private(set) var isSuggestingVisuals = false
    @Published private(set) var isBuildingPlaybackPreview = false
    @Published private(set) var isBuildingJoinPreview = false
    @Published private(set) var playbackPositionUpdate =
        RoughCutPlaybackPositionUpdate.initial
    @Published private(set) var statusMessage = "Choose a source recording to begin."
    @Published var errorMessage: String?
    private let sourceLibrary: RoughCutSourceLibrary
    private let analysisStore: RoughCutAnalysisStore
    private let runner: FilmoraRoughCutRunner
    private let codexAnalysisRunner = CodexRoughCutAnalysisRunner()
    private let exportRunner: FilmoraRoughCutExportRunner
    private let codexJoinRunner = CodexJoinSuggestionRunner()
    private let codexVisualRunner = CodexVisualSuggestionRunner()
    private var transcriptWords: [RoughCutTranscript.Word] = []
    private var isPlayingComposition = false
    private var activePlaybackPlan: RoughCutPlaybackPlan?
    private var playbackBuildGeneration: UInt = 0
    private var joinReviewBuildGeneration: UInt = 0
    private var autoplayBuildPending = false
    private weak var playerAwaitingAutoplay: AVPlayer?
    private var playerAwaitingAutoplayGeneration: UInt?
    private var playerAwaitingAutoplayTime = 0.0
    private var playbackPositionRevision: UInt = 0

    init(project: VideoProject, configuration: VideoHQConfiguration) {
        self.project = project
        sourceLibrary = RoughCutSourceLibrary(projectDirectoryURL: project.directoryURL)
        analysisStore = RoughCutAnalysisStore(projectDirectoryURL: project.directoryURL)
        runner = FilmoraRoughCutRunner(
            automationRootURL: configuration.filmoraAutomationRoot,
            pythonExecutableURL: configuration.roughCutPythonURL
        )
        exportRunner = FilmoraRoughCutExportRunner(
            automationRootURL: configuration.filmoraAutomationRoot,
            pythonExecutableURL: configuration.roughCutPythonURL
        )
        reloadSourceVideos(selectFirst: true)
    }

    var isWorking: Bool {
        isImporting || isAnalyzing || isExporting || isSuggestingJoins
            || isSuggestingVisuals
            || isBuildingPlaybackPreview || isBuildingJoinPreview
    }
    var canAnalyze: Bool { selectedVideoURL != nil && !isWorking }
    var canSuggestJoins: Bool { analysis != nil && acceptedRegions.count >= 2 && !isWorking }
    var analyzeButtonTitle: String { analysis == nil ? "Analyze Recording" : "Run Again" }
    var isPlaybackPlaying: Bool {
        guard let player else { return false }
        return player.timeControlStatus != .paused || player.rate > 0
    }
    var shouldContinuePlaybackOnSelection: Bool {
        RoughCutPlaybackContinuation.shouldContinue(
            isPlayerPlaying: isPlaybackPlaying,
            isAutoplayBuildPending: autoplayBuildPending
        )
    }
    var shouldFollowPlaybackPosition: Bool {
        isPlaybackPlaying || autoplayBuildPending
    }
    var effectiveRegions: [RoughCutRegion] {
        analysis?.plan.regions.map {
            $0.applyingManualDecision(manualDecisions[$0.id])
        } ?? []
    }
    var acceptedRegions: [RoughCutRegion] {
        effectiveRegions.filter { $0.decision == "keep" }
    }
    var reviewedPlaybackPlan: RoughCutPlaybackPlan {
        RoughCutReviewedCutPlanner.plan(
            regions: effectiveRegions,
            words: transcriptWords,
            process: process
        )
    }
    var unresolvedReviewCount: Int {
        guard let regions = analysis?.plan.regions else { return 0 }
        return RoughCutRegionFilter.awaitingDecision.apply(
            to: regions,
            manualDecisions: manualDecisions
        ).count
    }
    var plannedVisualCount: Int {
        process.groups.filter { $0.visual.layout != .unassigned }.count
    }
    var aiSuggestedVisualCount: Int {
        process.groups.filter(\.visual.isAISuggested).count
    }
    var unplannedVisualCount: Int {
        process.groups.count - plannedVisualCount
    }
    var suggestibleVisualCount: Int {
        unplannedVisualCount + aiSuggestedVisualCount
    }
    var canSuggestVisuals: Bool {
        analysis != nil && suggestibleVisualCount > 0 && !isWorking
    }
    var pendingJoinCount: Int {
        joinSuggestions.filter { $0.decision == .pending }.count
    }
    var approvedJoinCount: Int {
        joinSuggestions.filter { $0.decision == .approved }.count
    }
    var rejectedJoinCount: Int {
        joinSuggestions.filter { $0.decision == .rejected }.count
    }

    func reloadSourceVideos(selectFirst: Bool = false) {
        do {
            sourceVideos = try sourceLibrary.videos()
            if let selectedVideoURL,
               sourceVideos.contains(where: {
                   $0.standardizedFileURL == selectedVideoURL.standardizedFileURL
               }) {
                return
            }
            if selectFirst, let first = sourceVideos.first {
                selectVideo(first)
            } else if sourceVideos.isEmpty {
                clearSelection()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseAndImportVideo() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Source Recording"
        panel.message = "The recording will be copied into \(project.name)/source."
        panel.prompt = "Copy to Source"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = sourceLibrary.sourceDirectoryURL
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        isImporting = true
        statusMessage = "Copying \(sourceURL.lastPathComponent) into the project source directory..."
        let library = sourceLibrary
        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try library.importVideo(at: sourceURL)
                }.value
                reloadSourceVideos()
                isImporting = false
                selectVideo(imported)
                statusMessage = "Imported \(imported.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Source import failed."
                isImporting = false
            }
        }
    }

    func selectVideo(_ url: URL) {
        guard !isWorking else { return }
        cancelPendingPlaybackBuild()
        stopAssembledPlayback()
        discardJoinReviewPlayback()
        player?.pause()
        selectedVideoURL = url
        player = AVPlayer(url: url)
        selectedGroupIDs.removeAll()
        focusedGroupID = nil
        expandedGroupIDs.removeAll()
        stage = .review
        editorVisualLayout = .unassigned
        editorVisualDetail = ""
        isEditorVisualDirty = false
        lastExportURL = nil
        isPlayingComposition = false
        activePlaybackPlan = nil

        do {
            analysis = try analysisStore.latestAnalysis(for: url)
            if let analysis {
                manualDecisions = try RoughCutOverrideStore(
                    analysisDirectoryURL: analysis.directoryURL
                ).load()
                try loadAndReconcileProcess(for: analysis)
            } else {
                manualDecisions = [:]
                process = .initial(acceptedRegionIDs: [])
                joinSuggestions = []
                transcriptWords = []
                regionFilterSelection = .all
            }
            if let analysis {
                statusMessage = "Loaded saved analysis from \(formatted(analysis.createdAt))."
            } else {
                statusMessage = "Source loaded. Analyze it to detect silence and repeated takes."
            }
        } catch {
            analysis = nil
            manualDecisions = [:]
            process = .initial(acceptedRegionIDs: [])
            joinSuggestions = []
            transcriptWords = []
            regionFilterSelection = .all
            errorMessage = error.localizedDescription
        }
    }

    func analyze() {
        guard canAnalyze, let sourceVideoURL = selectedVideoURL else { return }
        discardJoinReviewPlayback()
        isAnalyzing = true
        errorMessage = nil

        let store = analysisStore
        let runner = runner
        Task {
            do {
                let reusableTranscript = try await Task.detached(priority: .userInitiated) {
                    try store.reusableTranscriptURL(for: sourceVideoURL)
                }.value
                let transcriptNote: String
                if reusableTranscript?.pathExtension.lowercased() == "json" {
                    transcriptNote = "Reusing the saved word-timestamp transcript."
                } else if reusableTranscript != nil {
                    transcriptNote = "Reusing the existing source SRT."
                } else {
                    transcriptNote = "Transcribing each audible region first."
                }
                statusMessage = "Detecting silence and preparing the complete transcript. \(transcriptNote)"

                let prepared = try await Task.detached(priority: .userInitiated) {
                    let outputDirectoryURL = try store.newRunDirectoryURL(for: sourceVideoURL)
                    let inputURL = try runner.run(
                        videoURL: sourceVideoURL,
                        outputDirectoryURL: outputDirectoryURL,
                        transcriptURL: reusableTranscript
                    )
                    return (outputDirectoryURL, inputURL)
                }.value

                statusMessage = "Codex is reviewing the complete transcript for false starts, bad takes, and sections that need your call..."
                let codexRunner = codexAnalysisRunner
                let scriptURL = project.directoryURL.appendingPathComponent("script.md")
                let referenceScript = try? String(contentsOf: scriptURL, encoding: .utf8)
                let completed = try await Task.detached(priority: .userInitiated) {
                    let result = try codexRunner.run(
                        inputURL: prepared.1,
                        transcriptURL: prepared.0.appendingPathComponent("transcript.json"),
                        script: referenceScript,
                        outputPlanURL: prepared.0.appendingPathComponent("rough-cut-plan.json"),
                        workingDirectoryURL: prepared.0
                    )
                    try RoughCutJoinSuggestionStore(
                        analysisDirectoryURL: prepared.0
                    ).save(result.joinSuggestions)
                    return try store.recordCompletedRun(
                        at: prepared.0,
                        sourceVideoURL: sourceVideoURL
                    )
                }.value

                analysis = completed
                manualDecisions = [:]
                try loadAndReconcileProcess(for: completed)
                lastExportURL = nil
                statusMessage = pendingJoinCount == 0
                    ? "Analysis complete. Review the color-coded timeline and proposed decisions."
                    : "Analysis complete with \(pendingJoinCount) likely joins ready to preview in Step 1."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Rough-cut analysis failed."
            }
            isAnalyzing = false
        }
    }

    func seek(
        to seconds: Double,
        play: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        cancelPendingPlaybackBuild()
        stopAssembledPlayback()
        let seekTime: Double
        if isPlayingComposition, let activePlaybackPlan {
            // Keep the current composition attached while scrubbing included clips.
            // Gaps clamp to the nearest edit boundary so replacing the player
            // cannot destroy the SwiftUI drag gesture mid-scrub.
            seekTime = activePlaybackPlan.playbackTime(forSourceTime: seconds)
                ?? activePlaybackPlan.nearestPlaybackTime(forSourceTime: seconds)
        } else {
            restoreSourcePlayerIfNeeded()
            seekTime = seconds
        }
        guard let player else { return }
        player.seek(
            to: CMTime(seconds: max(0, seekTime), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            Task { @MainActor in
                if finished {
                    self.publishPlaybackPosition(player.currentTime().seconds)
                }
                completion?(finished)
            }
        }
        if play { player.play() }
    }

    func playReviewedCut() {
        guard let sourceURL = selectedVideoURL else { return }
        let plan = RoughCutReviewedCutPlanner.plan(
            regions: effectiveRegions,
            words: transcriptWords,
            process: process
        )
        guard !plan.clips.isEmpty else { return }

        let generation = beginPlaybackBuild(autoplay: true)
        stopAssembledPlayback()
        isBuildingPlaybackPreview = true
        statusMessage = "Building the reviewed cut with rejected sections and silences removed..."
        Task {
            do {
                let result = try await RoughCutPlaybackCompositionBuilder.build(
                    sourceURL: sourceURL,
                    plan: plan
                )
                guard selectedVideoURL?.standardizedFileURL
                    == sourceURL.standardizedFileURL,
                      generation == playbackBuildGeneration else { return }
                let item = AVPlayerItem(asset: result.composition)
                item.audioMix = result.audioMix
                let replacementPlayer = AVPlayer(playerItem: item)
                playerAwaitingAutoplay = replacementPlayer
                playerAwaitingAutoplayGeneration = generation
                playerAwaitingAutoplayTime = 0
                player = replacementPlayer
                isPlayingComposition = true
                activePlaybackPlan = plan
                statusMessage = "Playing the reviewed cut with approved joins and removed sections."
            } catch {
                if generation == playbackBuildGeneration {
                    autoplayBuildPending = false
                    errorMessage = error.localizedDescription
                    statusMessage = "Could not build the reviewed-cut playback."
                }
            }
            if generation == playbackBuildGeneration {
                isBuildingPlaybackPreview = false
            }
        }
    }

    func playFilteredCut(
        visibleRegionIDs: [String],
        startingAt startRegionID: String? = nil,
        startingAtSourceTime sourceTime: Double? = nil,
        autoplay: Bool = true
    ) {
        guard let sourceURL = selectedVideoURL else { return }
        let plan = RoughCutFilteredPlaybackPlanner.plan(
            regions: effectiveRegions,
            words: transcriptWords,
            process: process,
            visibleRegionIDs: Set(visibleRegionIDs),
            startingAt: nil
        )
        guard !plan.clips.isEmpty else {
            statusMessage = "The current filter does not contain any clips to play."
            return
        }
        let playbackStartTime = sourceTime.map {
            plan.playbackStartTime(forSourceTime: $0)
        } ?? plan.playbackStartTime(forRegionID: startRegionID)

        if RoughCutPlaybackReuse.shouldReuse(
            isPlayingComposition: isPlayingComposition,
            activePlan: activePlaybackPlan,
            requestedPlan: plan
        ) {
            seekExistingComposition(
                to: playbackStartTime,
                autoplay: autoplay
            )
            return
        }

        let generation = beginPlaybackBuild(autoplay: autoplay)
        stopAssembledPlayback()
        isBuildingPlaybackPreview = true
        statusMessage = "Building playback from the clips shown by the current filter..."
        Task {
            do {
                let result = try await RoughCutPlaybackCompositionBuilder.build(
                    sourceURL: sourceURL,
                    plan: plan
                )
                guard selectedVideoURL?.standardizedFileURL
                    == sourceURL.standardizedFileURL,
                      generation == playbackBuildGeneration else { return }
                let item = AVPlayerItem(asset: result.composition)
                item.audioMix = result.audioMix
                let replacementPlayer = AVPlayer(playerItem: item)
                if autoplay {
                    playerAwaitingAutoplay = replacementPlayer
                    playerAwaitingAutoplayGeneration = generation
                    playerAwaitingAutoplayTime = playbackStartTime
                } else {
                    _ = await replacementPlayer.seek(
                        to: CMTime(
                            seconds: playbackStartTime,
                            preferredTimescale: 600
                        ),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
                guard selectedVideoURL?.standardizedFileURL
                    == sourceURL.standardizedFileURL,
                      generation == playbackBuildGeneration else { return }
                player = replacementPlayer
                isPlayingComposition = true
                activePlaybackPlan = plan
                statusMessage = autoplay
                    ? "Playing the visible clips with excluded sections and silence skipped."
                    : "Ready at the selected clip with excluded sections and silence skipped."
            } catch {
                if generation == playbackBuildGeneration {
                    autoplayBuildPending = false
                    errorMessage = error.localizedDescription
                    statusMessage = "Could not build playback for the visible clips."
                }
            }
            if generation == playbackBuildGeneration {
                isBuildingPlaybackPreview = false
            }
        }
    }

    func playerViewDidAppear(_ attachedPlayer: AVPlayer) {
        guard player === attachedPlayer,
              playerAwaitingAutoplay === attachedPlayer,
              let expectedGeneration = playerAwaitingAutoplayGeneration else { return }
        let autoplayTime = playerAwaitingAutoplayTime
        playerAwaitingAutoplay = nil
        attachedPlayer.pause()
        attachedPlayer.seek(
            to: CMTime(seconds: autoplayTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak attachedPlayer] finished in
            Task { @MainActor [weak self] in
                guard let self, let attachedPlayer,
                      player === attachedPlayer,
                      RoughCutAutoplayAuthorization.isCurrent(
                          expectedGeneration: expectedGeneration,
                          playbackGeneration: playbackBuildGeneration,
                          authorizedGeneration: playerAwaitingAutoplayGeneration
                      ) else { return }
                guard finished else {
                    autoplayBuildPending = false
                    playerAwaitingAutoplayGeneration = nil
                    playerAwaitingAutoplayTime = 0
                    return
                }
                attachedPlayer.play()
                autoplayBuildPending = false
                playerAwaitingAutoplayGeneration = nil
                playerAwaitingAutoplayTime = 0
                publishPlaybackPosition(autoplayTime)
            }
        }
    }

    func showSourceRecording() {
        cancelPendingPlaybackBuild()
        stopAssembledPlayback()
        restoreSourcePlayerIfNeeded()
        statusMessage = "Showing the source recording."
    }

    func sourceTime(for playbackTime: Double) -> Double {
        activePlaybackPlan?.sourceTime(at: playbackTime) ?? playbackTime
    }

    func revealAnalysis() {
        guard let analysis else { return }
        NSWorkspace.shared.activateFileViewerSelecting([analysis.directoryURL])
    }

    func manualDecision(for regionID: String) -> RoughCutManualDecision {
        manualDecisions[regionID] ?? .automatic
    }

    func setManualDecision(_ decision: RoughCutManualDecision, for regionID: String) {
        guard let analysis else { return }
        let previous = manualDecisions
        let previousProcess = process
        if decision == .automatic {
            manualDecisions.removeValue(forKey: regionID)
        } else {
            manualDecisions[regionID] = decision
        }
        do {
            try RoughCutOverrideStore(analysisDirectoryURL: analysis.directoryURL).save(
                manualDecisions,
                validRegionIDs: analysis.plan.regions.map(\.id)
            )
            try reconcileAndSaveProcess(for: analysis)
            statusMessage = "Saved manual \(decision.label.lowercased()) decision for this section."
        } catch {
            manualDecisions = previous
            process = previousProcess
            try? RoughCutOverrideStore(analysisDirectoryURL: analysis.directoryURL).save(
                previous,
                validRegionIDs: analysis.plan.regions.map(\.id)
            )
            errorMessage = error.localizedDescription
        }
    }

    func setRegionFilterSelection(_ selection: RoughCutRegionFilterSelection) {
        guard let analysis else {
            regionFilterSelection = selection
            return
        }
        let previous = regionFilterSelection
        regionFilterSelection = selection
        do {
            try RoughCutViewStateStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(selection)
        } catch {
            regionFilterSelection = previous
            errorMessage = error.localizedDescription
        }
    }

    func regions(for group: RoughCutStoryBeat) -> [RoughCutRegion] {
        let byID = Dictionary(uniqueKeysWithValues: effectiveRegions.map { ($0.id, $0) })
        return group.regionIDs.compactMap { byID[$0] }
    }

    func duration(of group: RoughCutStoryBeat) -> Double {
        guard group.regionIDs.count > 1 else {
            return regions(for: group).reduce(0) { $0 + $1.duration }
        }
        return playbackPlan(for: group).duration
    }

    func transcript(for group: RoughCutStoryBeat) -> String {
        regions(for: group)
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @discardableResult
    func mergeGroups(_ groupIDs: Set<String>) -> String? {
        guard let analysis else { return nil }
        let previousProcess = process
        let previousSuggestions = joinSuggestions
        do {
            let selectedRegionIDs = process.groups
                .filter { groupIDs.contains($0.id) }
                .flatMap(\.regionIDs)
            let updated = try process.merging(groupIDs: groupIDs)
            var updatedSuggestions = joinSuggestions
            for index in updatedSuggestions.indices
                where updatedSuggestions[index].regionIDs == selectedRegionIDs {
                updatedSuggestions[index].decision = .approved
            }
            try RoughCutProcessStore(analysisDirectoryURL: analysis.directoryURL).save(updated)
            try RoughCutJoinSuggestionStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(updatedSuggestions)
            process = updated
            joinSuggestions = updatedSuggestions
            let mergedID = updated.groups.first { $0.regionIDs == selectedRegionIDs }?.id
            statusMessage = "Joined \(selectedRegionIDs.count) accepted clips into one parent clip."
            return mergedID
        } catch {
            process = previousProcess
            joinSuggestions = previousSuggestions
            try? RoughCutProcessStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(previousProcess)
            try? RoughCutJoinSuggestionStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(previousSuggestions)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func unmergeGroups(_ groupIDs: Set<String>) {
        guard let analysis else { return }
        let previousProcess = process
        let previousSuggestions = joinSuggestions
        do {
            let unmergedRegionGroups = process.groups
                .filter { groupIDs.contains($0.id) && $0.regionIDs.count > 1 }
                .map(\.regionIDs)
            let updated = process.unmerging(groupIDs: groupIDs)
            var updatedSuggestions = joinSuggestions
            for index in updatedSuggestions.indices
                where updatedSuggestions[index].decision == .approved
                    && unmergedRegionGroups.contains(where: { parentRegionIDs in
                        Set(parentRegionIDs).isSuperset(
                            of: updatedSuggestions[index].regionIDs
                        )
                    }) {
                updatedSuggestions[index].decision = .pending
            }
            try RoughCutProcessStore(analysisDirectoryURL: analysis.directoryURL).save(updated)
            try RoughCutJoinSuggestionStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(updatedSuggestions)
            process = updated
            joinSuggestions = updatedSuggestions
            let resetCount = zip(previousSuggestions, updatedSuggestions).filter {
                $0.0.decision == .approved && $0.1.decision == .pending
            }.count
            statusMessage = resetCount > 0
                ? "Unjoined the parent clip and returned its approved suggestion to Not decided."
                : "Unjoined the parent clip back into its child clips."
        } catch {
            process = previousProcess
            joinSuggestions = previousSuggestions
            try? RoughCutProcessStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(previousProcess)
            try? RoughCutJoinSuggestionStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(previousSuggestions)
            errorMessage = error.localizedDescription
        }
    }

    func suggestJoins() {
        guard canSuggestJoins, let analysis else { return }
        isSuggestingJoins = true
        errorMessage = nil
        statusMessage = "Codex is reading the accepted clip transcripts and looking for interrupted sentences..."
        let regions = acceptedRegions
        let candidates = regions.map {
            RoughCutJoinCandidate(
                regionID: $0.id,
                start: $0.start,
                end: $0.end,
                transcript: $0.text
            )
        }
        let acceptedRegionIDs = regions.map(\.id)
        let runner = codexJoinRunner
        let directoryURL = analysis.directoryURL

        Task {
            do {
                let suggestions = try await Task.detached(priority: .userInitiated) {
                    try runner.run(
                        candidates: candidates,
                        acceptedRegionIDs: acceptedRegionIDs,
                        workingDirectoryURL: directoryURL
                    )
                }.value
                let reconciled = RoughCutJoinSuggestionReconciler.reconcile(
                    refreshed: suggestions,
                    previous: joinSuggestions,
                    acceptedRegionIDs: acceptedRegionIDs
                )
                try RoughCutJoinSuggestionStore(
                    analysisDirectoryURL: directoryURL
                ).save(reconciled)
                joinSuggestions = reconciled
                statusMessage = reconciled.isEmpty
                    ? "Codex did not find any high-confidence interrupted sentences."
                    : "Join review now has \(pendingJoinCount) awaiting, \(approvedJoinCount) approved, and \(rejectedJoinCount) rejected."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Codex join suggestions failed. No clips were changed."
            }
            isSuggestingJoins = false
        }
    }

    func setJoinDecision(
        _ decision: RoughCutJoinDecision,
        for suggestion: RoughCutJoinSuggestion
    ) {
        guard let analysis,
              let proposalIndex = joinSuggestions.firstIndex(where: {
                  $0.id == suggestion.id
              }) else { return }
        let previousProcess = process
        let previousSuggestions = joinSuggestions
        do {
            let result = try RoughCutJoinDecisionWorkflow.apply(
                decision,
                to: joinSuggestions[proposalIndex],
                process: process
            )
            var updatedSuggestions = joinSuggestions
            updatedSuggestions[proposalIndex] = result.proposal
            try RoughCutProcessStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(result.process)
            try RoughCutJoinSuggestionStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(updatedSuggestions)
            process = result.process
            joinSuggestions = updatedSuggestions
            switch decision {
            case .pending:
                statusMessage = "Undid the merge and returned this suggestion to Not decided."
            case .approved:
                statusMessage = "Approved the join and created a parent clip with \(suggestion.regionIDs.count) children."
            case .rejected:
                statusMessage = "Rejected the join. The clips remain separate and the decision stays reviewable."
            }
        } catch {
            process = previousProcess
            joinSuggestions = previousSuggestions
            try? RoughCutProcessStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(previousProcess)
            try? RoughCutJoinSuggestionStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(previousSuggestions)
            errorMessage = error.localizedDescription
        }
    }

    func previewJoinSuggestion(_ suggestion: RoughCutJoinSuggestion) {
        let group = RoughCutStoryBeat(
            id: "suggestion-\(suggestion.id)",
            regionIDs: suggestion.regionIDs,
            visual: .unassigned
        )
        buildJoinReviewPreview(
            plan: playbackPlan(for: group),
            status: "Previewing the proposed merge with word-edge trims and a 40 ms audio crossfade."
        )
    }

    func previewJoinRegion(_ regionID: String) {
        guard let region = effectiveRegions.first(where: { $0.id == regionID }) else { return }
        let plan = RoughCutPlaybackPlan(clips: [
            RoughCutPlaybackClip(
                regionID: region.id,
                sourceStart: region.start,
                sourceEnd: region.end,
                crossfadeAfter: 0
            ),
        ])
        buildJoinReviewPreview(
            plan: plan,
            status: "Previewing \(region.id) on its own."
        )
    }

    func stopJoinReviewPlayback() {
        joinReviewBuildGeneration &+= 1
        joinReviewPlayer?.pause()
        isBuildingJoinPreview = false
    }

    private func discardJoinReviewPlayback() {
        stopJoinReviewPlayback()
        joinReviewPlayer = nil
    }

    func assignVisual(
        layout: RoughCutVisualLayout,
        detail: String,
        to groupIDs: Set<String>
    ) {
        guard let analysis, !groupIDs.isEmpty else { return }
        do {
            let visual = RoughCutVisualEditor.plan(
                selecting: layout,
                detail: detail
            )
            let updated = process.assigningVisual(visual, toGroupIDs: groupIDs)
            try RoughCutProcessStore(analysisDirectoryURL: analysis.directoryURL).save(updated)
            process = updated
            statusMessage = "Applied \(layout.label.lowercased()) to \(groupIDs.count) story beat\(groupIDs.count == 1 ? "" : "s")."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func suggestRemainingVisuals() {
        guard canSuggestVisuals, let analysis else { return }
        let targetGroupIDs = Set(
            process.groups.compactMap {
                $0.visual.layout == .unassigned || $0.visual.isAISuggested
                    ? $0.id
                    : nil
            }
        )
        let clips = process.groups.enumerated().map { index, group in
            RoughCutVisualSuggestionClip(
                groupID: group.id,
                clipNumber: index + 1,
                transcript: transcript(for: group),
                // Previous AI output is deliberately presented as unplanned so
                // a regeneration uses the new prompt instead of preserving it.
                currentVisual: targetGroupIDs.contains(group.id)
                    ? .unassigned
                    : group.visual
            )
        }
        let runner = codexVisualRunner
        let directoryURL = analysis.directoryURL

        isSuggestingVisuals = true
        errorMessage = nil
        statusMessage = unplannedVisualCount > 0
            ? "Codex is learning from your visual choices and planning \(targetGroupIDs.count) clips..."
            : "Codex is regenerating \(targetGroupIDs.count) AI suggestions with the latest production rules..."

        Task {
            do {
                let suggestions = try await Task.detached(priority: .userInitiated) {
                    try runner.run(
                        clips: clips,
                        targetGroupIDs: targetGroupIDs,
                        workingDirectoryURL: directoryURL
                    )
                }.value
                let updated = process.assigningSuggestedVisuals(suggestions)
                let appliedCount = targetGroupIDs.filter {
                    suggestions[$0] != nil
                }.count
                try RoughCutProcessStore(
                    analysisDirectoryURL: directoryURL
                ).save(updated)
                process = updated
                if let focusedGroupID,
                   let focused = updated.groups.first(where: {
                       $0.id == focusedGroupID
                   }) {
                    editorVisualLayout = focused.visual.layout
                    editorVisualDetail = focused.visual.detail
                    isEditorVisualDirty = false
                }
                statusMessage = appliedCount == 0
                    ? "Codex did not return any valid visual suggestions. Existing choices were unchanged."
                    : "Added \(appliedCount) AI visual suggestion\(appliedCount == 1 ? "" : "s"). Edit and apply any suggestion to make it yours."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Codex visual planning failed. Existing choices were unchanged."
            }
            isSuggestingVisuals = false
        }
    }

    func exportFilmoraProject() {
        guard !isWorking, let analysis, let sourceVideoURL = selectedVideoURL else { return }
        let type = UTType(filenameExtension: "wfp") ?? .data
        let savePanel = NSSavePanel()
        savePanel.title = "Create Filmora Project"
        savePanel.message = "Choose the name and location for the new Filmora rough-cut project. Video HQ will find the matching source project automatically."
        savePanel.prompt = "Create Project"
        savePanel.allowedContentTypes = [type]
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = project.directoryURL
        savePanel.nameFieldStringValue = "\(project.name)-rough-cut.wfp"
        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            errorMessage = RoughCutEditingError.outputExists(outputURL).localizedDescription
            return
        }

        isExporting = true
        errorMessage = nil
        statusMessage = "Finding the matching Filmora source and creating a new project..."
        let decisions = manualDecisions
        let exportPlaybackPlan = reviewedPlaybackPlan
        let exporter = exportRunner
        let projectDirectoryURL = project.directoryURL
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let seed = try exporter.discoverMatchingSeed(
                        projectDirectoryURL: projectDirectoryURL,
                        sourceVideoURL: sourceVideoURL,
                        plannedDurationSeconds: analysis.plan.source.durationSeconds
                    )
                    let reviewedPlanURL = Self.newReviewedPlanURL(for: analysis)
                    try RoughCutReviewedPlanWriter().write(
                        sourcePlanURL: analysis.planURL,
                        outputURL: reviewedPlanURL,
                        overrides: decisions,
                        filmoraSourceDurationSeconds: seed.sourceDurationSeconds,
                        playbackPlan: exportPlaybackPlan
                    )
                    return try exporter.run(
                        seedURL: seed.projectURL,
                        planURL: reviewedPlanURL,
                        outputURL: outputURL
                    )
                }.value
                lastExportURL = result.outputURL
                statusMessage = "Exported \(result.outputPairCount) linked sections to \(result.outputURL.lastPathComponent). Open it in Filmora, save it, reopen it, and listen through the cut."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Filmora project creation failed. Existing projects and analysis files were not changed."
            }
            isExporting = false
        }
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
    }

    func revealSourceDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: sourceLibrary.sourceDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(sourceLibrary.sourceDirectoryURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        cancelPendingPlaybackBuild()
        stopAssembledPlayback()
        stopJoinReviewPlayback()
        player?.pause()
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaybackPlaying || autoplayBuildPending || isBuildingPlaybackPreview {
            if autoplayBuildPending || isBuildingPlaybackPreview {
                cancelPendingPlaybackBuild()
            }
            player.pause()
            statusMessage = "Playback paused."
            return
        }

        let currentTime = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        if currentTime.isFinite, duration.isFinite,
           duration > 0, currentTime >= duration - 0.05 {
            player.seek(to: .zero) { [weak self, weak player] finished in
                Task { @MainActor in
                    guard finished, let self, let player, self.player === player else {
                        return
                    }
                    player.play()
                    self.statusMessage = "Playback resumed."
                }
            }
        } else {
            player.play()
            statusMessage = "Playback resumed."
        }
    }

    private func clearSelection() {
        cancelPendingPlaybackBuild()
        player?.pause()
        selectedVideoURL = nil
        player = nil
        analysis = nil
        manualDecisions = [:]
        process = .initial(acceptedRegionIDs: [])
        selectedGroupIDs.removeAll()
        focusedGroupID = nil
        expandedGroupIDs.removeAll()
        editorVisualLayout = .unassigned
        editorVisualDetail = ""
        isEditorVisualDirty = false
        joinSuggestions = []
        joinReviewPlayer = nil
        transcriptWords = []
        activePlaybackPlan = nil
        regionFilterSelection = .all
        lastExportURL = nil
        statusMessage = "No videos are in the project source directory yet."
    }

    private func loadAndReconcileProcess(for analysis: RoughCutAnalysis) throws {
        let store = RoughCutProcessStore(analysisDirectoryURL: analysis.directoryURL)
        let loaded = try store.loadOrCreate(acceptedRegionIDs: acceptedRegions.map(\.id))
        try store.save(loaded)
        process = loaded
        transcriptWords = try RoughCutTranscript.decode(
            from: Data(contentsOf: analysis.transcriptURL)
        ).words
        joinSuggestions = RoughCutJoinSuggestionValidator.validated(
            try RoughCutJoinSuggestionStore(
                analysisDirectoryURL: analysis.directoryURL
            ).load(),
            acceptedRegionIDs: acceptedRegions.map(\.id)
        )
        regionFilterSelection = (try? RoughCutViewStateStore(
            analysisDirectoryURL: analysis.directoryURL
        ).load()) ?? .all
    }

    private func reconcileAndSaveProcess(for analysis: RoughCutAnalysis) throws {
        let updated = process.reconciled(acceptedRegionIDs: acceptedRegions.map(\.id))
        try RoughCutProcessStore(analysisDirectoryURL: analysis.directoryURL).save(updated)
        process = updated
        joinSuggestions = RoughCutJoinSuggestionValidator.validated(
            joinSuggestions,
            acceptedRegionIDs: acceptedRegions.map(\.id)
        )
        saveJoinSuggestions()
    }

    private func playbackPlan(for group: RoughCutStoryBeat) -> RoughCutPlaybackPlan {
        let groupRegions = regions(for: group)
        let pairs = Set(zip(group.regionIDs, group.regionIDs.dropFirst()).map {
            RoughCutRegionPair(left: $0, right: $1)
        })
        return RoughCutSpeechJoinPlanner.plan(
            regions: groupRegions,
            words: transcriptWords,
            joinedPairs: pairs
        )
    }

    private func saveJoinSuggestions() {
        guard let analysis else { return }
        do {
            try RoughCutJoinSuggestionStore(
                analysisDirectoryURL: analysis.directoryURL
            ).save(joinSuggestions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildJoinReviewPreview(
        plan: RoughCutPlaybackPlan,
        status: String
    ) {
        guard let sourceURL = selectedVideoURL else { return }
        joinReviewBuildGeneration &+= 1
        let generation = joinReviewBuildGeneration
        isBuildingJoinPreview = true
        statusMessage = "Building preview..."
        Task {
            do {
                let result = try await RoughCutPlaybackCompositionBuilder.build(
                    sourceURL: sourceURL,
                    plan: plan
                )
                guard generation == joinReviewBuildGeneration,
                      selectedVideoURL?.standardizedFileURL
                        == sourceURL.standardizedFileURL else { return }
                let item = AVPlayerItem(asset: result.composition)
                item.audioMix = result.audioMix
                joinReviewPlayer = AVPlayer(playerItem: item)
                joinReviewPlayer?.play()
                statusMessage = status
            } catch {
                if generation == joinReviewBuildGeneration {
                    errorMessage = error.localizedDescription
                    statusMessage = "Could not build the join-review preview."
                }
            }
            if generation == joinReviewBuildGeneration {
                isBuildingJoinPreview = false
            }
        }
    }

    private func stopAssembledPlayback() {
        player?.pause()
    }

    private func seekExistingComposition(
        to playbackTime: Double,
        autoplay: Bool
    ) {
        guard let player else { return }
        let generation = beginPlaybackBuild(autoplay: autoplay)
        player.pause()
        player.seek(
            to: CMTime(seconds: playbackTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] finished in
            Task { @MainActor [weak self] in
                guard let self, let player,
                      self.player === player,
                      generation == playbackBuildGeneration else { return }
                autoplayBuildPending = false
                guard finished else {
                    statusMessage = "Could not seek to the selected clip."
                    return
                }
                publishPlaybackPosition(playbackTime)
                if autoplay {
                    player.play()
                    statusMessage = "Playing from the selected clip."
                } else {
                    statusMessage = "Ready at the selected clip."
                }
            }
        }
    }

    private func beginPlaybackBuild(autoplay: Bool) -> UInt {
        playbackBuildGeneration &+= 1
        // The new generation owns playback state. Any older composition build
        // will now bail out, so it can no longer be responsible for clearing
        // this flag.
        isBuildingPlaybackPreview = false
        autoplayBuildPending = autoplay
        playerAwaitingAutoplay = nil
        playerAwaitingAutoplayGeneration = nil
        playerAwaitingAutoplayTime = 0
        return playbackBuildGeneration
    }

    private func publishPlaybackPosition(_ playbackTime: Double) {
        playbackPositionRevision &+= 1
        playbackPositionUpdate = RoughCutPlaybackPositionUpdate(
            revision: playbackPositionRevision,
            playbackTime: playbackTime.isFinite ? max(0, playbackTime) : 0
        )
    }

    private func cancelPendingPlaybackBuild() {
        let wasBuilding = isBuildingPlaybackPreview
        playbackBuildGeneration &+= 1
        autoplayBuildPending = false
        playerAwaitingAutoplay = nil
        playerAwaitingAutoplayGeneration = nil
        playerAwaitingAutoplayTime = 0
        isBuildingPlaybackPreview = false
        if wasBuilding {
            statusMessage = "Playback build cancelled."
        }
    }

    private func restoreSourcePlayerIfNeeded() {
        guard isPlayingComposition, let selectedVideoURL else { return }
        player = AVPlayer(url: selectedVideoURL)
        isPlayingComposition = false
        activePlaybackPlan = nil
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    nonisolated private static func newReviewedPlanURL(for analysis: RoughCutAnalysis) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let version = "\(formatter.string(from: Date()))-\(UUID().uuidString)"
        return analysis.directoryURL
            .appendingPathComponent("reviewed-plans", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("rough-cut-plan.json")
    }
}

@MainActor
final class RoughCutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: RoughCutReviewModel?
    private var keyDownMonitor: Any?

    func show(project: VideoProject, configuration: VideoHQConfiguration) {
        model?.stopPlayback()
        let model = RoughCutReviewModel(
            project: project,
            configuration: configuration
        )
        let window = window ?? makeWindow()
        window.title = "Rough Cut Process - \(project.name)"
        window.contentView = NSHostingView(rootView: RoughCutReviewView(model: model))
        self.model = model
        self.window = window
        startMonitoringKeyboard()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        model?.stopPlayback()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 1040, height: 700)
        window.center()
        window.delegate = self
        return window
    }

    private func startMonitoringKeyboard() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, event.window === window, !event.isARepeat else {
                return event
            }
            let isEditingText = window?.firstResponder.map(Self.isEditingText) ?? false
            guard RoughCutPlaybackShortcut.shouldHandle(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isEditingText: isEditingText
            ) else {
                return event
            }
            model?.togglePlayback()
            return nil
        }
    }

    private static func isEditingText(_ responder: NSResponder) -> Bool {
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        if let textField = responder as? NSTextField {
            return textField.isEditable
        }
        return false
    }

    deinit {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
    }
}

private struct RoughCutReviewView: View {
    @ObservedObject var model: RoughCutReviewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Rough Cut Process", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Something went wrong.")
        }
    }

    private var header: some View {
        VStack(spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Rough Cut Process", systemImage: "scissors")
                        .font(.title2.weight(.semibold))
                    Text(model.project.name)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Source Folder", systemImage: "folder") {
                    model.revealSourceDirectory()
                }
                Button("Import Recording", systemImage: "square.and.arrow.down") {
                    model.chooseAndImportVideo()
                }
                .disabled(model.isWorking)
            }

            HStack(spacing: 12) {
                Picker("Source recording", selection: sourceSelection) {
                    Text("Choose a source recording").tag(URL?.none)
                    ForEach(model.sourceVideos, id: \.self) { url in
                        Text(url.lastPathComponent).tag(URL?.some(url))
                    }
                }
                .frame(maxWidth: 520)
                .disabled(model.isWorking || model.sourceVideos.isEmpty)

                Button(model.analyzeButtonTitle, systemImage: "waveform.badge.magnifyingglass") {
                    model.analyze()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canAnalyze)

                if model.analysis != nil {
                    Button("Play reviewed cut", systemImage: "play.fill") {
                        if model.stage == .visuals {
                            model.playFilteredCut(
                                visibleRegionIDs: model.process.groups.flatMap(\.regionIDs)
                            )
                        } else {
                            model.playReviewedCut()
                        }
                    }
                    .disabled(model.isWorking)
                    Button("Show source", systemImage: "film") {
                        model.showSourceRecording()
                    }
                    Button("Reveal Analysis", systemImage: "doc.text.magnifyingglass") {
                        model.revealAnalysis()
                    }
                    Button("Export Filmora Project", systemImage: "square.and.arrow.up") {
                        model.exportFilmoraProject()
                    }
                    .disabled(model.isWorking)
                }
                if model.lastExportURL != nil {
                    Button("Reveal Export", systemImage: "folder.badge.checkmark") {
                        model.revealLastExport()
                    }
                }
                Spacer()
            }

            if model.analysis != nil {
                HStack(spacing: 14) {
                    Picker("Rough cut step", selection: $model.stage) {
                        ForEach(RoughCutProcessStage.allCases) { stage in
                            Text(stage.label).tag(stage)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 440)

                    switch model.stage {
                    case .review:
                        Text("\(model.unresolvedReviewCount) review calls outstanding")
                    case .visuals:
                        Text(
                            "\(model.plannedVisualCount) of \(model.process.groups.count) visuals planned"
                        )
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    @ViewBuilder
    private var content: some View {
        if let player = model.player {
            RoughCutPlayerWorkspace(model: model, player: player)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text("Add a source recording")
                    .font(.title2.weight(.semibold))
                Text("Choose a video already in this project's source directory, or import one and Video HQ will copy it there.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Button("Import Recording", systemImage: "square.and.arrow.down") {
                    model.chooseAndImportVideo()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.analysis == nil ? "info.circle" : "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
    }

    private var sourceSelection: Binding<URL?> {
        Binding(
            get: { model.selectedVideoURL },
            set: { if let url = $0 { model.selectVideo(url) } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

@MainActor
final class RoughCutPlaybackClock: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVPlayer
    private var timeObserver: Any?
    private var timeJumpObserver: NSObjectProtocol?

    var observedPlayer: AVPlayer { player }

    init(player: AVPlayer) {
        self.player = player
        observe(player)
    }

    func attach(to newPlayer: AVPlayer) {
        guard player !== newPlayer else { return }
        stopObserving()
        player = newPlayer
        currentTime = 0
        duration = 0
        observe(newPlayer)
    }

    func synchronize(to playbackTime: Double) {
        currentTime = playbackTime.isFinite ? max(0, playbackTime) : 0
    }

    private func observe(_ player: AVPlayer) {
        updateCurrentTime(from: player)
        if let asset = player.currentItem?.asset {
            Task { [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                guard let loadedDuration = try? await asset.load(.duration),
                      loadedDuration.seconds.isFinite,
                      loadedDuration.seconds > 0 else { return }
                guard self.player === player else { return }
                duration = loadedDuration.seconds
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            let seconds = time.seconds.isFinite ? max(0, time.seconds) : 0
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                currentTime = seconds
                let itemDuration = player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 {
                    duration = itemDuration
                }
            }
        }
        timeJumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                updateCurrentTime(from: player)
            }
        }
    }

    private func updateCurrentTime(from player: AVPlayer) {
        let seconds = player.currentTime().seconds
        currentTime = seconds.isFinite ? max(0, seconds) : 0
    }

    private func stopObserving() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let timeJumpObserver {
            NotificationCenter.default.removeObserver(timeJumpObserver)
            self.timeJumpObserver = nil
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let timeJumpObserver {
            NotificationCenter.default.removeObserver(timeJumpObserver)
        }
    }
}

private struct RoughCutPlayerWorkspace: View {
    @ObservedObject var model: RoughCutReviewModel
    @StateObject private var clock: RoughCutPlaybackClock
    @State private var isJoinReviewPresented = false
    @State private var scrubbedSourceTime: Double?
    @State private var scrubbedEditedTime: Double?
    let player: AVPlayer

    init(model: RoughCutReviewModel, player: AVPlayer) {
        self.model = model
        self.player = player
        _clock = StateObject(wrappedValue: RoughCutPlaybackClock(player: player))
    }

    var body: some View {
        VStack(spacing: 14) {
            MacVideoPlayer(player: player)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 245, idealHeight: 330)
                .onAppear {
                    model.playerViewDidAppear(player)
                }

            timelinePanel

            if model.analysis != nil {
                stagePanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("The source is ready")
                        .font(.headline)
                    Text("Run analysis to replace the plain timeline with valid sections, false starts, bad takes, and review items.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .onAppear {
            syncVisualEditorToFocusedGroup()
        }
        .onReceive(model.$player) { updatedPlayer in
            guard let updatedPlayer else { return }
            clock.attach(to: updatedPlayer)
            model.playerViewDidAppear(updatedPlayer)
        }
        .onChange(of: model.playbackPositionUpdate) { update in
            clock.synchronize(to: update.playbackTime)
        }
        .onChange(of: model.process.groups.map(\.id)) { validIDs in
            model.selectedGroupIDs.formIntersection(validIDs)
            model.expandedGroupIDs.formIntersection(validIDs)
            if let focusedGroupID = model.focusedGroupID,
               !validIDs.contains(focusedGroupID) {
                model.focusedGroupID = nil
                model.editorVisualLayout = .unassigned
                model.editorVisualDetail = ""
                model.isEditorVisualDirty = false
            }
        }
        .onChange(of: model.stage) { stage in
            if stage == .review {
                _ = persistEditorDraftIfNeeded()
            } else {
                let sourceTime = displayedSourceTime
                let shouldContinue = model.shouldContinuePlaybackOnSelection
                syncVisualEditorToFocusedGroup()
                model.playFilteredCut(
                    visibleRegionIDs: model.process.groups.flatMap(\.regionIDs),
                    startingAtSourceTime: sourceTime,
                    autoplay: shouldContinue
                )
            }
        }
        .sheet(isPresented: $isJoinReviewPresented) {
            RoughCutJoinReviewSheet(model: model)
        }
    }

    @ViewBuilder
    private var stagePanel: some View {
        switch model.stage {
        case .review:
            regionReview
        case .visuals:
            visualPlanning
        }
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(timelineTitle)
                    .font(.headline)
                Text(timelineTimeLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.analysis != nil, model.stage == .review { legend }
            }

            if model.analysis != nil {
                if model.stage == .visuals {
                    HStack(spacing: 8) {
                        Text("Visuals")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        RoughCutAssemblyTimelineView(
                            groups: assemblyTimelineGroups,
                            clipBoundaries: editedClipBoundaries,
                            duration: editedTimelineDuration,
                            currentTime: editedTimelineCurrentTime,
                            selectedGroupIDs: model.selectedGroupIDs,
                            onSelect: selectAndPlay
                        )
                        .frame(height: 30)
                    }

                    HStack(spacing: 8) {
                        Text("Dialogue")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        RoughCutEditedTimelineView(
                            clips: editedTimelineClips,
                            clipBoundaries: editedClipBoundaries,
                            duration: editedTimelineDuration,
                            currentTime: editedTimelineCurrentTime,
                            onScrub: scrubEditedTimeline,
                            onScrubEnd: finishEditedTimelineScrub
                        )
                        .frame(height: 38)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("Dialogue")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        RoughCutTimelineView(
                            regions: model.effectiveRegions,
                            joinSuggestions: model.joinSuggestions,
                            visibleRegionIDs: timelineVisibleRegionIDs,
                            duration: timelineDuration,
                            currentTime: displayedSourceTime,
                            onScrub: scrub,
                            onScrubEnd: finishScrub
                        )
                        .frame(height: 38)
                    }
                }
            } else {
                RoughCutTimelineView(
                    regions: model.effectiveRegions,
                    joinSuggestions: model.joinSuggestions,
                    visibleRegionIDs: nil,
                    duration: timelineDuration,
                    currentTime: displayedSourceTime,
                    onScrub: scrub,
                    onScrubEnd: finishScrub
                )
                .frame(height: 38)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var timelineTitle: String {
        guard model.analysis != nil else { return "Source timeline" }
        return model.stage == .visuals ? "Edited timeline" : "Rough cut timeline"
    }

    private var timelineTimeLabel: String {
        if model.analysis != nil, model.stage == .visuals {
            return "\(formatTime(editedTimelineCurrentTime)) / \(formatTime(editedTimelineDuration))"
        }
        return "\(formatTime(displayedSourceTime)) / \(formatTime(timelineDuration))"
    }

    private var displayedSourceTime: Double {
        if model.stage == .visuals, let scrubbedEditedTime {
            // While dragging the edited timeline, derive the active source clip
            // directly from the cursor. The AVPlayer seek can trail the pointer.
            return visualPlaybackPlan.sourceTime(at: scrubbedEditedTime)
        }
        return RoughCutDisplayedPlaybackPosition.sourceTime(
            scrubbedSourceTime: scrubbedSourceTime,
            clockSourceTime: model.sourceTime(for: clock.currentTime)
        )
    }

    private func scrub(to sourceTime: Double) {
        scrubbedSourceTime = sourceTime
        model.seek(to: sourceTime)
    }

    private func finishScrub(at sourceTime: Double) {
        scrubbedSourceTime = sourceTime
        model.seek(to: sourceTime) { _ in
            guard scrubbedSourceTime == sourceTime else { return }
            scrubbedSourceTime = nil
        }
    }

    private var editedTimelineCurrentTime: Double {
        if let scrubbedEditedTime {
            return scrubbedEditedTime
        }
        let sourceTime = displayedSourceTime
        return visualPlaybackPlan.playbackTime(forSourceTime: sourceTime)
            ?? visualPlaybackPlan.nearestPlaybackTime(forSourceTime: sourceTime)
    }

    private func scrubEditedTimeline(to playbackTime: Double) {
        scrubbedEditedTime = playbackTime
        let sourceTime = visualPlaybackPlan.sourceTime(at: playbackTime)
        selectVisualGroupFollowingPlayhead(at: sourceTime)
        model.seek(to: sourceTime)
    }

    private func finishEditedTimelineScrub(at playbackTime: Double) {
        scrubbedEditedTime = playbackTime
        let sourceTime = visualPlaybackPlan.sourceTime(at: playbackTime)
        selectVisualGroupFollowingPlayhead(at: sourceTime)
        model.seek(
            to: sourceTime
        ) { _ in
            guard scrubbedEditedTime == playbackTime else { return }
            scrubbedEditedTime = nil
        }
    }

    private func selectVisualGroupFollowingPlayhead(at sourceTime: Double) {
        guard let groupID = RoughCutTimelineInteraction.groupID(
            at: sourceTime,
            regions: model.effectiveRegions,
            groups: model.process.groups
        ), model.focusedGroupID != groupID || model.selectedGroupIDs != [groupID],
           persistEditorDraftIfNeeded(),
           let group = model.process.groups.first(where: { $0.id == groupID }) else {
            return
        }
        model.selectedGroupIDs = [groupID]
        model.focusedGroupID = groupID
        model.editorVisualLayout = group.visual.layout
        model.editorVisualDetail = group.visual.detail
        model.isEditorVisualDirty = false
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(RoughCutRegionKind.allCases, id: \.self) { kind in
                HStack(spacing: 4) {
                    Circle().fill(kind.color).frame(width: 8, height: 8)
                    Text(kind.rawValue).font(.caption2)
                }
            }
            if !model.joinSuggestions.isEmpty {
                HStack(spacing: 4) {
                    Rectangle().fill(Color.pink).frame(width: 3, height: 10)
                    Text("Likely join").font(.caption2)
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var stageNotice: some View {
        if model.unresolvedReviewCount > 0 {
            Label(
                "\(model.unresolvedReviewCount) review items are unresolved and remain outside reviewed playback.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func selectAndPlay(_ groupID: String) {
        guard let group = model.process.groups.first(where: { $0.id == groupID }) else { return }
        let shouldContinue = model.shouldContinuePlaybackOnSelection
        selectGroupFromRowClick(group)
        guard let startRegionID = firstVisibleRegionID(in: group) else { return }
        playVisibleCut(
            startingAt: startRegionID,
            behavior: .rowSelection(wasPlaying: shouldContinue)
        )
    }

    private func chooseVisualMedia() {
        let panel = NSOpenPanel()
        panel.title = "Choose Visual Media"
        panel.message = "Choose the B-roll or screen recording for the selected story beats."
        panel.prompt = "Use Media"
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.editorVisualDetail = url.path
        model.isEditorVisualDirty = true
        saveCurrentVisual()
    }

    private var visualLayoutSelection: Binding<RoughCutVisualLayout> {
        Binding(
            get: { model.editorVisualLayout },
            set: { newLayout in
                model.editorVisualLayout = newLayout
                model.isEditorVisualDirty = true
                saveCurrentVisual(layout: newLayout)
            }
        )
    }

    private var visualDetailSelection: Binding<String> {
        Binding(
            get: { model.editorVisualDetail },
            set: { newDetail in
                model.editorVisualDetail = newDetail
                model.isEditorVisualDirty = true
            }
        )
    }

    private func saveCurrentVisual(
        layout: RoughCutVisualLayout? = nil
    ) {
        let plan = RoughCutVisualEditor.plan(
            selecting: layout ?? model.editorVisualLayout,
            detail: model.editorVisualDetail
        )
        model.assignVisual(
            layout: plan.layout,
            detail: plan.detail,
            to: model.selectedGroupIDs
        )
        let saved = model.process.groups
            .filter { model.selectedGroupIDs.contains($0.id) }
            .allSatisfy { $0.visual == plan }
        if saved {
            model.isEditorVisualDirty = false
        }
    }

    private var visualDetailPlaceholder: String {
        switch model.editorVisualLayout {
        case .aiBRollFullScreen:
            return "Describe the AI B-roll to generate"
        case .bRollFullScreen:
            return "Choose or describe the B-roll"
        case .screenRecordingFullScreen, .screencastWithCamera:
            return "Choose or describe the screen recording"
        default:
            return "No additional media needed"
        }
    }

    private var assemblyTimelineGroups: [RoughCutAssemblyTimelineGroup] {
        model.process.groups.compactMap { group in
            guard let range = visualPlaybackPlan.playbackRange(
                forRegionIDs: group.regionIDs
            ) else { return nil }
            return RoughCutAssemblyTimelineGroup(
                id: group.id,
                start: range.start,
                end: range.end,
                duration: range.end - range.start,
                visualLayout: group.visual.layout,
                isAISuggested: group.visual.isAISuggested,
                isIncludedByFilter: true
            )
        }
    }

    private var visualPlaybackPlan: RoughCutPlaybackPlan {
        model.reviewedPlaybackPlan
    }

    private var editedTimelineDuration: Double {
        max(visualPlaybackPlan.duration, 0.001)
    }

    private var editedTimelineClips: [RoughCutEditedTimelineClip] {
        let regionsByID = Dictionary(
            uniqueKeysWithValues: model.effectiveRegions.map { ($0.id, $0) }
        )
        return visualPlaybackPlan.timelineClips.compactMap { clip in
            guard let region = regionsByID[clip.regionID] else { return nil }
            return RoughCutEditedTimelineClip(
                id: clip.regionID,
                start: clip.start,
                end: clip.end,
                kind: region.kind
            )
        }
    }

    private var editedClipBoundaries: [Double] {
        visualPlaybackPlan.playbackBoundaries(
            forRegionGroups: model.process.groups.map(\.regionIDs)
        )
    }

    private var timelineVisibleRegionIDs: Set<String> {
        if model.stage == .visuals {
            return Set(model.process.groups.flatMap(\.regionIDs))
        }
        return Set(displayedRegions.map(\.id))
    }

    private var regionReview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Detected sections")
                    .font(.headline)
                Text(sectionSummary(displayedRegions))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Play shown clips", systemImage: "play.fill") {
                    playVisibleCut()
                }
                .disabled(model.isWorking)
                if !model.joinSuggestions.isEmpty {
                    Button(
                        "Review likely joins (\(model.pendingJoinCount))",
                        systemImage: "arrow.triangle.merge"
                    ) {
                        isJoinReviewPresented = true
                    }
                }
                Text("Scrub the timeline or click a row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                Text("Show")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Button("All sections") {
                        model.setRegionFilterSelection(.all)
                    }
                    Button("Hide all") {
                        model.setRegionFilterSelection(
                            RoughCutRegionFilterSelection(filters: [])
                        )
                    }
                    Divider()
                    ForEach(RoughCutRegionFilterSelection.selectableFilters, id: \.self) {
                        filter in
                        Toggle(
                            filter.label,
                            isOn: Binding(
                                get: { regionFilters.filters.contains(filter) },
                                set: { isVisible in
                                    var updated = regionFilters
                                    if isVisible {
                                        updated.filters.insert(filter)
                                    } else {
                                        updated.filters.remove(filter)
                                    }
                                    model.setRegionFilterSelection(updated)
                                }
                            )
                        )
                    }
                } label: {
                    Text(regionFilters.label)
                        .frame(minWidth: 125, alignment: .leading)
                }
                .frame(width: 160, alignment: .leading)

                Text("\(displayedRegions.count) of \(model.effectiveRegions.count) sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Join selected", systemImage: "arrow.triangle.merge") {
                    joinSelectedGroups()
                }
                .disabled(model.selectedGroupIDs.count < 2)
                Button("Unjoin selected", systemImage: "arrow.uturn.backward") {
                    unjoinSelectedGroups()
                }
                .disabled(selectedMergedGroupIDs.isEmpty)
                Text(
                    model.selectedGroupIDs.isEmpty
                        ? "Select adjacent accepted clips to join them"
                        : "\(model.selectedGroupIDs.count) clip boundar\(model.selectedGroupIDs.count == 1 ? "y" : "ies") selected"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            stageNotice
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if displayedRegions.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: isOnlyAwaitingDecisionFilter
                                ? "checkmark.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(isOnlyAwaitingDecisionFilter
                                    ? Color.green
                                    : Color.secondary)
                            Text(emptyFilterTitle)
                                .font(.headline)
                            Text("Choose another filter to see the other detected sections.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        LazyVStack(spacing: 1) {
                            ForEach(reviewHierarchyItems) { item in
                                if item.isJoinedParent,
                                   let groupID = item.groupID,
                                   let group = model.process.groups.first(where: {
                                       $0.id == groupID
                                   }) {
                                    joinedGroupRow(group)
                                        .id(item.id)
                                } else if let regionID = item.regionIDs.first,
                                          let region = model.effectiveRegions.first(where: {
                                              $0.id == regionID
                                          }) {
                                    regionRow(
                                        region,
                                        isActive: region.id == activeRegionID,
                                        selectableGroup: item.groupID.flatMap { groupID in
                                            model.process.groups.first { $0.id == groupID }
                                        },
                                        clickSelectionGroup: item.groupID.flatMap { groupID in
                                            model.process.groups.first { $0.id == groupID }
                                        }
                                    )
                                    .id(item.id)
                                }
                            }
                        }
                    }
                }
                .onChange(of: activeRegionID) { regionID in
                    guard model.shouldFollowPlaybackPosition
                            || scrubbedSourceTime != nil,
                          let regionID,
                          let item = reviewHierarchyItems.first(where: {
                              $0.regionIDs.contains(regionID)
                          }) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
            Divider()
            Text("Keep and Cut override the analysis. Approved and manual joins define the clip boundaries used in Step 2.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18))
        }
    }

    private var visualPlanning: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Plan what viewers see")
                    .font(.headline)
                Text("\(model.plannedVisualCount) of \(model.process.groups.count) planned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.aiSuggestedVisualCount > 0 {
                    Label(
                        "\(model.aiSuggestedVisualCount) AI suggested",
                        systemImage: "sparkles"
                    )
                    .font(.caption)
                    .foregroundStyle(.purple)
                }
                Spacer()
                if model.isSuggestingVisuals {
                    ProgressView()
                        .controlSize(.small)
                    Text("Codex is planning visuals...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(
                        model.unplannedVisualCount == 0
                            ? "Regenerate \(model.aiSuggestedVisualCount) AI suggestions"
                            : "Suggest \(model.unplannedVisualCount) remaining",
                        systemImage: "wand.and.stars"
                    ) {
                        model.suggestRemainingVisuals()
                    }
                    .disabled(!model.canSuggestVisuals)
                }
                Button("Play reviewed cut", systemImage: "play.fill") {
                    playVisualCut()
                }
                .disabled(model.isWorking)
                Text(
                    model.selectedGroupIDs.isEmpty
                        ? "Select one or more clip boundaries"
                        : "\(model.selectedGroupIDs.count) selected"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)

            stageNotice

            HStack(spacing: 10) {
                Picker("Visual", selection: visualLayoutSelection) {
                    ForEach(RoughCutVisualLayout.allCases) { layout in
                        Label(layout.label, systemImage: layout.systemImage).tag(layout)
                    }
                }
                .frame(width: 245)
                .disabled(model.selectedGroupIDs.isEmpty || model.isWorking)

                TextField(visualDetailPlaceholder, text: visualDetailSelection)
                    .textFieldStyle(.roundedBorder)
                    .disabled(
                        model.selectedGroupIDs.isEmpty
                            || model.isWorking
                            || !model.editorVisualLayout.needsDetail
                    )
                    .onSubmit {
                        saveCurrentVisual()
                    }

                if model.editorVisualLayout.needsDetail
                    && model.editorVisualLayout != .aiBRollFullScreen {
                    Button("Choose Media", systemImage: "folder") {
                        chooseVisualMedia()
                    }
                    .disabled(model.selectedGroupIDs.isEmpty || model.isWorking)
                }

                Button("Apply visual", systemImage: "paintbrush") {
                    saveCurrentVisual()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedGroupIDs.isEmpty || model.isWorking)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(model.process.groups.enumerated()), id: \.element.id) {
                            index, group in
                            visualPlanningRow(group, index: index)
                                .id(group.id)
                        }
                    }
                }
                .onChange(of: activeRegionID) { regionID in
                    guard model.shouldFollowPlaybackPosition
                            || scrubbedEditedTime != nil,
                          let regionID,
                          let group = model.process.groups.first(where: {
                              $0.regionIDs.contains(regionID)
                          }) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(group.id, anchor: .center)
                    }
                }
            }

            Divider()
            Text("Visual choices save against these accepted clip boundaries. Joined clips remain one visual beat until you unjoin them in Step 1.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18))
        }
    }

    private func visualPlanningRow(
        _ group: RoughCutStoryBeat,
        index: Int
    ) -> some View {
        let isSelected = model.selectedGroupIDs.contains(group.id)
        let isActive = group.regionIDs.contains(activeRegionID ?? "")
        return HStack(alignment: .center, spacing: 10) {
            RoughCutListPlayheadIndicator(isVisible: isActive)
            groupSelectionButton(group)

            Button {
                let shouldContinue = model.shouldContinuePlaybackOnSelection
                selectGroupFromRowClick(group)
                playVisualCut(
                    startingAt: group.regionIDs.first,
                    behavior: .rowSelection(wasPlaying: shouldContinue)
                )
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green)
                        .frame(width: 7, height: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text("Clip \(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Text(
                                "\(group.regionIDs.count) section\(group.regionIDs.count == 1 ? "" : "s")"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            if group.regionIDs.count > 1 {
                                Label("Joined", systemImage: "link")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                            if group.visual.isAISuggested {
                                Label("AI suggested", systemImage: "sparkles")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.purple)
                            }
                        }
                        Text(model.transcript(for: group))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Label(
                            group.visual.layout.label,
                            systemImage: group.visual.layout.systemImage
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            group.visual.layout == .unassigned
                                ? Color.orange
                                : group.visual.isAISuggested
                                    ? Color.purple
                                : Color.accentColor
                        )
                        if !group.visual.detail.isEmpty {
                            Text(group.visual.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 300)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            isActive
                ? Color.accentColor.opacity(0.17)
                : isSelected
                    ? Color.accentColor.opacity(0.09)
                    : Color(nsColor: .textBackgroundColor)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var displayedRegions: [RoughCutRegion] {
        guard let plannerRegions = model.analysis?.plan.regions else { return [] }
        let visibleIDs = Set(
            regionFilters.apply(
                to: plannerRegions,
                manualDecisions: model.manualDecisions
            ).map(\.id)
        )
        return model.effectiveRegions.filter { visibleIDs.contains($0.id) }
    }

    private var regionFilters: RoughCutRegionFilterSelection {
        model.regionFilterSelection
    }

    private var reviewHierarchyItems: [RoughCutReviewHierarchyItem] {
        RoughCutReviewHierarchy.items(
            regionIDsInSourceOrder: model.effectiveRegions.map(\.id),
            visibleRegionIDs: displayedRegions.map(\.id),
            process: model.process
        )
    }

    private var emptyFilterTitle: String {
        isOnlyAwaitingDecisionFilter
            ? "No review calls outstanding"
            : "No matching sections"
    }

    private var isOnlyAwaitingDecisionFilter: Bool {
        regionFilters.filters == [.awaitingDecision]
    }

    private func joinedGroupRow(_ group: RoughCutStoryBeat) -> some View {
        let regions = model.regions(for: group)
        let visibleRegionIDs = Set(displayedRegions.map(\.id))
        let visibleRegions = regions.filter { visibleRegionIDs.contains($0.id) }
        let isExpanded = model.expandedGroupIDs.contains(group.id)
        let isActive = regions.contains { $0.id == activeRegionID }
        let showsActiveParent = RoughCutListPlayheadVisibility.showOnParent(
            isActive: isActive,
            isExpanded: isExpanded
        )
        return VStack(spacing: 1) {
            HStack(alignment: .center, spacing: 10) {
                RoughCutListPlayheadIndicator(
                    isVisible: showsActiveParent
                )
                groupSelectionButton(group)

                Button {
                    if model.expandedGroupIDs.remove(group.id) == nil {
                        model.expandedGroupIDs.insert(group.id)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Button {
                    let shouldContinue = model.shouldContinuePlaybackOnSelection
                    selectGroupFromRowClick(group)
                    playVisibleCut(
                        startingAt: visibleRegions.first?.id,
                        behavior: .rowSelection(wasPlaying: shouldContinue)
                    )
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue)
                            .frame(width: 7, height: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Label("Joined clip", systemImage: "link")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                Text("\(regions.count) child clips")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let first = regions.first, let last = regions.last {
                                    Text("\(formatTime(first.start)) - \(formatTime(last.end))")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(model.transcript(for: group))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Label(group.visual.layout.label, systemImage: group.visual.layout.systemImage)
                            .font(.caption)
                            .foregroundStyle(
                                group.visual.layout == .unassigned
                                    ? Color.orange
                                    : Color.accentColor
                            )
                        Image(systemName: "play.fill")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button("Unjoin", systemImage: "arrow.uturn.backward") {
                    model.unmergeGroups([group.id])
                    model.selectedGroupIDs.remove(group.id)
                    if model.focusedGroupID == group.id {
                        model.focusedGroupID = nil
                    }
                    model.expandedGroupIDs.remove(group.id)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                showsActiveParent
                    ? Color.accentColor.opacity(0.17)
                    : Color.blue.opacity(0.07)
            )
            .overlay {
                if showsActiveParent {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(visibleRegions) { region in
                        regionRow(
                            region,
                            isActive: region.id == activeRegionID,
                            selectableGroup: nil,
                            clickSelectionGroup: group
                        )
                        .padding(.leading, 38)
                        .id("child-\(group.id)-\(region.id)")
                    }
                }
            }
        }
    }

    private func regionRow(
        _ region: RoughCutRegion,
        isActive: Bool,
        selectableGroup: RoughCutStoryBeat? = nil,
        clickSelectionGroup: RoughCutStoryBeat? = nil
    ) -> some View {
        let manualDecision = model.manualDecision(for: region.id)
        let joinIndicators = joinIndicatorsByRegionID[region.id] ?? []
        let primaryJoin = joinIndicators.first
        let inlineJoinSuggestion = primaryJoin?.showsInlineAction == true
            ? model.joinSuggestions.first { $0.id == primaryJoin?.suggestionID }
            : nil
        return HStack(alignment: .center, spacing: 10) {
            RoughCutListPlayheadIndicator(
                isVisible: RoughCutListPlayheadVisibility.showOnChild(
                    isActive: isActive
                )
            )
            if let selectableGroup {
                groupSelectionButton(selectableGroup)
            }

            Button {
                let shouldContinue = model.shouldContinuePlaybackOnSelection
                if let clickSelectionGroup {
                    selectGroupFromRowClick(clickSelectionGroup)
                }
                playVisibleCut(
                    startingAt: region.id,
                    behavior: .rowSelection(wasPlaying: shouldContinue)
                )
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    if let primaryJoin {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(joinIndicatorColor(primaryJoin.decision))
                            .frame(width: 3, height: 38)
                            .help(primaryJoin.reason)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(region.kind.color)
                        .frame(width: 7, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(region.kind.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(region.kind.color)
                        Text("\(formatTime(region.start)) - \(formatTime(region.end))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let primaryJoin {
                            Label(
                                joinIndicatorLabel(primaryJoin),
                                systemImage: "arrow.triangle.merge"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(joinIndicatorColor(primaryJoin.decision))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                joinIndicatorColor(primaryJoin.decision).opacity(0.12),
                                in: Capsule()
                            )
                            .help(primaryJoin.reason)
                        }
                        if joinIndicators.count > 1 {
                            Text("+\(joinIndicators.count - 1) join")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if manualDecision != .automatic {
                            Label("Manual \(manualDecision.label.lowercased())", systemImage: "hand.draw.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(region.kind.color)
                        }
                    }
                    Text(region.text.isEmpty ? friendlyReason(region.reason) : region.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(region.text.isEmpty ? Color.secondary : Color.primary)
                    if !region.text.isEmpty, region.decision != "keep" {
                        Text(friendlyReason(region.reason))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let inlineJoinSuggestion {
                Button {
                    model.setJoinDecision(
                        inlineJoinSuggestion.decision == .approved ? .pending : .approved,
                        for: inlineJoinSuggestion
                    )
                } label: {
                    Label(
                        inlineJoinSuggestion.decision == .approved
                            ? "Undo join"
                            : "Approve join",
                        systemImage: inlineJoinSuggestion.decision == .approved
                            ? "arrow.uturn.backward"
                            : "checkmark"
                    )
                }
                .buttonStyle(.bordered)
                .tint(inlineJoinSuggestion.decision == .approved ? .orange : .green)
                .help(
                    inlineJoinSuggestion.decision == .approved
                        ? "Split these clips and return the proposal to Not decided."
                        : "Merge these clips using the speech-tight preview settings."
                )
            }

            Picker(
                "Decision",
                selection: Binding(
                    get: { model.manualDecision(for: region.id) },
                    set: { model.setManualDecision($0, for: region.id) }
                )
            ) {
                ForEach(RoughCutManualDecision.allCases, id: \.self) { decision in
                    Text(decision.label).tag(decision)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 174)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(rowBackground(
            isActive: isActive,
            region: region,
            manualDecision: manualDecision,
            hasJoinSuggestion: primaryJoin != nil
        ))
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func groupSelectionButton(_ group: RoughCutStoryBeat) -> some View {
        Button {
            toggleGroupSelection(group)
        } label: {
            Image(systemName: model.selectedGroupIDs.contains(group.id)
                ? "checkmark.square.fill"
                : "square")
                .font(.title3)
                .foregroundStyle(
                    model.selectedGroupIDs.contains(group.id)
                        ? Color.accentColor
                        : Color.secondary
                )
        }
        .buttonStyle(.plain)
        .help("Select this clip boundary for joining or visual planning.")
    }

    private func toggleGroupSelection(_ group: RoughCutStoryBeat) {
        guard persistEditorDraftIfNeeded() else { return }
        let update = RoughCutClipSelection.toggle(
            group.id,
            in: model.selectedGroupIDs,
            focusedGroupID: model.focusedGroupID,
            orderedGroupIDs: model.process.groups.map(\.id)
        )
        model.selectedGroupIDs = update.selectedGroupIDs
        model.focusedGroupID = update.focusedGroupID
        syncVisualEditorToFocusedGroup()
    }

    private func selectGroupFromRowClick(_ group: RoughCutStoryBeat) {
        guard persistEditorDraftIfNeeded() else { return }
        guard let currentGroup = model.process.groups.first(where: {
            $0.id == group.id
        }) else { return }
        model.selectedGroupIDs = RoughCutClipSelection.select(
            currentGroup.id,
            in: model.selectedGroupIDs,
            additive: NSEvent.modifierFlags.contains(.shift)
        )
        model.focusedGroupID = currentGroup.id
        model.editorVisualLayout = currentGroup.visual.layout
        model.editorVisualDetail = currentGroup.visual.detail
        model.isEditorVisualDirty = false
    }

    private var selectedMergedGroupIDs: Set<String> {
        Set(model.process.groups.compactMap { group in
            model.selectedGroupIDs.contains(group.id) && group.regionIDs.count > 1
                ? group.id
                : nil
        })
    }

    private func joinSelectedGroups() {
        guard persistEditorDraftIfNeeded() else { return }
        guard let mergedID = model.mergeGroups(model.selectedGroupIDs) else { return }
        model.selectedGroupIDs = [mergedID]
        model.focusedGroupID = mergedID
        model.expandedGroupIDs.insert(mergedID)
        syncVisualEditorToFocusedGroup()
    }

    private func unjoinSelectedGroups() {
        guard persistEditorDraftIfNeeded() else { return }
        let groupIDs = selectedMergedGroupIDs
        guard !groupIDs.isEmpty else { return }
        model.unmergeGroups(groupIDs)
        model.selectedGroupIDs.subtract(groupIDs)
        model.expandedGroupIDs.subtract(groupIDs)
        if let focusedGroupID = model.focusedGroupID,
           groupIDs.contains(focusedGroupID) {
            model.focusedGroupID = nil
        }
    }

    private func persistEditorDraftIfNeeded() -> Bool {
        guard RoughCutVisualDraftPersistence.shouldPersist(
            isDirty: model.isEditorVisualDirty,
            selectedGroupCount: model.selectedGroupIDs.count
        ) else { return true }
        let draft = RoughCutVisualEditor.plan(
            selecting: model.editorVisualLayout,
            detail: model.editorVisualDetail
        )
        model.assignVisual(
            layout: draft.layout,
            detail: draft.detail,
            to: model.selectedGroupIDs
        )
        let saved = model.process.groups
            .filter { model.selectedGroupIDs.contains($0.id) }
            .allSatisfy { $0.visual == draft }
        if saved {
            model.isEditorVisualDirty = false
        }
        return saved
    }

    private func syncVisualEditorToFocusedGroup() {
        guard let focusedGroupID = model.focusedGroupID,
              let group = model.process.groups.first(where: {
                  $0.id == focusedGroupID
        }) else { return }
        model.editorVisualLayout = group.visual.layout
        model.editorVisualDetail = group.visual.detail
        model.isEditorVisualDirty = false
    }

    private func playVisibleCut(
        startingAt regionID: String? = nil,
        behavior: RoughCutPlaybackStartBehavior = .explicitPlay
    ) {
        model.playFilteredCut(
            visibleRegionIDs: displayedRegions.map(\.id),
            startingAt: regionID,
            autoplay: behavior.shouldAutoplay
        )
    }

    private func playVisualCut(
        startingAt regionID: String? = nil,
        behavior: RoughCutPlaybackStartBehavior = .explicitPlay
    ) {
        model.playFilteredCut(
            visibleRegionIDs: model.process.groups.flatMap(\.regionIDs),
            startingAt: regionID,
            autoplay: behavior.shouldAutoplay
        )
    }

    private func firstVisibleRegionID(in group: RoughCutStoryBeat) -> String? {
        let visibleRegionIDs = Set(displayedRegions.map(\.id))
        return group.regionIDs.first(where: visibleRegionIDs.contains)
    }

    private var activeRegionID: String? {
        RoughCutTimelineInteraction.regionID(
            at: displayedSourceTime,
            regions: model.effectiveRegions
        )
    }

    private func rowBackground(
        isActive: Bool,
        region: RoughCutRegion,
        manualDecision: RoughCutManualDecision,
        hasJoinSuggestion: Bool
    ) -> Color {
        if isActive { return Color.accentColor.opacity(0.17) }
        if manualDecision != .automatic { return region.kind.color.opacity(0.07) }
        if hasJoinSuggestion { return Color.pink.opacity(0.055) }
        return Color(nsColor: .textBackgroundColor)
    }

    private var joinIndicatorsByRegionID: [String: [RoughCutJoinSectionIndicator]] {
        RoughCutJoinSectionIndicator.byRegionID(suggestions: model.joinSuggestions)
    }

    private func joinIndicatorLabel(_ indicator: RoughCutJoinSectionIndicator) -> String {
        let prefix: String
        switch indicator.decision {
        case .pending: prefix = "Likely join"
        case .approved: prefix = "Joined"
        case .rejected: prefix = "Rejected join"
        }
        return "\(prefix) \(indicator.proposalNumber) · clip \(indicator.clipNumber)/\(indicator.clipCount)"
    }

    private func joinIndicatorColor(_ decision: RoughCutJoinDecision) -> Color {
        switch decision {
        case .pending: return .pink
        case .approved: return .green
        case .rejected: return .gray
        }
    }

    private var timelineDuration: Double {
        let planDuration = model.analysis?.plan.source.durationSeconds ?? 0
        return max(planDuration, clock.duration, 0.001)
    }

    private func sectionSummary(_ regions: [RoughCutRegion]) -> String {
        RoughCutRegionKind.allCases.compactMap { kind in
            let count = regions.filter { $0.kind == kind }.count
            return count == 0 ? nil : "\(count) \(kind.rawValue.lowercased())"
        }.joined(separator: " · ")
    }

    private func friendlyReason(_ reason: String) -> String {
        RoughCutReasonPresentation.text(for: reason)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }
}

private enum RoughCutJoinDecisionFilter: String, CaseIterable, Identifiable {
    case pending
    case approved
    case rejected
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pending: return "Awaiting"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        case .all: return "All"
        }
    }

    func includes(_ suggestion: RoughCutJoinSuggestion) -> Bool {
        switch self {
        case .pending: return suggestion.decision == .pending
        case .approved: return suggestion.decision == .approved
        case .rejected: return suggestion.decision == .rejected
        case .all: return true
        }
    }
}

private struct RoughCutListPlayheadIndicator: View {
    let isVisible: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isVisible ? Color.accentColor : Color.clear)
                .frame(width: 2, height: 34)
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .offset(x: 2)
                .opacity(isVisible ? 1 : 0)
        }
        .frame(width: 12, height: 40, alignment: .leading)
        .accessibilityHidden(!isVisible)
        .accessibilityLabel("Currently playing")
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

private struct RoughCutJoinReviewSheet: View {
    @ObservedObject var model: RoughCutReviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var filter: RoughCutJoinDecisionFilter = .pending
    @State private var selectedSuggestionID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 285, idealWidth: 315, maxWidth: 360)
                detail
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 1040, height: 720)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: filter) { _ in selectFirstIfNeeded(force: true) }
        .onChange(of: model.joinSuggestions.map { "\($0.id):\($0.decision.rawValue)" }) { _ in
            selectFirstIfNeeded()
        }
        .onDisappear { model.stopJoinReviewPlayback() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Review suggested joins", systemImage: "sparkles")
                    .font(.title2.weight(.semibold))
                Text("Every Codex proposal stays here until you change its decision.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            decisionCount("Awaiting", model.pendingJoinCount, color: .orange)
            decisionCount("Approved", model.approvedJoinCount, color: .green)
            decisionCount("Rejected", model.rejectedJoinCount, color: .red)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            Picker("Show join suggestions", selection: $filter) {
                ForEach(RoughCutJoinDecisionFilter.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if filteredSuggestions.isEmpty {
                emptyState(
                    title: "No \(filter.label.lowercased()) joins",
                    detail: "Choose another filter or ask Codex for suggestions.",
                    systemImage: "checkmark.circle"
                )
            } else {
                List(filteredSuggestions, selection: $selectedSuggestionID) { suggestion in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(
                                suggestion.decision.label,
                                systemImage: decisionImage(suggestion.decision)
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(decisionColor(suggestion.decision))
                            Spacer()
                            Text("\(Int((suggestion.confidence * 100).rounded()))%")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(suggestion.regionIDs.count) clips")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(suggestion.reason)
                            .font(.caption)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                    .tag(suggestion.id)
                }
                .listStyle(.sidebar)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var detail: some View {
        if let suggestion = selectedSuggestion {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label(
                        suggestion.decision.label,
                        systemImage: decisionImage(suggestion.decision)
                    )
                    .foregroundStyle(decisionColor(suggestion.decision))
                    .font(.headline)
                    Spacer()
                    Text("Codex confidence \(Int((suggestion.confidence * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(suggestion.reason)
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(suggestion.regionIDs.enumerated()), id: \.element) {
                        index, regionID in
                        clipCard(regionID: regionID, number: index + 1)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Merged sentence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(mergedTranscript(suggestion))
                        .font(.body)
                        .textSelection(.enabled)
                }

                Group {
                    if let player = model.joinReviewPlayer {
                        MacVideoPlayer(player: player)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 28))
                            Text("Play either original clip or preview the proposed merge.")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.82))
                    }
                }
                .frame(minHeight: 190, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 9))

                Spacer(minLength: 0)
                decisionBar(suggestion)
            }
            .padding(16)
        } else {
            emptyState(
                title: "Choose a suggestion",
                detail: "Select a join proposal from the list.",
                systemImage: "rectangle.and.hand.point.up.left"
            )
        }
    }

    private func clipCard(regionID: String, number: Int) -> some View {
        let region = model.effectiveRegions.first { $0.id == regionID }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Clip \(number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                if let region {
                    Text("\(formatTime(region.start)) – \(formatTime(region.end))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(region?.text.isEmpty == false ? region?.text ?? "" : "No transcript")
                .font(.callout)
                .lineLimit(4)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            Button("Play Clip \(number)", systemImage: "play.fill") {
                model.previewJoinRegion(regionID)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func decisionBar(_ suggestion: RoughCutJoinSuggestion) -> some View {
        HStack {
            Button("Previous", systemImage: "chevron.left") { moveSelection(-1) }
                .disabled(selectedIndex == 0)
            Button("Next", systemImage: "chevron.right") { moveSelection(1) }
                .disabled(selectedIndex >= filteredSuggestions.count - 1)
            Spacer()
            Button("Preview merged", systemImage: "play.fill") {
                model.previewJoinSuggestion(suggestion)
            }
            .buttonStyle(.borderedProminent)
            if suggestion.decision != .pending {
                Button("Undo decision", systemImage: "arrow.uturn.backward") {
                    apply(.pending, to: suggestion)
                }
            }
            Button("Reject merge", systemImage: "xmark") {
                apply(.rejected, to: suggestion)
            }
            .tint(.red)
            .disabled(suggestion.decision == .rejected)
            Button("Approve merge", systemImage: "checkmark") {
                apply(.approved, to: suggestion)
            }
            .tint(.green)
            .disabled(suggestion.decision == .approved)
        }
    }

    private var filteredSuggestions: [RoughCutJoinSuggestion] {
        model.joinSuggestions.filter(filter.includes)
    }

    private var selectedSuggestion: RoughCutJoinSuggestion? {
        filteredSuggestions.first { $0.id == selectedSuggestionID }
    }

    private var selectedIndex: Int {
        filteredSuggestions.firstIndex { $0.id == selectedSuggestionID } ?? 0
    }

    private func selectFirstIfNeeded(force: Bool = false) {
        if force || !filteredSuggestions.contains(where: { $0.id == selectedSuggestionID }) {
            selectedSuggestionID = filteredSuggestions.first?.id
        }
    }

    private func moveSelection(_ offset: Int) {
        guard !filteredSuggestions.isEmpty else { return }
        let next = max(0, min(filteredSuggestions.count - 1, selectedIndex + offset))
        selectedSuggestionID = filteredSuggestions[next].id
    }

    private func apply(
        _ decision: RoughCutJoinDecision,
        to suggestion: RoughCutJoinSuggestion
    ) {
        let oldIndex = selectedIndex
        model.setJoinDecision(decision, for: suggestion)
        let updated = filteredSuggestions
        selectedSuggestionID = updated.isEmpty
            ? nil
            : updated[min(oldIndex, updated.count - 1)].id
    }

    private func mergedTranscript(_ suggestion: RoughCutJoinSuggestion) -> String {
        let byID = Dictionary(uniqueKeysWithValues: model.effectiveRegions.map { ($0.id, $0) })
        return suggestion.regionIDs.compactMap { byID[$0]?.text }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func decisionCount(_ label: String, _ count: Int, color: Color) -> some View {
        Text("\(label) \(count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private func emptyState(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func decisionImage(_ decision: RoughCutJoinDecision) -> String {
        switch decision {
        case .pending: return "questionmark.circle"
        case .approved: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        }
    }

    private func decisionColor(_ decision: RoughCutJoinDecision) -> Color {
        switch decision {
        case .pending: return .orange
        case .approved: return .green
        case .rejected: return .red
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }
}

private struct RoughCutAssemblyTimelineGroup: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let duration: Double
    let visualLayout: RoughCutVisualLayout
    let isAISuggested: Bool
    let isIncludedByFilter: Bool
}

private struct RoughCutEditedTimelineClip: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let kind: RoughCutRegionKind
}

private struct RoughCutAssemblyTimelineView: View {
    let groups: [RoughCutAssemblyTimelineGroup]
    let clipBoundaries: [Double]
    let duration: Double
    let currentTime: Double
    let selectedGroupIDs: Set<String>
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.7))
                ForEach(groups.filter {
                    $0.visualLayout != .unassigned
                }) { group in
                    let range = RoughCutTimelineGeometry.normalizedRange(
                        start: group.start,
                        end: group.end,
                        duration: duration
                    )
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            group.isAISuggested
                                ? color(for: group).opacity(0.2)
                                : color(for: group)
                        )
                        .frame(
                            width: max(3, geometry.size.width * range.length),
                            height: selectedGroupIDs.contains(group.id) ? 28 : 22
                        )
                        .overlay {
                            if group.isAISuggested {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(
                                        color(for: group),
                                        style: StrokeStyle(
                                            lineWidth: 2,
                                            dash: [5, 3]
                                        )
                                    )
                            }
                            if selectedGroupIDs.contains(group.id) {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white, lineWidth: 2)
                            }
                        }
                        // Apply the offset after the overlay so the selection
                        // outline travels with its visual block.
                        .offset(x: geometry.size.width * range.start)
                        .help(
                            "\(group.visualLayout.label)\(group.isAISuggested ? " · AI suggested" : "") · \(formatDuration(group.duration))"
                        )
                        .onTapGesture { onSelect(group.id) }
                }

                clipBoundaryLines(in: geometry)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 30)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .offset(
                        x: geometry.size.width
                            * RoughCutTimelineGeometry.normalizedPosition(
                                time: currentTime,
                                duration: duration
                            )
                    )
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func clipBoundaryLines(in geometry: GeometryProxy) -> some View {
        ForEach(Array(clipBoundaries.enumerated()), id: \.offset) { _, boundary in
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .frame(width: 1, height: 30)
                .offset(
                    x: geometry.size.width
                        * RoughCutTimelineGeometry.normalizedPosition(
                            time: boundary,
                            duration: duration
                        )
                )
        }
    }

    private func color(for group: RoughCutAssemblyTimelineGroup) -> Color {
        guard group.isIncludedByFilter else {
            return Color.gray.opacity(0.1)
        }
        return group.visualLayout.color.opacity(0.9)
    }

    private func formatDuration(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }
}

private struct RoughCutEditedTimelineView: View {
    let clips: [RoughCutEditedTimelineClip]
    let clipBoundaries: [Double]
    let duration: Double
    let currentTime: Double
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.7))

                ForEach(clips) { clip in
                    let range = RoughCutTimelineGeometry.normalizedRange(
                        start: clip.start,
                        end: clip.end,
                        duration: duration
                    )
                    Rectangle()
                        .fill(clip.kind.color.opacity(0.9))
                        .frame(
                            width: max(2, geometry.size.width * range.length),
                            height: 26
                        )
                        .offset(x: geometry.size.width * range.start)
                }

                ForEach(Array(clipBoundaries.enumerated()), id: \.offset) { _, boundary in
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 1, height: 30)
                        .offset(
                            x: geometry.size.width
                                * RoughCutTimelineGeometry.normalizedPosition(
                                    time: boundary,
                                    duration: duration
                                )
                        )
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 36)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .offset(
                        x: geometry.size.width
                            * RoughCutTimelineGeometry.normalizedPosition(
                                time: currentTime,
                                duration: duration
                            )
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(RoughCutTimelineInteraction.seconds(
                            x: value.location.x,
                            width: geometry.size.width,
                            duration: duration
                        ))
                    }
                    .onEnded { value in
                        onScrubEnd(RoughCutTimelineInteraction.seconds(
                            x: value.location.x,
                            width: geometry.size.width,
                            duration: duration
                        ))
                    }
            )
        }
    }
}

private struct RoughCutTimelineView: View {
    let regions: [RoughCutRegion]
    let joinSuggestions: [RoughCutJoinSuggestion]
    let visibleRegionIDs: Set<String>?
    let duration: Double
    let currentTime: Double
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.7))

                ForEach(regions) { region in
                    let range = RoughCutTimelineGeometry.normalizedRange(
                        start: region.start,
                        end: region.end,
                        duration: duration
                    )
                    let isVisible = visibleRegionIDs?.contains(region.id) ?? true
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            isVisible
                                ? region.kind.color.opacity(0.9)
                                : Color.gray.opacity(0.08)
                        )
                        .frame(width: max(2, geometry.size.width * range.length), height: 26)
                        .offset(x: geometry.size.width * range.start)
                        .help("\(region.kind.rawValue): \(region.text.isEmpty ? region.reason : region.text)")

                }

                ForEach(joinMarkers) { marker in
                    Rectangle()
                        .fill(marker.color)
                        .frame(width: 3, height: 34)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .offset(
                            x: geometry.size.width
                                * RoughCutTimelineGeometry.normalizedPosition(
                                    time: marker.time,
                                    duration: duration
                                )
                        )
                        .help("Likely join: \(marker.reason)")
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 36)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .offset(
                        x: geometry.size.width
                            * RoughCutTimelineGeometry.normalizedPosition(
                                time: currentTime,
                                duration: duration
                            )
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(RoughCutTimelineInteraction.seconds(
                            x: value.location.x,
                            width: geometry.size.width,
                            duration: duration
                        ))
                    }
                    .onEnded { value in
                        onScrubEnd(RoughCutTimelineInteraction.seconds(
                            x: value.location.x,
                            width: geometry.size.width,
                            duration: duration
                        ))
                    }
            )
        }
    }

    private var joinMarkers: [RoughCutTimelineJoinMarker] {
        let regionsByID = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
        return joinSuggestions.flatMap { suggestion in
            zip(suggestion.regionIDs, suggestion.regionIDs.dropFirst()).compactMap {
                leftID, rightID -> RoughCutTimelineJoinMarker? in
                guard let left = regionsByID[leftID], let right = regionsByID[rightID] else {
                    return nil
                }
                return RoughCutTimelineJoinMarker(
                    id: "\(suggestion.id)|\(rightID)",
                    time: (left.end + right.start) / 2,
                    reason: suggestion.reason,
                    decision: suggestion.decision
                )
            }
        }
    }
}

private struct RoughCutTimelineJoinMarker: Identifiable {
    let id: String
    let time: Double
    let reason: String
    let decision: RoughCutJoinDecision

    var color: Color {
        switch decision {
        case .pending: return .pink
        case .approved: return .green
        case .rejected: return .gray
        }
    }
}

private extension RoughCutRegionKind {
    var color: Color {
        switch self {
        case .valid: return .green
        case .falseStart: return .orange
        case .badTake: return .red
        case .noTranscriptSkip: return .gray
        case .needsReview: return .yellow
        }
    }
}

private extension RoughCutVisualLayout {
    var color: Color {
        switch self {
        case .unassigned: return .gray
        case .talkingHeadFullScreen: return .blue
        case .cameraCutoutCorner: return .mint
        case .bRollFullScreen: return .orange
        case .screenRecordingFullScreen: return .purple
        case .aiBRollFullScreen: return .pink
        case .screencastWithCamera: return .indigo
        }
    }
}
