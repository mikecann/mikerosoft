import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RoughCutReviewModel: ObservableObject {
    let project: VideoProject
    let script: String

    @Published private(set) var sourceVideos: [URL] = []
    @Published private(set) var selectedVideoURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var analysis: RoughCutAnalysis?
    @Published private(set) var scriptCoverage: RoughCutScriptCoverageReport?
    @Published private(set) var manualDecisions: [String: RoughCutManualDecision] = [:]
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var isImporting = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isExporting = false
    @Published private(set) var statusMessage = "Choose a source recording to begin."
    @Published var errorMessage: String?

    private let sourceLibrary: RoughCutSourceLibrary
    private let analysisStore: RoughCutAnalysisStore
    private let runner: FilmoraRoughCutRunner
    private let exportRunner: FilmoraRoughCutExportRunner

    init(project: VideoProject, script: String, configuration: VideoHQConfiguration) {
        self.project = project
        self.script = script
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

    var isWorking: Bool { isImporting || isAnalyzing || isExporting }
    var canAnalyze: Bool { selectedVideoURL != nil && !isWorking }
    var analyzeButtonTitle: String { analysis == nil ? "Analyze Recording" : "Run Again" }
    var effectiveRegions: [RoughCutRegion] {
        analysis?.plan.regions.map {
            $0.applyingManualDecision(manualDecisions[$0.id])
        } ?? []
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
        player?.pause()
        selectedVideoURL = url
        player = AVPlayer(url: url)

        do {
            analysis = try analysisStore.latestAnalysis(for: url)
            if let analysis {
                manualDecisions = try RoughCutOverrideStore(
                    analysisDirectoryURL: analysis.directoryURL
                ).load()
            } else {
                manualDecisions = [:]
            }
            lastExportURL = nil
            updateScriptCoverage()
            if let analysis {
                statusMessage = "Loaded saved analysis from \(formatted(analysis.createdAt))."
            } else {
                statusMessage = "Source loaded. Analyze it to detect silence and repeated takes."
            }
        } catch {
            analysis = nil
            scriptCoverage = nil
            manualDecisions = [:]
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
                statusMessage = "Detecting silence and repeated takes. \(transcriptNote)"

                let completed = try await Task.detached(priority: .userInitiated) {
                    let outputDirectoryURL = try store.newRunDirectoryURL(for: sourceVideoURL)
                    _ = try runner.run(
                        videoURL: sourceVideoURL,
                        outputDirectoryURL: outputDirectoryURL,
                        transcriptURL: reusableTranscript
                    )
                    return try store.recordCompletedRun(
                        at: outputDirectoryURL,
                        sourceVideoURL: sourceVideoURL
                    )
                }.value

                analysis = completed
                manualDecisions = [:]
                lastExportURL = nil
                updateScriptCoverage()
                statusMessage = "Analysis complete. Review the color-coded timeline and listen through the proposed decisions."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Rough-cut analysis failed."
            }
            isAnalyzing = false
        }
    }

    func seek(to seconds: Double, play: Bool = false) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        if play { player.play() }
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
            updateScriptCoverage()
            statusMessage = "Saved manual \(decision.label.lowercased()) decision for this section."
        } catch {
            manualDecisions = previous
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
        player?.pause()
    }

    private func updateScriptCoverage() {
        guard analysis != nil, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            scriptCoverage = nil
            return
        }
        scriptCoverage = RoughCutScriptCoverage.analyze(
            script: script,
            regions: effectiveRegions
        )
    }

    private func clearSelection() {
        player?.pause()
        selectedVideoURL = nil
        player = nil
        analysis = nil
        scriptCoverage = nil
        manualDecisions = [:]
        lastExportURL = nil
        statusMessage = "No videos are in the project source directory yet."
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

    func show(project: VideoProject, script: String, configuration: VideoHQConfiguration) {
        model?.stopPlayback()
        let model = RoughCutReviewModel(
            project: project,
            script: script,
            configuration: configuration
        )
        let window = window ?? makeWindow()
        window.title = "Rough Cut Review - \(project.name)"
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
        .alert("Rough Cut Review", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Something went wrong.")
        }
    }

    private var header: some View {
        VStack(spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Rough Cut Review", systemImage: "scissors")
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
                HSplitView {
                    regionReview
                        .frame(minWidth: 610)
                    scriptReview
                        .frame(minWidth: 300, idealWidth: 360)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("The source is ready")
                        .font(.headline)
                    Text("Run analysis to replace the plain timeline with valid sections, false starts, bad takes, review items, and script mismatch markers.")
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
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.analysis == nil ? "Source timeline" : "Analysis timeline")
                    .font(.headline)
                Text("\(formatTime(clock.currentTime)) / \(formatTime(timelineDuration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.analysis != nil { legend }
            }

            RoughCutTimelineView(
                regions: model.effectiveRegions,
                duration: timelineDuration,
                currentTime: clock.currentTime,
                mismatchedRegionIDs: model.scriptCoverage?.mismatchedRegionIDs ?? [],
                onSeek: { model.seek(to: $0) }
            )
            .frame(height: 38)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(RoughCutRegionKind.allCases, id: \.self) { kind in
                HStack(spacing: 4) {
                    Circle().fill(kind.color).frame(width: 8, height: 8)
                    Text(kind.rawValue).font(.caption2)
                }
            }
            HStack(spacing: 4) {
                Rectangle().fill(Color.purple).frame(width: 10, height: 3)
                Text("Script mismatch").font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var regionReview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Detected sections")
                    .font(.headline)
                Text(sectionSummary(model.effectiveRegions))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Scrub the timeline or click a row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.effectiveRegions) { region in
                            regionRow(region, isActive: region.id == activeRegionID)
                                .id(region.id)
                        }
                    }
                }
                .onChange(of: activeRegionID) { regionID in
                    guard let regionID else { return }
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

    private func regionRow(_ region: RoughCutRegion, isActive: Bool) -> some View {
        let isMismatch = model.scriptCoverage?.mismatchedRegionIDs.contains(region.id) == true
        let manualDecision = model.manualDecision(for: region.id)
        return HStack(alignment: .center, spacing: 10) {
            Button {
                model.seek(to: region.start, play: true)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(region.kind.color)
                    .frame(width: 7, height: 38)
                    .overlay(alignment: .bottom) {
                        if isMismatch {
                            Rectangle().fill(Color.purple).frame(height: 5)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(region.kind.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(region.kind.color)
                        Text("\(formatTime(region.start)) - \(formatTime(region.end))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if isMismatch {
                            Label("Script mismatch", systemImage: "text.badge.xmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.purple)
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
        .background(rowBackground(isActive: isActive, region: region, manualDecision: manualDecision))
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
        manualDecision: RoughCutManualDecision
    ) -> Color {
        if isActive { return Color.accentColor.opacity(0.17) }
        if manualDecision != .automatic { return region.kind.color.opacity(0.07) }
        return Color(nsColor: .textBackgroundColor)
    }

    @ViewBuilder
    private var scriptReview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Script coverage", systemImage: "text.magnifyingglass")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            if model.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scriptEmptyState(
                    icon: "doc.badge.ellipsis",
                    title: "No project script",
                    message: "Add or sync a script in Video HQ to compare the recording against it."
                )
            } else if let coverage = model.scriptCoverage {
                if coverage.missingParagraphs.isEmpty {
                    scriptEmptyState(
                        icon: "checkmark.circle.fill",
                        title: "No obvious omissions",
                        message: "Every spoken script paragraph has reasonable ordered-token coverage in retained sections."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Likely missing from the recording")
                            .font(.subheadline.weight(.semibold))
                        Text("Purple timeline marks show retained speech that also looks off-script.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(coverage.missingParagraphs) { paragraph in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(paragraph.text)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(Int((paragraph.coverage * 100).rounded()))% transcript coverage")
                                            .font(.caption2)
                                            .foregroundStyle(.purple)
                                    }
                                    .padding(10)
                                    .background(Color.purple.opacity(0.09))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            } else {
                scriptEmptyState(
                    icon: "hourglass",
                    title: "Analyze the recording first",
                    message: "Script coverage is calculated from the retained transcription after rough-cut analysis."
                )
            }

            Divider()
            Text("Coverage is a transcript comparison, not proof. Listen through the flagged sections before accepting the cut.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18))
        }
    }

    private func scriptEmptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(icon.hasPrefix("checkmark") ? Color.green : Color.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
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
        reason.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }
}

private struct RoughCutTimelineView: View {
    let regions: [RoughCutRegion]
    let duration: Double
    let currentTime: Double
    let mismatchedRegionIDs: Set<String>
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

                    if mismatchedRegionIDs.contains(region.id) {
                        Rectangle()
                            .fill(Color.purple)
                            .frame(width: max(2, geometry.size.width * length), height: 4)
                            .offset(x: geometry.size.width * start, y: 14)
                    }
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
}

private extension RoughCutRegionKind {
    var color: Color {
        switch self {
        case .valid: return .green
        case .falseStart: return .orange
        case .badTake: return .red
        case .needsReview: return .yellow
        }
    }
}
