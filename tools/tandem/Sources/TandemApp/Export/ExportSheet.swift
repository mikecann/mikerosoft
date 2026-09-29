import AppKit
import SwiftUI
import TandemCore
import TandemRender

/// The export sheet: presets on the left, what they'll do on the right, and
/// the output file. It drops from the top bar over a dimmed window, as in
/// the design. Presets resolve through `ExportPreset.plan(for:)`, as they
/// do for the CLI: each keeps the timeline's shape, and the sheet opens on
/// the one that fits the timeline.
struct ExportSheetOverlay: View {
    let model: EditorModel
    /// Nil until Mike picks one: the preset that fits the timeline.
    @State private var presetIndex: Int?
    @State private var useRange = false
    @State private var output: URL?

    static let presets = ExportPreset.all

    init(model: EditorModel, initialPreset: Int? = nil) {
        self.model = model
        _presetIndex = State(initialValue: initialPreset)
    }

    private var presets: [ExportPreset] { Self.presets }
    private var selectedIndex: Int { min(presetIndex ?? Self.defaultIndex(settings: model.project.settings), presets.count - 1) }
    private var preset: ExportPreset { presets[selectedIndex] }
    private var plan: Result<ExportPlan, ExportPlanError> { Self.plan(preset, settings: model.project.settings) }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.dimmer.color
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 0) {
                    presetList
                    Rectangle().fill(Theme.sheetDivider.color).frame(width: 1)
                    settings
                }
                .fixedSize(horizontal: false, vertical: true)
                if !model.exports.jobs.isEmpty {
                    ExportJobList(model: model)
                }
                footer
            }
            .frame(width: 800)
            .background(Theme.raised.color)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
            .overlay(
                UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                    .stroke(Theme.controlBorder.color, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            .padding(.top, Theme.Metrics.topBarHeight)
        }
        .onAppear {
            useRange = model.inOutRange != nil
            output = defaultOutput()
        }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Export")
                .font(.ui(17, .bold))
                .foregroundStyle(Theme.text.color)
            Text("\(model.project.name) · \(Timecode.clock(model.project.duration.seconds))")
                .font(.ui(13))
                .foregroundStyle(Theme.textMuted.color)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                let selected = index == selectedIndex
                Button {
                    presetIndex = index
                    output = defaultOutput()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.ui(13, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.text.color : Theme.textStrong.color)
                        Text(Self.detail(preset, settings: model.project.settings))
                            .font(.ui(11.5))
                            .foregroundStyle(selected ? Theme.textMuted.color : Theme.textFaint.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.presetSelected.color : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .top)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch plan {
            case .success(let plan):
                SheetRow(label: "Video") {
                    Text(verbatim: "\(plan.codec.displayName) on the hardware encoder, \(ExportPlan.megabits(plan.videoBitrate))")
                }
                SheetRow(label: "Size") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: Self.sizeText(plan, settings: model.project.settings))
                        if let note = Self.upscaleNote(plan, settings: model.project.settings) {
                            Text(verbatim: note)
                                .font(.ui(11.5))
                                .foregroundStyle(Theme.amber.color)
                        }
                    }
                }
            case .failure(let problem):
                SheetRow(label: "Short") {
                    Text(verbatim: Self.problem(problem))
                        .foregroundStyle(Theme.amber.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SheetRow(label: "Loudness") {
                VStack(alignment: .leading, spacing: 3) {
                    if let target = preset.loudnessTarget {
                        Text(String(format: "Master to %.0f LUFS, peaks under %.0f dB", target, preset.truePeakCeiling ?? -1).replacingOccurrences(of: "-", with: "−"))
                    } else {
                        Text("Left as mixed")
                    }
                    Text("Measured during the export")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                }
            }
            SheetRow(label: "Range") {
                GraphiteSegmented(
                    options: [false, true],
                    selected: useRange,
                    title: { ranged in
                        if ranged, let range = model.inOutRange {
                            return "In to out · \(Timecode.clock(range.duration.seconds))"
                        }
                        return ranged ? "In to out (none set)" : "Whole timeline"
                    },
                    action: { ranged in
                        if !ranged || model.inOutRange != nil { useRange = ranged }
                    }
                )
                .frame(maxWidth: 330)
            }
            SheetRow(label: "Save to", divider: false) {
                HStack(spacing: 10) {
                    Text(displayPath(output ?? defaultOutput()))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    OutlineButton(title: "Choose…") { chooseOutput() }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(estimate.title)
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Theme.text.color)
                Text(estimate.detail)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
            }
            Spacer()
            Button(action: close) {
                Text("Cancel")
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.text.color)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.buttonBorder.color, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Button(action: export) {
                Text("Export")
                    .font(.ui(12.5, .bold))
                    .foregroundStyle(Theme.onAmber.color)
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.amber.color))
                    .opacity(canExport ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canExport)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    // MARK: - Actions

    private func close() {
        model.showExportSheet = false
    }

    private var canExport: Bool {
        if case .success = plan { return true }
        return false
    }

    private func export() {
        // The plan carries the frame, size and bitrate the sheet showed.
        guard case .success(let plan) = plan else { return }
        var chosen = plan.preset
        if useRange, let range = model.inOutRange { chosen.range = range }
        let url = output ?? defaultOutput()
        let context = RenderContext(project: model.project, folder: model.folder, analysis: model.session.analysis, useProxies: false, format: plan.format)
        model.exports.enqueue(preset: chosen, output: url, context: context)
        model.show(.info, "Exporting \(url.lastPathComponent).")
        close()
    }

    private func defaultOutput() -> URL {
        let folder = model.folder.exportsFolder
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        // The preset that fits the timeline is the plain export.
        let fits = selectedIndex == Self.defaultIndex(settings: model.project.settings)
        let name = VersionNaming.exportName(projectFile: model.fileName, preset: fits ? "" : preset.name, existing: existing)
        return folder.appendingPathComponent(name)
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        let url = output ?? defaultOutput()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        if panel.runModal() == .OK, let chosen = panel.url { output = chosen }
    }

    private func displayPath(_ url: URL) -> String {
        let root = model.folder.root.deletingLastPathComponent().path
        let path = url.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// How long it should take, from the speed of the last export.
    private var estimate: (title: String, detail: String) {
        let seconds = (useRange ? model.inOutRange?.duration : nil)?.seconds ?? model.project.duration.seconds
        let speed = AppDefaults.store.double(forKey: ExportSpeed.defaultsKey)
        guard speed > 0 else {
            return ("\(Timecode.clock(seconds)) of video", "Runs in the background; the status bar shows progress.")
        }
        let wall = seconds / speed
        let minutes = Int(wall / 60)
        let rest = Int(wall.truncatingRemainder(dividingBy: 60))
        let title = minutes > 0 ? "About \(minutes) min \(rest) s" : "About \(max(rest, 1)) s"
        return (title, String(format: "Measured on this Mac: %.1f× realtime", speed))
    }

    // MARK: - Descriptions

    /// The preset that fits the timeline (`ExportPreset.standard(for:)`).
    static func defaultIndex(settings: ProjectSettings) -> Int {
        let standard = ExportPreset.standard(for: settings)
        return presets.firstIndex { $0.name == standard.name } ?? 0
    }

    /// What the preset makes of the project, or why it can't export it.
    static func plan(_ preset: ExportPreset, settings: ProjectSettings) -> Result<ExportPlan, ExportPlanError> {
        do {
            return .success(try preset.plan(for: settings))
        } catch let error as ExportPlanError {
            return .failure(error)
        } catch {
            return .failure(.noFormat(id: preset.format ?? OutputFrames.main, known: settings.alternateFormats.map(\.id)))
        }
    }

    static func fps(_ rate: FrameRate) -> String {
        let value = rate.framesPerSecond
        return value == value.rounded() ? "\(Int(value))" : String(format: "%.2f", value)
    }

    /// The line under each preset's name.
    static func detail(_ preset: ExportPreset, settings: ProjectSettings) -> String {
        switch plan(preset, settings: settings) {
        case .success(let plan):
            return "\(plan.codec.displayName) · \(plan.width)×\(plan.height) · \(fps(settings.frameRate))p"
        case .failure(.noPortrait):
            return "No 9:16 layout yet"
        case .failure:
            return "No such layout"
        }
    }

    /// The Size row: the frame, and how it compares with the timeline.
    static func sizeText(_ plan: ExportPlan, settings: ProjectSettings) -> String {
        let size = "\(plan.width) × \(plan.height), \(fps(settings.frameRate)) fps"
        let frame = "\(plan.frameWidth) × \(plan.frameHeight)"
        if let id = plan.format, plan.width == plan.frameWidth, plan.height == plan.frameHeight {
            let name = settings.alternateFormats.first { $0.id == id }?.name ?? id
            return "\(size), the timeline's \(name) layout"
        }
        if plan.isUpscaled { return "\(size), upscaled from the \(frame) timeline" }
        if plan.width < plan.frameWidth || plan.height < plan.frameHeight { return "\(size), scaled down from the \(frame) timeline" }
        return "\(size), same as the timeline"
    }

    /// Under an upscale: it adds nothing, and the preset that keeps the size.
    static func upscaleNote(_ plan: ExportPlan, settings: ProjectSettings) -> String? {
        guard plan.isUpscaled else { return nil }
        var note = "No sharper than the timeline."
        let standard = ExportPreset.standard(for: settings, format: plan.format)
        if standard.name != plan.preset.name, let fits = try? standard.plan(for: settings, format: plan.format), !fits.isUpscaled {
            note += " \(standard.name) exports it at \(fits.width) × \(fits.height)."
        }
        return note
    }

    /// Why the preset can't export this project, in the sheet's words.
    static func problem(_ error: ExportPlanError) -> String {
        switch error {
        case .noPortrait:
            return "This project has no 9:16 layout for the short yet. An agent can lay one out with `tandem short --apply`, with the screen on top and the camera below."
        case .noFormat:
            return error.description
        }
    }
}

/// Remembers how fast exports run, for the next estimate.
enum ExportSpeed {
    static let defaultsKey = "exportSpeed"

    static func record(_ result: ExportResult) {
        guard result.elapsed > 0.5, result.duration.seconds > 1 else { return }
        AppDefaults.store.set(result.duration.seconds / result.elapsed, forKey: defaultsKey)
    }
}

private struct SheetRow<Content: View>: View {
    let label: String
    var divider = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.ui(12.5))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 120, alignment: .leading)
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

/// Exports in this session with their state.
private struct ExportJobList: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This session")
                    .font(.ui(11.5, .semibold))
                    .foregroundStyle(Theme.textMuted.color)
                Spacer()
                if model.exports.jobs.contains(where: \.isFinished) {
                    Button("Clear finished") { model.exports.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                }
            }
            ForEach(model.exports.jobs.suffix(4)) { job in
                HStack(spacing: 10) {
                    Text(job.output.lastPathComponent)
                        .font(.ui(12))
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.state(job))
                        .font(.ui(11.5))
                        .foregroundStyle(Self.colour(job).color)
                        .lineLimit(1)
                    if case .done = job.state {
                        OutlineButton(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([job.output]) }
                    } else if !job.isFinished {
                        OutlineButton(title: "Cancel") { model.exports.cancel(job.id) }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    static func state(_ job: ExportJob) -> String {
        switch job.state {
        case .queued: return "Queued"
        case .running(let progress): return "\(Int(progress * 100))%"
        case .done(let result):
            let lufs = result.integratedLUFS.map { String(format: " · %.1f LUFS", $0).replacingOccurrences(of: "-", with: "−") } ?? ""
            return "Done in \(Int(result.elapsed)) s\(lufs)"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }

    static func colour(_ job: ExportJob) -> Swatch {
        switch job.state {
        case .failed: return Theme.red
        case .done: return Theme.green
        case .running: return Theme.amber
        default: return Theme.textMuted
        }
    }
}
