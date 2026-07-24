import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class RecordMeetingAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MeetingViewModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRecording else { return .terminateNow }
        Task {
            await model.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
@MainActor
struct RecordMeetingApplication: App {
    @NSApplicationDelegateAdaptor(RecordMeetingAppDelegate.self) private var appDelegate
    @StateObject private var model = MeetingViewModel()

    var body: some Scene {
        WindowGroup("Record Meeting") {
            RecordMeetingView(model: model)
                .onAppear {
                    appDelegate.model = model
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 500, height: 520)
        .windowResizability(.contentSize)

        Settings {
            PreferencesView(model: model)
        }
    }
}

struct RecordMeetingView: View {
    @ObservedObject var model: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FloatingWindowConfigurator()
                .frame(width: 0, height: 0)

            header
            meetingDetails
            recordingState
            controls
            footer
        }
        .padding(24)
        .frame(width: 500)
        .alert(
            "Record Meeting",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("OK") { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "Unknown error")
        }
        .sheet(
            item: Binding(
                get: { model.pendingMeeting },
                set: { _ in }
            )
        ) { meeting in
            MeetingReviewView(model: model, meeting: meeting)
                .interactiveDismissDisabled()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(
                        colors: [.indigo, .red.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 13)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Record Meeting")
                    .font(.title2.bold())
                Text("System audio, microphone, and speaker-labelled notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Preferences")
            .disabled(model.isBusy)
        }
    }

    private var meetingDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Meeting title (optional)", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBusy)
            TextField("Short description of the meeting", text: $model.meetingDescription, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
                .disabled(model.isBusy)
        }
    }

    private var recordingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .fill(model.isRecording ? Color.red : (model.isProcessing ? Color.orange : Color.green))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusMessage)
                        .font(.headline)
                    if let startedAt = model.startedAt, model.isRecording {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(TranscriptDocument.durationString(context.date.timeIntervalSince(startedAt)))
                                .font(.title2.monospacedDigit().bold())
                        }
                    } else if model.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("The window stays above other apps while it is open.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if (model.isRecording || model.isProcessing), !model.recordingWaveform.isEmpty {
                AudioWaveformView(samples: model.recordingWaveform)
                    .frame(height: 46)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.isBusy)

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!model.isRecording)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.preferences.saveDirectory, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
            if let url = model.lastNotionURL {
                Link("Open meeting in Notion", destination: url)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.title = "Record Meeting"
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct PreferencesView: View {
    @ObservedObject var model: MeetingViewModel
    @ObservedObject private var preferences: RecordMeetingPreferences
    @State private var notionToken = ""
    @State private var huggingFaceToken = ""
    @State private var isCreatingDatabase = false
    @State private var message = ""

    init(model: MeetingViewModel) {
        self.model = model
        preferences = model.preferences
    }

    var body: some View {
        Form {
            Section("Files") {
                HStack {
                    TextField("Save recordings to", text: $preferences.saveDirectory)
                    Button("Choose…") { chooseDirectory() }
                }
                TextField("Whisper model", text: $preferences.whisperModel)
            }

            Section("Speaker detection") {
                SecureField("Hugging Face token", text: $huggingFaceToken)
                Text("Requires accepted access to pyannote/speaker-diarization-community-1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notion") {
                Toggle("Publish completed meetings to Notion", isOn: $preferences.autoPublishToNotion)
                SecureField("Notion integration token", text: $notionToken)
                TextField("Parent page URL or ID", text: $preferences.notionParentPage)
                HStack {
                    TextField("Recorded Meetings data source ID", text: $preferences.notionDataSourceID)
                    Button("Create database") {
                        Task { await createDatabase() }
                    }
                    .disabled(isCreatingDatabase)
                }
                if isCreatingDatabase {
                    ProgressView("Creating Recorded Meetings database…")
                } else if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Save secrets") {
                    saveSecrets()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620, height: 530)
        .onAppear {
            notionToken = model.notionToken()
            huggingFaceToken = model.huggingFaceToken()
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: preferences.saveDirectory, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            preferences.saveDirectory = url.path
        }
    }

    private func saveSecrets() {
        do {
            try model.saveSecrets(
                notionToken: notionToken,
                huggingFaceToken: huggingFaceToken
            )
            message = "Preferences saved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func createDatabase() async {
        isCreatingDatabase = true
        message = ""
        do {
            try await model.createNotionDatabase(notionToken: notionToken)
            message = "Recorded Meetings database created and connected."
        } catch {
            message = error.localizedDescription
        }
        isCreatingDatabase = false
    }
}
