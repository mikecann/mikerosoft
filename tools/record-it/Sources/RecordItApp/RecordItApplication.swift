import AppKit
import SwiftUI

@MainActor
final class RecordItAppDelegate: NSObject, NSApplicationDelegate {
    weak var recordingModel: RecordingViewModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recordingModel, recordingModel.isRecording else {
            return .terminateNow
        }

        Task {
            await recordingModel.stopRecording(revealInFinder: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
@MainActor
struct RecordItApplication: App {
    @NSApplicationDelegateAdaptor(RecordItAppDelegate.self) private var appDelegate
    @StateObject private var model = RecordingViewModel()

    var body: some Scene {
        WindowGroup("Record It") {
            RecordItView(model: model)
                .onAppear {
                    appDelegate.recordingModel = model
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 580, height: 720)
        .windowResizability(.contentSize)
    }
}

struct RecordItView: View {
    @ObservedObject var model: RecordingViewModel
    @ObservedObject private var preferences: RecordingPreferences

    init(model: RecordingViewModel) {
        self.model = model
        preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            captureMode
            configuration
            Divider()
            footer
        }
        .padding(26)
        .frame(width: 580)
        .task {
            await model.load()
        }
        .alert(
            "Record It",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("OK") { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.red, Color(red: 0.72, green: 0.05, blue: 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Record It")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Native screen and camera capture")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var captureMode: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("RECORD")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Record", selection: $model.mode) {
                ForEach(RecordingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRecording || model.isBusy)
        }
    }

    private var configuration: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                rowLabel("Project", systemImage: "folder")
                projectPicker
            }

            GridRow {
                rowLabel("File name", systemImage: "doc")
                fileNameEditor
            }

            if model.mode.capturesScreen {
                GridRow {
                    rowLabel("Screen", systemImage: "display")
                    displayPicker
                }

                GridRow {
                    rowLabel("Screen audio", systemImage: "speaker.wave.2")
                    screenAudioPicker
                }
            }

            if model.mode.capturesCamera {
                GridRow {
                    rowLabel("Camera", systemImage: "video")
                    cameraPicker
                }

                GridRow {
                    rowLabel("Camera audio", systemImage: "mic")
                    microphonePicker
                }
            }

            GridRow {
                Color.clear.frame(width: 104, height: 1)
                Toggle("Open Finder after recording", isOn: $preferences.openFinderAfterRecording)
                    .disabled(model.isRecording || model.isBusy)
            }
        }
    }

    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Project", selection: $model.selectedDestinationID) {
                ForEach(model.destinations) { destination in
                    Text(destination.displayName).tag(destination.id)
                }
            }
            .labelsHidden()
            .disabled(model.isRecording || model.isBusy)

            if let outputDirectory = model.selectedDestination?.outputDirectory {
                Text(outputDirectory.path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path,
                    with: "~"
                ))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }

    private var displayPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Screen", selection: $model.selectedDisplayID) {
                ForEach(model.displays) { display in
                    Text("\(display.name)  ·  \(display.resolutionLabel)").tag(display.id)
                }
            }
            .labelsHidden()
            .disabled(model.isRecording || model.isBusy)

            if let display = model.selectedDisplay {
                Text("HEVC · \(display.resolutionLabel) · 30 fps")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = display.upscalingWarning {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var fileNameEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("File name", text: $model.fileName)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isRecording || model.isBusy)

            if let preview = outputNamePreview {
                Text(preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Enter a file name without / or :")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var outputNamePreview: String? {
        guard let baseName = model.resolvedFileName else { return nil }
        switch model.mode {
        case .screen:
            return "\(baseName)-screen.mov"
        case .camera:
            return "\(baseName)-camera.mov"
        case .both:
            return "\(baseName)-screen.mov + \(baseName)-camera.mov"
        }
    }

    private var screenAudioPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Screen Audio", selection: $model.screenAudioSource) {
                ForEach(ScreenAudioSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .labelsHidden()
            .disabled(model.isRecording || model.isBusy)

            Text(model.screenAudioSource.capturesSystemAudio
                 ? "Captures music, videos, and other Mac playback, not a microphone"
                 : "The screen recording will have no audio track")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cameraPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Camera", selection: $model.selectedCameraID) {
                ForEach(model.cameras) { camera in
                    Text("\(camera.name)  ·  \(camera.resolutionLabel)").tag(camera.id)
                }
            }
            .labelsHidden()
            .disabled(model.isRecording || model.isBusy)

            if let camera = model.selectedCamera {
                HStack(spacing: 5) {
                    Image(systemName: camera.recordsNative4K ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(camera.recordsNative4K
                         ? "Native 4K · HEVC · 30 fps"
                         : "This camera cannot supply native 4K at 30 fps")
                }
                .font(.caption)
                .foregroundStyle(camera.recordsNative4K ? Color.secondary : Color.orange)
            }
        }
    }

    private var microphonePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Camera Audio", selection: $model.selectedMicrophoneID) {
                Text("None").tag("")
                ForEach(model.microphones) { microphone in
                    Text(microphone.name).tag(microphone.id)
                }
            }
            .labelsHidden()
            .disabled(model.isRecording || model.isBusy)

            Text(model.selectedMicrophone.map {
                "Records microphone audio from \($0.name)"
            } ?? "The camera recording will have no audio track")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.secondary.opacity(0.45))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusMessage)
                        .font(.subheadline.weight(.medium))
                    if let startedAt = model.recordingStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsedTime(from: startedAt, to: context.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            Button {
                Task { await model.toggleRecording() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                    Text(model.isRecording ? "Stop Recording" : "Start Recording")
                }
                .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!model.canRecord && !model.isRecording)
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .frame(width: 104, alignment: .leading)
    }
}

private func elapsedTime(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
}
