import AppKit
import SwiftUI
import TandemAPI
import TandemCore

/// File > Archive project…: makes the project standalone, either in its own
/// folder or as a copy somewhere else (Bruce's archive share). It opens with
/// a dry run of the choice (what would be copied, the sizes, anything
/// missing), shows progress while it copies, and says where the archive
/// went. `ProjectArchiver` does the work, the same as `tandem archive`.
@MainActor
@Observable
final class ArchiveSheetModel {
    enum Mode: Hashable {
        /// A standalone copy of the folder somewhere else.
        case copy
        /// This folder, made standalone.
        case consolidate
    }

    enum Stage: Equatable {
        case planning, ready, running, done, stopped
        case failed(String)
    }

    static let destinationKey = "archiveDestination"

    @ObservationIgnored let session: ProjectSession
    let projectName: String
    var mode: Mode {
        didSet { if mode != oldValue { replan() } }
    }
    var destination: URL? {
        didSet { if destination != oldValue { replan() } }
    }
    var withCache = false {
        didSet { if withCache != oldValue { replan() } }
    }
    private(set) var stage: Stage = .planning
    /// The dry run for what's chosen now.
    private(set) var plan: ArchiveResult?
    private(set) var planProblem: String?
    private(set) var progress: ArchiveProgress?
    private(set) var result: ArchiveResult?
    /// Called on the main thread when an archive finishes.
    @ObservationIgnored var onFinished: ((ArchiveResult) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var control: ArchiveControl?
    @ObservationIgnored private var planning: Task<Void, Never>?

    init(session: ProjectSession, projectName: String) {
        self.session = session
        self.projectName = projectName
        let saved = AppDefaults.store.string(forKey: Self.destinationKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        destination = saved.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        mode = .copy
        replan()
    }

    var isRunning: Bool { stage == .running }

    var canStart: Bool {
        guard stage == .ready || stage == .stopped || isFailure else { return false }
        return mode == .consolidate || destination != nil
    }

    private var isFailure: Bool {
        if case .failed = stage { return true }
        return false
    }

    /// Works out the dry run for the current choice, in the background.
    func replan() {
        guard !isRunning, stage != .done else { return }
        planning?.cancel()
        stage = .planning
        let options = self.options(dryRun: true)
        let session = self.session
        planning = Task { [weak self] in
            do {
                let plan = try await ProjectArchiver.onBackgroundThread {
                    try ProjectArchiver(session: session, options: options).run()
                }
                guard !Task.isCancelled else { return }
                self?.plan = plan
                self?.planProblem = nil
                self?.stage = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self?.plan = nil
                self?.planProblem = ServiceError.wrap(error).message
                self?.stage = .ready
            }
        }
    }

    /// Consolidating plans with the project's own folder; a copy with no
    /// folder chosen yet shows what the project brings in from outside.
    private func options(dryRun: Bool) -> ArchiveOptions {
        let destination = mode == .copy ? self.destination : nil
        return ArchiveOptions(destination: destination, withCache: mode == .copy && withCache, dryRun: dryRun)
    }

    func start() {
        guard canStart else { return }
        if mode == .copy, let destination {
            AppDefaults.store.set(destination.path, forKey: Self.destinationKey)
        }
        planning?.cancel()
        let control = ArchiveControl()
        self.control = control
        stage = .running
        progress = ArchiveProgress(message: "Starting", fraction: 0, filesDone: 0, filesTotal: 0)
        let options = self.options(dryRun: false)
        let session = self.session
        Task { [weak self] in
            do {
                let result = try await ProjectArchiver.onBackgroundThread {
                    try ProjectArchiver(session: session, options: options, control: control, progress: { progress in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress = progress } }
                    }).run()
                }
                self?.result = result
                self?.stage = .done
                self?.onFinished?(result)
            } catch is CancellationError {
                self?.stage = .stopped
            } catch {
                self?.stage = control.isCancelled ? .stopped : .failed(ServiceError.wrap(error).message)
            }
        }
    }

    /// Stops a running archive between chunks. What was copied stays
    /// (hidden), and archiving again carries on from there.
    func stop() {
        control?.cancel()
    }

    func chooseDestination(for window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Archive here"
        panel.message = "Choose where the archive goes. It's a folder named after the project's folder, inside this one."
        panel.directoryURL = destination ?? URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }

    func close() {
        if isRunning { stop() }
        planning?.cancel()
        onClose?()
    }
}

/// Hosts the sheet on a project window.
@MainActor
final class ArchiveSheetController {
    let model: ArchiveSheetModel
    /// Called once the sheet has gone.
    var onDismiss: (() -> Void)?
    private let sheet: NSWindow
    private weak var parent: NSWindow?

    init(model: ArchiveSheetModel, parent: NSWindow) {
        self.model = model
        self.parent = parent
        let hosting = NSHostingController(rootView: ArchiveSheetView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled]
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.backgroundColor = Theme.raised.ns
        model.onClose = { [weak self] in self?.dismiss() }
    }

    func present() {
        parent?.beginSheet(sheet)
    }

    func dismiss() {
        parent?.endSheet(sheet)
        sheet.orderOut(nil)
        onDismiss?()
    }
}

struct ArchiveSheetView: View {
    let model: ArchiveSheetModel

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 0) {
                if model.stage != .done {
                    Row(label: "Archive") {
                        GraphiteSegmented(
                            options: [ArchiveSheetModel.Mode.copy, .consolidate],
                            selected: model.mode,
                            title: { $0 == .copy ? "Copy to another folder" : "Make this folder standalone" },
                            action: { if !model.isRunning { model.mode = $0 } }
                        )
                        .frame(maxWidth: 420)
                    }
                    if model.mode == .copy {
                        Row(label: "Into") {
                            HStack(spacing: 10) {
                                Text(model.destination.map { Self.display($0.path) } ?? "Choose a folder, like the archive share on Bruce")
                                    .foregroundStyle(model.destination == nil ? Theme.textMuted.color : Theme.text.color)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                OutlineButton(title: "Choose…") { model.chooseDestination(for: NSApp.keyWindow) }
                                    .disabled(model.isRunning)
                            }
                        }
                        Row(label: "Cache") {
                            HStack(spacing: 10) {
                                GraphiteSwitch(isOn: model.withCache) { if !model.isRunning { model.withCache.toggle() } }
                                Text("Keep proxies and mattes too. Left out, Tandem makes them again; transcripts always go.")
                                    .font(.ui(11.5))
                                    .foregroundStyle(Theme.textMuted.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                summary
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 14)
            footer
        }
        .frame(width: 640)
        .background(Theme.raised.color)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textMuted.color)
            Text("Archive project")
                .font(.ui(17, .bold))
                .foregroundStyle(Theme.text.color)
            Text(model.projectName)
                .font(.ui(13))
                .foregroundStyle(Theme.textMuted.color)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    // MARK: - What it will do, or did

    @ViewBuilder
    private var summary: some View {
        if let result = model.result, model.stage == .done {
            done(result)
        } else if let problem = model.planProblem {
            Row(label: "Can't archive", divider: false) {
                Text(problem).foregroundStyle(Theme.red.color).fixedSize(horizontal: false, vertical: true)
            }
        } else if let plan = model.plan {
            planned(plan)
        } else {
            Row(label: "Looking", divider: false) {
                Text("Finding the files the project uses…").foregroundStyle(Theme.textMuted.color)
            }
        }
    }

    @ViewBuilder
    private func planned(_ plan: ArchiveResult) -> some View {
        let outside = plan.collected
        Row(label: "From outside") {
            VStack(alignment: .leading, spacing: 3) {
                if outside.isEmpty {
                    Text("Nothing: every file the project uses is in its folder.")
                } else {
                    Text("\(Self.count(outside.count, "file")), \(Self.size(outside.reduce(0) { $0 + $1.bytes })), copied into its folder")
                    ForEach(Array(outside.prefix(5).enumerated()), id: \.offset) { _, file in
                        Text("\(file.path)  ·  \(Self.size(file.bytes))  ·  from \(Self.display(file.original))")
                            .font(.ui(11.5))
                            .foregroundStyle(Theme.textMuted.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if outside.count > 5 {
                        Text("and \(outside.count - 5) more").font(.ui(11.5)).foregroundStyle(Theme.textFaint.color)
                    }
                }
            }
        }
        if model.mode == .copy, model.destination != nil {
            Row(label: "Project folder") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Self.count(plan.folderFiles, "file")), \(Self.size(plan.folderBytes)), to \(Self.display(plan.folder))")
                    let left = plan.leftOut.reduce(Int64(0)) { $0 + $1.bytes }
                    if left > 0 {
                        Text("Leaves out \(Self.size(left)) Tandem can make again (proxies, mattes) or npm can install.")
                            .font(.ui(11.5))
                            .foregroundStyle(Theme.textMuted.color)
                    }
                }
            }
        }
        if !plan.missing.isEmpty {
            Row(label: "Missing") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Self.count(plan.missing.count, "file")) can't be found, so they're left as they are:")
                        .foregroundStyle(Theme.red.color)
                    ForEach(Array(plan.missing.prefix(4).enumerated()), id: \.offset) { _, item in
                        Text(item.kind == .font ? "font \(item.path)" : Self.display(item.path))
                            .font(.ui(11.5))
                            .foregroundStyle(Theme.textMuted.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if plan.missing.count > 4 {
                        Text("and \(plan.missing.count - 4) more").font(.ui(11.5)).foregroundStyle(Theme.textFaint.color)
                    }
                }
            }
        }
        let fonts = plan.fonts.filter { $0.status == .collected }.map(\.family)
        if !fonts.isEmpty {
            Row(label: "Fonts") {
                Text("\(fonts.joined(separator: ", ")) copied into assets/font")
            }
        }
        Row(label: "Total", divider: false) {
            Text(model.mode == .copy && model.destination == nil
                ? "Choose where the copy goes."
                : "\(Self.size(plan.copiedBytes)) to copy. Files on the same drive are cloned, which takes no extra space.")
                .foregroundStyle(Theme.textMuted.color)
        }
    }

    @ViewBuilder
    private func done(_ result: ArchiveResult) -> some View {
        Row(label: "Done", divider: !result.missing.isEmpty) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.mode == .archive
                    ? "Archived to \(Self.display(result.folder))."
                    : "\(model.projectName) is standalone in \(Self.display(result.folder)).")
                    .font(.ui(12.5, .semibold))
                Text("Copied \(Self.count(result.copiedFiles, "file")) (\(Self.size(result.copiedBytes)))\(result.reusedFiles > 0 ? ", \(result.reusedFiles) already there" : ""). archive.json says where each came from.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
            }
        }
        if !result.missing.isEmpty {
            Row(label: "Missing", divider: false) {
                Text("\(Self.count(result.missing.count, "file")) couldn't be found and still point where they did.")
                    .foregroundStyle(Theme.red.color)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            status
            Spacer(minLength: 12)
            if model.stage == .done {
                Button("Show in Finder") {
                    if let result = model.result { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.projectFile)]) }
                }
                .buttonStyle(SheetButtonStyle(prominent: false))
                Button("Done") { model.close() }
                    .buttonStyle(SheetButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            } else if model.isRunning {
                Button("Stop") { model.stop() }
                    .buttonStyle(SheetButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") { model.close() }
                    .buttonStyle(SheetButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button(model.mode == .copy ? "Archive" : "Make standalone") { model.start() }
                    .buttonStyle(SheetButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
                    .opacity(model.canStart ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    @ViewBuilder
    private var status: some View {
        switch model.stage {
        case .running:
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: model.progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.amber.color)
                    .frame(width: 300)
                Text(model.progress.map { "\($0.message)  ·  \($0.filesDone) of \($0.filesTotal) files" } ?? "Starting")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 300, alignment: .leading)
            }
        case .stopped:
            Text("Stopped. Nothing in the project changed; archiving again carries on where it stopped.")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(.ui(11.5))
                .foregroundStyle(Theme.red.color)
                .fixedSize(horizontal: false, vertical: true)
        case .planning:
            Text("Working out what to copy…").font(.ui(11.5)).foregroundStyle(Theme.textMuted.color)
        case .ready, .done:
            EmptyView()
        }
    }

    // MARK: - Words

    static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func display(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory() + "/") ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}

/// A label on the left and what it's about on the right, like the export
/// sheet's rows.
private struct Row<Content: View>: View {
    let label: String
    var divider = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.ui(12.5))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 118, alignment: .leading)
            content()
                .font(.ui(12.5))
                .foregroundStyle(Theme.text.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Theme.border.color).frame(height: 1) }
        }
    }
}

/// The sheet's buttons: amber for the one that goes ahead, outlined for the
/// rest, as in the export sheet.
private struct SheetButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12.5, prominent ? .bold : .regular))
            .foregroundStyle(prominent ? Theme.onAmber.color : Theme.text.color)
            .padding(.horizontal, prominent ? 18 : 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(prominent ? Theme.amber.color : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(prominent ? .clear : Theme.buttonBorder.color, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}
