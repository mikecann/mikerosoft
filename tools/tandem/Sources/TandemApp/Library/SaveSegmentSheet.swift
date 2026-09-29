import AppKit
import SwiftUI
import TandemAPI
import TandemAssets
import TandemCore
import TandemMedia

/// What saving a selection as a segment starts from: a name, the titles
/// that could ask for their words when it goes in, and a line saying what
/// it holds. Kept apart from the sheet so it can be tested.
struct SegmentSaveSetup: Equatable {
    struct Title: Equatable, Identifiable {
        var id: String { clipID }
        var clipID: String
        /// The words the title has now, the field's default.
        var text: String
        /// What it's called when it's asked for.
        var label: String
        var asked = false
    }

    var name: String
    var titles: [Title]
    /// "4 clips, 3 s, on Graphics, Text and SFX, playing 2 files".
    var summary: String

    /// For the selected clips, in timeline order.
    static func make(clipIDs: [String], in project: Project) -> SegmentSaveSetup {
        let clips = clipIDs.compactMap { project.clip($0) }
        var titles: [Title] = []
        for clip in clips {
            guard case .text(let text) = clip.content else { continue }
            titles.append(Title(clipID: clip.id, text: text.text, label: clip.name ?? "Text \(titles.count + 1)"))
        }
        let start = clips.map(\.start).min() ?? .zero
        let end = clips.map(\.end).max() ?? .zero
        var tracks: [String] = []
        for id in clipIDs {
            guard let track = project.track(containingClip: id), !tracks.contains(track.name) else { continue }
            tracks.append(track.name)
        }
        let files = Set(clips.compactMap(\.mediaID)).count
        var summary = "\(clips.count == 1 ? "1 clip" : "\(clips.count) clips"), \(SegmentLibraryText.seconds(end - start)), on \(list(tracks))"
        if files > 0 { summary += ", playing \(files == 1 ? "1 file" : "\(files) files")" }
        return SegmentSaveSetup(name: defaultName(titles), titles: titles, summary: summary)
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// The first title's first line, or "Segment".
    static func defaultName(_ titles: [Title]) -> String {
        let line = titles.first?.text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty, !line.contains("{{") else { return "Segment" }
        return String(line.prefix(40))
    }

    /// The fields to ask for.
    var fields: [SegmentMaker.Field] {
        titles.filter(\.asked).map { SegmentMaker.Field(clipID: $0.clipID, label: $0.label.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.label) }
    }
}


/// Timeline > Save selection as segment…: names the selected clips, picks
/// which titles ask for their words when it goes in, and saves it into the
/// shared library's Segments folder with copies of the files it plays.
@MainActor
@Observable
final class SaveSegmentModel {
    enum Stage: Equatable {
        case editing, saving
        /// A segment of that name is there; saving again replaces it.
        case exists
        case failed(String)
    }

    @ObservationIgnored let project: Project
    @ObservationIgnored let folder: ProjectFolder
    @ObservationIgnored let clipIDs: [String]
    @ObservationIgnored let library: SharedLibrary
    var setup: SegmentSaveSetup {
        didSet { if setup.name != oldValue.name, stage == .exists { stage = .editing } }
    }
    private(set) var stage: Stage = .editing
    @ObservationIgnored var onSaved: ((StoredSegment) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    /// Where a replaced segment goes; the Trash unless a test says.
    @ObservationIgnored var discard: (@Sendable (URL) throws -> Void)?

    init(project: Project, folder: ProjectFolder, clipIDs: [String], library: SharedLibrary) {
        self.project = project
        self.folder = folder
        self.clipIDs = clipIDs
        self.library = library
        setup = SegmentSaveSetup.make(clipIDs: clipIDs, in: project)
    }

    var canSave: Bool {
        stage != .saving && !SegmentStore.folderName(for: setup.name).isEmpty
    }

    /// Where it will go, for the sheet.
    var destination: String {
        ArchiveSheetView.display(library.segmentsFolder.appendingPathComponent(SegmentStore.folderName(for: setup.name)).path)
    }

    func save() {
        guard canSave else { return }
        let replace = stage == .exists
        let draft: SegmentMaker.Draft
        do {
            let library = AssetLibraryHost.shared.library
            draft = try SegmentMaker.draft(
                name: setup.name, clipIDs: clipIDs, in: project, folder: folder, fields: setup.fields,
                assets: SegmentMaker.AssetLookup(project: project, library: library), assetsRoot: library?.root ?? AssetLibrary.root()
            )
        } catch {
            stage = .failed(ServiceError.wrap(error).message)
            return
        }
        var store = SegmentStore(library: library)
        if let discard { store.discard = discard }
        if !replace, FileManager.default.fileExists(atPath: store.folder.appendingPathComponent(SegmentStore.folderName(for: setup.name)).path) {
            stage = .exists
            return
        }
        stage = .saving
        let saver = store
        Task { [weak self] in
            do {
                let stored = try await ProjectArchiver.onBackgroundThread { try saver.save(draft, replace: replace) }
                self?.stage = .editing
                self?.onSaved?(stored)
                self?.onClose?()
            } catch {
                self?.stage = .failed(ServiceError.wrap(error).message)
            }
        }
    }

    func close() {
        onClose?()
    }
}

/// Hosts the sheet on a project window.
@MainActor
final class SaveSegmentSheetController {
    let model: SaveSegmentModel
    /// Called once the sheet has gone.
    var onDismiss: (() -> Void)?
    private let sheet: NSWindow
    private weak var parent: NSWindow?

    init(model: SaveSegmentModel, parent: NSWindow) {
        self.model = model
        self.parent = parent
        let hosting = NSHostingController(rootView: SaveSegmentView(model: model))
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

struct SaveSegmentView: View {
    @Bindable var model: SaveSegmentModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.ui(12.5)).foregroundStyle(Theme.textMuted.color)
                    TextField("", text: $model.setup.name, prompt: Text("Intro").foregroundStyle(Theme.textFaint.color))
                        .textFieldStyle(.plain)
                        .font(.ui(13))
                        .foregroundStyle(Theme.text.color)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field.color))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.fieldBorder.color, lineWidth: 1))
                        .focused($nameFocused)
                        .onSubmit { model.save() }
                    Text("\(model.setup.summary). Saved to \(model.destination), with copies of its files, so it works in any project.")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.setup.titles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Words that change each time").font(.ui(12.5)).foregroundStyle(Theme.textMuted.color)
                        Text("Mark a title whose words change each time it's used, like a section name. Agents fill it in when they add the segment; in the app it goes in with the words it has now, ready to edit in the inspector.")
                            .font(.ui(11.5))
                            .foregroundStyle(Theme.textFaint.color)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach($model.setup.titles) { $title in
                            HStack(spacing: 10) {
                                GraphiteSwitch(isOn: title.asked) { title.asked.toggle() }
                                Text("\u{201C}\(title.text.replacingOccurrences(of: "\n", with: " "))\u{201D}")
                                    .font(.ui(12))
                                    .foregroundStyle(Theme.text.color)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if title.asked {
                                    TextField("", text: $title.label, prompt: Text("Its name, like Section").foregroundStyle(Theme.textFaint.color))
                                        .textFieldStyle(.plain)
                                        .font(.ui(12))
                                        .foregroundStyle(Theme.text.color)
                                        .padding(.horizontal, 8)
                                        .frame(width: 150, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field.color))
                                        .help("What agents call these words when they fill them in. The words now are what it starts with.")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            footer
        }
        .frame(width: 520)
        .background(Theme.raised.color)
        .onAppear { nameFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textMuted.color)
            Text("Save as segment")
                .font(.ui(17, .bold))
                .foregroundStyle(Theme.text.color)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch model.stage {
            case .exists:
                Text("There's already a segment called \u{201C}\(SegmentStore.folderName(for: model.setup.name))\u{201D}. Replace it? The old one goes to the Trash.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.amber.color)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.red.color)
                    .fixedSize(horizontal: false, vertical: true)
            case .saving:
                Text("Copying its files…").font(.ui(11.5)).foregroundStyle(Theme.textMuted.color)
            case .editing:
                EmptyView()
            }
            Spacer(minLength: 12)
            Button("Cancel") { model.close() }
                .buttonStyle(SegmentSheetButtonStyle(prominent: false))
                .keyboardShortcut(.cancelAction)
            Button(model.stage == .exists ? "Replace" : "Save") { model.save() }
                .buttonStyle(SegmentSheetButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .opacity(model.canSave ? 1 : 0.5)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }
}

/// Amber for the button that goes ahead, outlined for the rest, as in the
/// export and archive sheets.
private struct SegmentSheetButtonStyle: ButtonStyle {
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
