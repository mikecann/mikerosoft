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
    @StateObject private var cameraPreviewWindowController = CameraPreviewWindowController()
    @State private var showingEncoderSettings = false

    init(model: RecordingViewModel) {
        self.model = model
        preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if shouldShowRecordingDashboard(isRecording: model.isRecording, isBusy: model.isBusy) {
                recordingDashboard
            } else {
                captureMode
                configuration
            }
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
        .sheet(isPresented: $showingEncoderSettings) {
            EncoderSettingsView(model: model)
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
                Text("Native screen, camera, and audio capture")
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

    private var recordingDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("RECORDING", systemImage: "record.circle.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.red)
                Spacer()
                if let startedAt = model.recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedTime(from: startedAt, to: context.date))
                            .font(.title2.monospacedDigit().weight(.semibold))
                    }
                }
            }

            recordingHealthBanner

            if model.activeTelemetry.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.mode == .audio
                         ? "Waiting for the first written audio sample…"
                         : "Waiting for the first written video sample…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(model.activeTelemetry) { telemetry in
                    recordingSourceCard(telemetry)
                }
            }

            Label(
                model.mode == .audio
                    ? "Record It will stop automatically if the selected input stops supplying audio."
                    : "Record It will stop automatically if video callbacks cease or the encoder stops accepting frames.",
                systemImage: "shield.checkered"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordingHealthBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: healthIcon(model.recordingHealth))
                .foregroundStyle(healthColor(model.recordingHealth))
            VStack(alignment: .leading, spacing: 1) {
                Text(overallHealthTitle(model.recordingHealth))
                    .font(.subheadline.weight(.semibold))
                Text(overallHealthDetail(model.recordingHealth))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(11)
        .background(healthColor(model.recordingHealth).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func recordingSourceCard(_ telemetry: RecordingTelemetry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(telemetry.source.displayName, systemImage: sourceIcon(telemetry.source))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Label(telemetry.healthMessage, systemImage: healthIcon(telemetry.health))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(healthColor(telemetry.health))
            }

            if telemetry.source == .audio {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Input waveform")
                        Spacer()
                        Text("Live")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    AudioWaveformView(levels: telemetry.audioWaveformLevels)
                }

                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                    GridRow {
                        telemetryValue("Audio timeline", formattedMediaDuration(telemetry.mediaDuration))
                        telemetryValue("File size", formattedByteCount(telemetry.fileSizeBytes))
                    }
                    GridRow {
                        telemetryValue("Audio samples written", telemetry.audioSamplesWritten.formatted())
                        telemetryValue("Format", telemetry.codecName)
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                    GridRow {
                        telemetryValue("Video timeline", formattedMediaDuration(telemetry.mediaDuration))
                        telemetryValue("File size", formattedByteCount(telemetry.fileSizeBytes))
                    }
                    GridRow {
                        telemetryValue("Video samples written", telemetry.videoSamplesWritten.formatted())
                        telemetryValue("Audio samples written", telemetry.audioSamplesWritten.formatted())
                    }
                    GridRow {
                        telemetryValue("Output", telemetry.resolutionLabel)
                        telemetryValue("Encoder", telemetry.codecName)
                    }
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "arrow.down.doc.fill")
                Text("Writing \(telemetry.outputFileName)")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(telemetry.outputURL.path)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(healthColor(telemetry.health).opacity(0.35), lineWidth: 1)
        }
    }

    private func telemetryValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            if model.mode.requiresVideoEncoder {
                GridRow {
                    rowLabel("Encoder", systemImage: "slider.horizontal.3")
                    encoderSettingsControl
                }
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
                    microphonePicker(title: "Camera Audio", allowsNone: true)
                }
            }

            if model.mode.capturesAudio {
                GridRow {
                    rowLabel("Audio input", systemImage: "mic")
                    microphonePicker(title: "Audio Input", allowsNone: false)
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
                Text("\(model.selectedEncoder?.codec.displayName ?? "Hardware") · \(display.resolutionLabel) · 30 fps")
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

    private var encoderSettingsControl: some View {
        HStack(spacing: 10) {
            Text(model.encoderSummary)
                .font(.caption)
                .foregroundStyle(model.selectedEncoder == nil ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Settings…") {
                showingEncoderSettings = true
            }
            .disabled(model.availableEncoders.isEmpty || model.isRecording || model.isBusy)
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
        case .audio:
            return "\(baseName)-audio.m4a"
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
            HStack(spacing: 10) {
                Picker("Camera", selection: $model.selectedCameraID) {
                    ForEach(model.cameras) { camera in
                        Text("\(camera.name)  ·  \(camera.resolutionLabel)").tag(camera.id)
                    }
                }
                .labelsHidden()
                .disabled(model.isRecording || model.isBusy || cameraPreviewWindowController.isPreviewOpen)

                Button("Preview…") {
                    if let camera = model.selectedCamera {
                        cameraPreviewWindowController.show(camera: camera)
                    }
                }
                .disabled(cameraPreviewButtonIsDisabled(
                    hasSelectedCamera: model.selectedCamera != nil,
                    isRecording: model.isRecording,
                    isBusy: model.isBusy
                ))
            }

            if let camera = model.selectedCamera {
                HStack(spacing: 5) {
                    Image(systemName: camera.recordsNative4K ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(camera.recordsNative4K
                         ? "Native 4K · \(model.selectedEncoder?.codec.displayName ?? "hardware") · 30 fps"
                         : "This camera cannot supply native 4K at 30 fps")
                }
                .font(.caption)
                .foregroundStyle(camera.recordsNative4K ? Color.secondary : Color.orange)
            }
        }
    }

    private func microphonePicker(title: String, allowsNone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(title, selection: $model.selectedMicrophoneID) {
                if allowsNone {
                    Text("None").tag("")
                }
                ForEach(model.microphones) { microphone in
                    Text(microphone.name).tag(microphone.id)
                }
            }
            .labelsHidden()
            .disabled(model.isRecording || model.isBusy)

            Text(model.selectedMicrophone.map {
                "Records microphone audio from \($0.name)"
            } ?? (allowsNone
                  ? "The camera recording will have no audio track"
                  : "Choose an input device before recording"))
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
            .disabled(recordButtonIsDisabled(
                canRecord: model.canRecord,
                isRecording: model.isRecording,
                isBusy: model.isBusy,
                isCameraPreviewOpen: cameraPreviewWindowController.isPreviewOpen
            ))
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .frame(width: 104, alignment: .leading)
    }

    private func sourceIcon(_ source: CaptureSource) -> String {
        switch source {
        case .screen: "display"
        case .camera: "video"
        case .audio: "waveform"
        }
    }
}

private struct AudioWaveformView: View {
    let levels: [Float]
    private let sampleCapacity = 72

    var body: some View {
        Canvas { context, size in
            var centreLine = Path()
            centreLine.move(to: CGPoint(x: 0, y: size.height / 2))
            centreLine.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(centreLine, with: .color(.secondary.opacity(0.2)), lineWidth: 1)

            let visibleLevels = Array(levels.suffix(sampleCapacity))
            let slotWidth = size.width / CGFloat(sampleCapacity)
            let firstSlot = sampleCapacity - visibleLevels.count
            for (index, rawLevel) in visibleLevels.enumerated() {
                let level = CGFloat(min(1, max(0, rawLevel)))
                let height = max(2, level * (size.height - 10))
                let width = max(1, slotWidth * 0.58)
                let x = (CGFloat(firstSlot + index) + 0.5) * slotWidth - width / 2
                let bar = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: width,
                    height: height
                )
                context.fill(
                    Path(roundedRect: bar, cornerRadius: width / 2),
                    with: .color(.accentColor)
                )
            }
        }
        .frame(height: 64)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live input waveform")
        .accessibilityValue("\(Int((levels.last ?? 0) * 100)) percent")
    }
}

private struct EncoderSettingsView: View {
    @ObservedObject var model: RecordingViewModel
    @ObservedObject private var preferences: RecordingPreferences
    @Environment(\.dismiss) private var dismiss

    init(model: RecordingViewModel) {
        self.model = model
        preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Encoder Settings")
                    .font(.title2.bold())
                Text("Only available H.264 and HEVC hardware encoders are shown.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                GridRow {
                    settingsLabel("Encoder")
                    Picker("Encoder", selection: $preferences.selectedEncoderID) {
                        ForEach(model.availableEncoders) { encoder in
                            Text(encoder.displayName).tag(encoder.id)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    settingsLabel("Rate control")
                    Picker("Rate control", selection: $preferences.rateControl) {
                        ForEach(supportedRateControls) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                rateControlFields
            }

            Text(preferences.rateControl.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Label("Settings are saved automatically", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onChange(of: preferences.selectedEncoderID) {
            preferences.reconcileEncoderSelection(in: model.availableEncoders)
        }
        .onChange(of: preferences.bitRateMbps) {
            if preferences.maximumBitRateMbps < preferences.bitRateMbps {
                preferences.maximumBitRateMbps = preferences.bitRateMbps
            }
        }
    }

    @ViewBuilder
    private var rateControlFields: some View {
        switch preferences.rateControl {
        case .cbr:
            GridRow {
                settingsLabel("Bitrate")
                integerControl(value: $preferences.bitRateMbps, range: 1...500, step: 5, unit: "Mbps")
            }
        case .cqp:
            GridRow {
                settingsLabel("QP level")
                integerControl(value: $preferences.qualityParameter, range: 0...51, step: 1, unit: "lower is better")
            }
        case .vbr:
            GridRow {
                settingsLabel("Target bitrate")
                integerControl(value: $preferences.bitRateMbps, range: 1...500, step: 5, unit: "Mbps")
            }
            GridRow {
                settingsLabel("Maximum bitrate")
                integerControl(
                    value: $preferences.maximumBitRateMbps,
                    range: min(500, max(1, preferences.bitRateMbps))...500,
                    step: 5,
                    unit: "Mbps"
                )
            }
        }
    }

    private var supportedRateControls: [RateControlMode] {
        guard let encoder = model.selectedEncoder else { return [] }
        return RateControlMode.allCases.filter { encoder.supportedRateControls.contains($0) }
    }

    private func settingsLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .frame(width: 118, alignment: .leading)
    }

    private func integerControl(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        unit: String
    ) -> some View {
        HStack(spacing: 8) {
            TextField("Value", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }
}

func recordButtonIsDisabled(
    canRecord: Bool,
    isRecording: Bool,
    isBusy: Bool,
    isCameraPreviewOpen: Bool = false
) -> Bool {
    isBusy || isCameraPreviewOpen || (!canRecord && !isRecording)
}

private func elapsedTime(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
}

private func formattedMediaDuration(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
}

private func formattedByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func healthColor(_ health: RecordingHealth) -> Color {
    switch health {
    case .starting: .secondary
    case .healthy: .green
    case .warning: .orange
    case .failed: .red
    }
}

private func healthIcon(_ health: RecordingHealth) -> String {
    switch health {
    case .starting: "hourglass"
    case .healthy: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .failed: "xmark.octagon.fill"
    }
}

private func overallHealthTitle(_ health: RecordingHealth) -> String {
    switch health {
    case .starting: "Starting capture pipelines"
    case .healthy: "Recording is healthy"
    case .warning: "Recording needs attention"
    case .failed: "Recording has failed"
    }
}

private func overallHealthDetail(_ health: RecordingHealth) -> String {
    switch health {
    case .starting: "Waiting for confirmed media writes"
    case .healthy: "Media samples are reaching the output file"
    case .warning: "Capture activity has slowed; the watchdog is still monitoring it"
    case .failed: "The recording will stop so you do not continue with a broken file"
    }
}
