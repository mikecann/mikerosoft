import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

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
    @Published private(set) var joinSuggestions: [RoughCutJoinSuggestion] = []
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var isImporting = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isExporting = false
    @Published private(set) var isSuggestingJoins = false
    @Published private(set) var isBuildingJoinPreview = false
    @Published private(set) var statusMessage = "Choose a source recording to begin."
    @Published var errorMessage: String?
    @Published var stage: RoughCutProcessStage = .review

    private let sourceLibrary: RoughCutSourceLibrary
    private let analysisStore: RoughCutAnalysisStore
    private let runner: FilmoraRoughCutRunner
    private let codexAnalysisRunner = CodexRoughCutAnalysisRunner()
    private let exportRunner: FilmoraRoughCutExportRunner
    private let codexJoinRunner = CodexJoinSuggestionRunner()
    private var transcriptWords: [RoughCutTranscript.Word] = []
    private var isPlayingComposition = false

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
            || isBuildingJoinPreview
    }
    var canAnalyze: Bool { selectedVideoURL != nil && !isWorking }
    var canSuggestJoins: Bool { analysis != nil && acceptedRegions.count >= 2 && !isWorking }
    var analyzeButtonTitle: String { analysis == nil ? "Analyze Recording" : "Run Again" }
    var effectiveRegions: [RoughCutRegion] {
        analysis?.plan.regions.map {
            $0.applyingManualDecision(manualDecisions[$0.id])
        } ?? []
    }
    var acceptedRegions: [RoughCutRegion] {
        effectiveRegions.filter { $0.decision == "keep" }
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
                selectVideo(imported)
                statusMessage = "Imported \(imported.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Source import failed."
            }
            isImporting = false
        }
    }

    func selectVideo(_ url: URL) {
        guard !isWorking else { return }
        stopAssembledPlayback()
        stopJoinReviewPlayback()
        player?.pause()
        selectedVideoURL = url
        player = AVPlayer(url: url)

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
            }
            lastExportURL = nil
            stage = .review
            isPlayingComposition = false
            if let analysis {
                statusMessage = "Loaded saved analysis from \(formatted(analysis.createdAt))."
            } else {
                statusMessage = "Source loaded. Analyze it to detect silence and repeated takes."
            }
        } catch {
            analysis = nil
            manualDecisions = [:]
            process = .initial(acceptedRegionIDs: [])
            errorMessage = error.localizedDescription
        }
    }

    func analyze() {
        guard canAnalyze, let sourceVideoURL = selectedVideoURL else { return }
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
                stage = .review
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

    func seek(to seconds: Double, play: Bool = false) {
        stopAssembledPlayback()
        restoreSourcePlayerIfNeeded()
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        if play { player.play() }
    }

    func play(_ group: RoughCutStoryBeat) {
        let regions = regions(for: group)
        guard !regions.isEmpty else { return }
        stopAssembledPlayback()
        guard group.regionIDs.count > 1, let sourceURL = selectedVideoURL else {
            seek(to: regions[0].start, play: true)
            return
        }

        let playbackPlan = playbackPlan(for: group)
        isBuildingJoinPreview = true
        statusMessage = "Building a speech-tight preview with \(group.regionIDs.count - 1) join\(group.regionIDs.count == 2 ? "" : "s")..."
        Task {
            do {
                let result = try await RoughCutPlaybackCompositionBuilder.build(
                    sourceURL: sourceURL,
                    plan: playbackPlan
                )
                let item = AVPlayerItem(asset: result.composition)
                item.audioMix = result.audioMix
                player = AVPlayer(playerItem: item)
                isPlayingComposition = true
                player?.play()
                statusMessage = "Previewing the merged beat with word-edge trims and 40 ms audio crossfades."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not build the merged-beat preview."
            }
            isBuildingJoinPreview = false
        }
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
        do {
            let selectedRegionIDs = process.groups
                .filter { groupIDs.contains($0.id) }
                .flatMap(\.regionIDs)
            let updated = try process.merging(groupIDs: groupIDs)
            try RoughCutProcessStore(analysisDirectoryURL: analysis.directoryURL).save(updated)
            process = updated
            let mergedID = updated.groups.first { $0.regionIDs == selectedRegionIDs }?.id
            statusMessage = "Merged \(selectedRegionIDs.count) accepted clips into one story beat."
            return mergedID
        } catch {
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
                    && unmergedRegionGroups.contains(updatedSuggestions[index].regionIDs) {
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
                ? "Split the story beat and returned its approved suggestion to Not decided."
                : "Split the selected story beat back into its accepted clips."
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
                statusMessage = "Approved the join and merged \(suggestion.regionIDs.count) clips."
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
        joinReviewPlayer?.pause()
    }

    func assignVisual(
        layout: RoughCutVisualLayout,
        detail: String,
        to groupIDs: Set<String>
    ) {
        guard let analysis, !groupIDs.isEmpty else { return }
        do {
            let visual = RoughCutVisualPlan(
                layout: layout,
                detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let updated = process.assigningVisual(visual, toGroupIDs: groupIDs)
            try RoughCutProcessStore(analysisDirectoryURL: analysis.directoryURL).save(updated)
            process = updated
            statusMessage = "Applied \(layout.label.lowercased()) to \(groupIDs.count) story beat\(groupIDs.count == 1 ? "" : "s")."
        } catch {
            errorMessage = error.localizedDescription
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
                        filmoraSourceDurationSeconds: seed.sourceDurationSeconds
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
        stopAssembledPlayback()
        stopJoinReviewPlayback()
        player?.pause()
    }

    private func clearSelection() {
        player?.pause()
        selectedVideoURL = nil
        player = nil
        analysis = nil
        manualDecisions = [:]
        process = .initial(acceptedRegionIDs: [])
        joinSuggestions = []
        joinReviewPlayer = nil
        transcriptWords = []
        lastExportURL = nil
        stage = .review
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
        isBuildingJoinPreview = true
        statusMessage = "Building preview..."
        Task {
            do {
                let result = try await RoughCutPlaybackCompositionBuilder.build(
                    sourceURL: sourceURL,
                    plan: plan
                )
                let item = AVPlayerItem(asset: result.composition)
                item.audioMix = result.audioMix
                joinReviewPlayer = AVPlayer(playerItem: item)
                joinReviewPlayer?.play()
                statusMessage = status
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not build the join-review preview."
            }
            isBuildingJoinPreview = false
        }
    }

    private func stopAssembledPlayback() {
        player?.pause()
    }

    private func restoreSourcePlayerIfNeeded() {
        guard isPlayingComposition, let selectedVideoURL else { return }
        player = AVPlayer(url: selectedVideoURL)
        isPlayingComposition = false
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

    func show(project: VideoProject, configuration: VideoHQConfiguration) {
        model?.stopPlayback()
        let model = RoughCutReviewModel(
            project: project,
            configuration: configuration
        )
        let window = window ?? makeWindow()
        window.title = "Rough Cut Process - \(project.name)"
        window.contentView = NSHostingView(rootView: RoughCutReviewView(model: model))
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.model = model
        self.window = window
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
                    Picker("Rough cut stage", selection: $model.stage) {
                        ForEach(RoughCutProcessStage.allCases) { stage in
                            Text(stage.label).tag(stage)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 620)

                    switch model.stage {
                    case .review:
                        Text("\(model.unresolvedReviewCount) review calls outstanding")
                    case .visuals:
                        Text("\(model.plannedVisualCount) of \(model.process.groups.count) beats planned")
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
                .id(ObjectIdentifier(player))
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
private final class RoughCutPlaybackClock: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private let player: AVPlayer
    private var timeObserver: Any?

    init(player: AVPlayer) {
        self.player = player
        if let asset = player.currentItem?.asset {
            Task { [weak self] in
                guard let loadedDuration = try? await asset.load(.duration),
                      loadedDuration.seconds.isFinite,
                      loadedDuration.seconds > 0 else { return }
                self?.duration = loadedDuration.seconds
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds.isFinite ? max(0, time.seconds) : 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                currentTime = seconds
                let itemDuration = player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 {
                    duration = itemDuration
                }
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }
}

private struct RoughCutPlayerWorkspace: View {
    @ObservedObject var model: RoughCutReviewModel
    @StateObject private var clock: RoughCutPlaybackClock
    @State private var regionFilter: RoughCutRegionFilter = .all
    @State private var selectedGroupIDs = Set<String>()
    @State private var visualLayout: RoughCutVisualLayout = .unassigned
    @State private var visualDetail = ""
    @State private var isJoinReviewPresented = false
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
        .onChange(of: model.process.groups.map(\.id)) { validIDs in
            selectedGroupIDs.formIntersection(validIDs)
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

            if model.analysis != nil, model.stage != .review {
                RoughCutAssemblyTimelineView(
                    groups: assemblyTimelineGroups,
                    selectedGroupIDs: selectedGroupIDs,
                    onSelect: selectAndPlay
                )
                .frame(height: 38)
            } else {
                RoughCutTimelineView(
                    regions: model.effectiveRegions,
                    joinSuggestions: model.joinSuggestions,
                    duration: timelineDuration,
                    currentTime: clock.currentTime,
                    onSeek: { model.seek(to: $0) }
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
        return model.stage == .review ? "Analysis timeline" : "Visual plan timeline"
    }

    private var timelineTimeLabel: String {
        if model.analysis != nil, model.stage != .review {
            return "\(formatTime(assembledDuration)) after silence removal"
        }
        return "\(formatTime(clock.currentTime)) / \(formatTime(timelineDuration))"
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

    private var visualPlanning: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Plan what viewers see")
                    .font(.headline)
                Text("\(model.plannedVisualCount) of \(model.process.groups.count) planned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedGroupIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            stageNotice

            HStack(spacing: 10) {
                Picker("Layout", selection: $visualLayout) {
                    ForEach(RoughCutVisualLayout.allCases) { layout in
                        Label(layout.label, systemImage: layout.systemImage).tag(layout)
                    }
                }
                .frame(width: 245)

                TextField(visualDetailPlaceholder, text: $visualDetail)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!visualLayout.needsDetail)

                if visualLayout.needsDetail && visualLayout != .aiBRollFullScreen {
                    Button("Choose Media", systemImage: "folder") {
                        chooseVisualMedia()
                    }
                }

                Button("Apply to selected", systemImage: "paintbrush") {
                    model.assignVisual(
                        layout: visualLayout,
                        detail: visualDetail,
                        to: selectedGroupIDs
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedGroupIDs.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.process.groups.enumerated()), id: \.element.id) {
                        index, group in
                        storyBeatRow(group, index: index, showsVisualPlan: true)
                    }
                }
            }

            Divider()
            Text("Visual choices are saved in video-hq-process.json beside this analysis. Filmora export still creates the reviewed dialogue cut; visual-track generation will be added after this planning workflow feels right.")
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

    @ViewBuilder
    private var stageNotice: some View {
        if model.unresolvedReviewCount > 0 {
            Label(
                "\(model.unresolvedReviewCount) review items are still unresolved and remain outside this assembled cut.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func storyBeatRow(
        _ group: RoughCutStoryBeat,
        index: Int,
        showsVisualPlan: Bool
    ) -> some View {
        let selected = selectedGroupIDs.contains(group.id)
        let transcript = model.transcript(for: group)
        return HStack(alignment: .center, spacing: 10) {
            Button {
                toggleSelection(group)
            } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Button {
                model.play(group)
            } label: {
                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("Beat \(index + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text("\(group.regionIDs.count) clip\(group.regionIDs.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatTime(model.duration(of: group)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if group.regionIDs.count > 1 {
                        Label("Merged", systemImage: "link")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                Text(transcript.isEmpty ? "No transcript for this beat" : transcript)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsVisualPlan {
                VStack(alignment: .trailing, spacing: 4) {
                    Label(group.visual.layout.label, systemImage: group.visual.layout.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(group.visual.layout == .unassigned
                            ? Color.orange
                            : Color.accentColor)
                    if !group.visual.detail.isEmpty {
                        Text(group.visual.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 260)
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSelection(group)
        }
    }

    private func toggleSelection(_ group: RoughCutStoryBeat) {
        if selectedGroupIDs.remove(group.id) == nil {
            selectedGroupIDs.insert(group.id)
            if selectedGroupIDs.count == 1 {
                visualLayout = group.visual.layout
                visualDetail = group.visual.detail
            }
        }
    }

    private func selectAndPlay(_ groupID: String) {
        guard let group = model.process.groups.first(where: { $0.id == groupID }) else { return }
        selectedGroupIDs = [groupID]
        visualLayout = group.visual.layout
        visualDetail = group.visual.detail
        model.play(group)
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
        visualDetail = url.path
    }

    private var visualDetailPlaceholder: String {
        switch visualLayout {
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
        model.process.groups.map { group in
            RoughCutAssemblyTimelineGroup(
                id: group.id,
                duration: model.duration(of: group),
                visualLayout: group.visual.layout
            )
        }
    }

    private var assembledDuration: Double {
        assemblyTimelineGroups.reduce(0) { $0 + $1.duration }
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
                Picker("Filter sections", selection: $regionFilter) {
                    ForEach(RoughCutRegionFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 145, alignment: .leading)

                Text("\(displayedRegions.count) of \(model.effectiveRegions.count) sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if displayedRegions.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: regionFilter == .awaitingDecision
                                ? "checkmark.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(regionFilter == .awaitingDecision
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
                            ForEach(displayedRegions) { region in
                                regionRow(region, isActive: region.id == activeRegionID)
                                    .id(region.id)
                            }
                        }
                    }
                }
                .onChange(of: activeRegionID) { regionID in
                    guard let regionID,
                          displayedRegions.contains(where: { $0.id == regionID }) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(regionID, anchor: .center)
                    }
                }
            }
            Divider()
            Text("Auto follows the analysis. Keep and Cut override it and save immediately for this analysis run.")
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

    private var displayedRegions: [RoughCutRegion] {
        guard let plannerRegions = model.analysis?.plan.regions else { return [] }
        let visibleIDs = Set(
            regionFilter.apply(
                to: plannerRegions,
                manualDecisions: model.manualDecisions
            ).map(\.id)
        )
        return model.effectiveRegions.filter { visibleIDs.contains($0.id) }
    }

    private var emptyFilterTitle: String {
        regionFilter == .awaitingDecision
            ? "No review calls outstanding"
            : "No matching sections"
    }

    private func regionRow(_ region: RoughCutRegion, isActive: Bool) -> some View {
        let manualDecision = model.manualDecision(for: region.id)
        let joinIndicators = joinIndicatorsByRegionID[region.id] ?? []
        let primaryJoin = joinIndicators.first
        let inlineJoinSuggestion = primaryJoin?.showsInlineAction == true
            ? model.joinSuggestions.first { $0.id == primaryJoin?.suggestionID }
            : nil
        return HStack(alignment: .center, spacing: 10) {
            Button {
                model.seek(to: region.start, play: true)
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

    private var activeRegionID: String? {
        RoughCutTimelineInteraction.regionID(
            at: clock.currentTime,
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
    let duration: Double
    let visualLayout: RoughCutVisualLayout
}

private struct RoughCutAssemblyTimelineView: View {
    let groups: [RoughCutAssemblyTimelineGroup]
    let selectedGroupIDs: Set<String>
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            let totalDuration = max(groups.reduce(0) { $0 + $1.duration }, 0.001)
            HStack(spacing: 1) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: group, index: index))
                        .frame(
                            width: max(
                                3,
                                (geometry.size.width - CGFloat(max(0, groups.count - 1)))
                                    * group.duration / totalDuration
                            ),
                            height: selectedGroupIDs.contains(group.id) ? 34 : 28
                        )
                        .overlay {
                            if selectedGroupIDs.contains(group.id) {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white, lineWidth: 2)
                            }
                        }
                        .help("Story beat \(index + 1) · \(formatDuration(group.duration))")
                        .onTapGesture { onSelect(group.id) }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func color(
        for group: RoughCutAssemblyTimelineGroup,
        index: Int
    ) -> Color {
        if group.visualLayout != .unassigned {
            return group.visualLayout.color.opacity(0.9)
        }
        return index.isMultiple(of: 2)
            ? Color.blue.opacity(0.9)
            : Color.cyan.opacity(0.75)
    }

    private func formatDuration(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }
}

private struct RoughCutTimelineView: View {
    let regions: [RoughCutRegion]
    let joinSuggestions: [RoughCutJoinSuggestion]
    let duration: Double
    let currentTime: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.7))

                ForEach(regions) { region in
                    let start = max(0, min(1, region.start / duration))
                    let length = max(0, min(1 - start, region.duration / duration))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(region.kind.color.opacity(0.9))
                        .frame(width: max(2, geometry.size.width * length), height: 26)
                        .offset(x: geometry.size.width * start)
                        .help("\(region.kind.rawValue): \(region.text.isEmpty ? region.reason : region.text)")

                }

                ForEach(joinMarkers) { marker in
                    Rectangle()
                        .fill(marker.color)
                        .frame(width: 3, height: 34)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .offset(
                            x: geometry.size.width
                                * max(0, min(1, marker.time / duration))
                        )
                        .help("Likely join: \(marker.reason)")
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 36)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .offset(x: geometry.size.width * max(0, min(1, currentTime / duration)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(RoughCutTimelineInteraction.seconds(
                            x: value.location.x,
                            width: geometry.size.width,
                            duration: duration
                        ))
                    }
                    .onEnded { value in
                        onSeek(RoughCutTimelineInteraction.seconds(
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
