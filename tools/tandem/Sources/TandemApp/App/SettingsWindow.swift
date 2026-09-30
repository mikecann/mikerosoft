import AppKit
import SwiftUI
import TandemAPI
import TandemAssets
import TandemCore

/// Tandem > Settings…: where the shared library is, and the sound each type
/// of transition plays. One window, reused.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var current: SettingsWindowController?

    static func show() {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.raised.ns
        window.isReleasedWhenClosed = false
        let controller = SettingsWindowController(window: window)
        window.delegate = controller
        current = controller
        window.center()
        controller.showWindow(nil)
        AssetLibraryHost.shared.open()
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

struct SettingsView: View {
    @State private var message: String?

    private var host: AssetLibraryHost { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: Icons.sharedLibrary)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textMuted.color)
                Text("Shared library")
                    .font(.ui(15, .bold))
                    .foregroundStyle(Theme.text.color)
            }
            Text("One folder of stickers, graphics, sound effects, music, looks, fonts and saved segments that every project can use. Drop files into its folders and they show up in the library tabs. Projects use these files where they are; archiving a project copies the ones it uses into it.")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(host.sharedRoot.map { ArchiveSheetView.display($0.path) } ?? "Opening the library…")
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.text.color)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                OutlineButton(title: "Show in Finder") {
                    if let root = host.sharedRoot { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field.color))
            HStack(spacing: 10) {
                OutlineButton(title: "Choose another folder…") { choose() }
                if let root = host.sharedRoot, root.standardizedFileURL.path != SharedLibrary.standardRoot.standardizedFileURL.path {
                    OutlineButton(title: "Use ~/Movies/Tandem Library") { move(to: nil) }
                }
                Spacer()
            }
            Text("Choosing a folder doesn't move your files: move them in Finder first, then choose where they are. Tandem makes its folders in the one you choose.")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textFaint.color)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.amber.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.sheetDivider.color).frame(height: 1).padding(.vertical, 4)
            TransitionSoundSettingsView()
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.raised.color)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Choose the folder to keep the shared library in."
        panel.directoryURL = host.sharedRoot?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        move(to: url)
    }

    private func move(to folder: URL?) {
        message = "Moving…"
        host.moveSharedLibrary(to: folder) { message = $0 }
    }
}

/// The sound each type of transition plays when it's added (dropped on a
/// cut, double-clicked in Effects, Cmd-D for a dissolve, or given as a new
/// type): a row per type with a picker, over Tandem's own (a light swoosh
/// for push, slide, cut slide and wipe, and none for the rest).
struct TransitionSoundSettingsView: View {
    var settings = TransitionSoundActions.settings
    @State private var picks: [String: String] = [:]
    @State private var choices: [Asset] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: Icons.transition)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textMuted.color)
                Text("Transition sounds")
                    .font(.ui(15, .bold))
                    .foregroundStyle(Theme.text.color)
            }
            Text("The sound effect each type of transition plays when you add one: it goes on SFX as a clip of its own, peaking in the middle of the transition, and moves and goes with it. A transition's own sound can be changed in the inspector.")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(TransitionType.allCases, id: \.self) { type in
                    row(type)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field.color))
        }
        .onAppear { picks = settings.choices }
        .task { choices = await TransitionSoundActions.choices() }
    }

    private func row(_ type: TransitionType) -> some View {
        let picked = picks[type.rawValue]
        let current = picked ?? TransitionSoundDefaults.builtIn(type)?.assetID ?? ""
        let own = TransitionSoundDefaults.builtIn(type)?.assetID ?? ""
        return HStack(spacing: 10) {
            Text(type.displayName)
                .font(.ui(12.5))
                .foregroundStyle(Theme.text.color)
                .frame(width: 110, alignment: .leading)
            Menu(TransitionSoundText.name(of: current, choices: choices).capitalisedFirst + (picked == nil ? " (Tandem's)" : "")) {
                Button("Tandem's: \(TransitionSoundText.name(of: own, choices: choices))") { pick(nil, for: type) }
                Button("None") { pick("", for: type) }
                if !choices.isEmpty {
                    Divider()
                    Section("Sound effects") {
                        ForEach(choices, id: \.id) { asset in
                            Button(asset.name) { pick(asset.id, for: type) }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tip("What a \(type.displayName.lowercased()) plays when it's added: Tandem's own, none, or a favourite or recently used sound effect from the library")
            IconButton(symbol: "play.fill", help: "Hear it", enabled: !current.isEmpty) {
                TransitionSoundActions.preview(current)
            }
        }
    }

    private func pick(_ assetID: String?, for type: TransitionType) {
        settings.set(assetID, for: type)
        picks = settings.choices
    }
}

private extension String {
    var capitalisedFirst: String { prefix(1).uppercased() + dropFirst() }
}
