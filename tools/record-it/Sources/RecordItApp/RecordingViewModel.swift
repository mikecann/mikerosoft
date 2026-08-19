import AppKit
import Combine
import Foundation

func defaultProjectsRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    homeDirectory.appendingPathComponent("dev/convex/convex-videos", isDirectory: true)
}

func recordingPrerequisitesAreAvailable(
    mode: RecordingMode,
    screenCaptureTargetKind: ScreenCaptureTargetKind,
    hasDestination: Bool,
    hasValidFileName: Bool,
    hasVideoEncoder: Bool,
    hasDisplay: Bool,
    hasWindow: Bool,
    hasCamera: Bool,
    hasAudioInput: Bool,
    hasRecoveryAudioInput: Bool = true,
    isBusy: Bool
) -> Bool {
    guard hasDestination, hasValidFileName, !isBusy else { return false }
    if mode.requiresVideoEncoder && !hasVideoEncoder { return false }
    if mode.capturesScreen {
        switch screenCaptureTargetKind {
        case .display where !hasDisplay: return false
        case .window where !hasWindow: return false
        default: break
        }
    }
    if mode.capturesCamera && !hasCamera { return false }
    if (mode.capturesCamera || mode.capturesAudio), !hasAudioInput { return false }
    if (mode.capturesCamera || mode.capturesAudio), !hasRecoveryAudioInput { return false }
    return true
}

@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var mode: RecordingMode {
        didSet { preferences.recordingMode = mode }
    }
    @Published private(set) var destinations: [ProjectDestination] = []
    @Published var selectedDestinationID = ""
    @Published private(set) var displays: [CaptureDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID = 0
    @Published var screenCaptureTargetKind: ScreenCaptureTargetKind = .display
    @Published private(set) var windows: [CaptureWindow] = []
    @Published var selectedWindowID: CGWindowID = 0
    @Published private(set) var isRefreshingWindows = false
    @Published private(set) var cameras: [CaptureCamera] = []
    @Published var selectedCameraID = ""
    @Published private(set) var microphones: [CaptureAudioDevice] = []
    @Published var selectedMicrophoneID = ""
    @Published private(set) var availableEncoders: [HardwareVideoEncoder] = []
    @Published var fileName = defaultRecordingBaseName(startedAt: Date())
    @Published var screenAudioSource: ScreenAudioSource = .systemSound
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var statusMessage = "Loading devices…"
    @Published private(set) var recordingTelemetry: [CaptureSource: RecordingTelemetry] = [:]
    @Published var presentedError: String?
    @Published private(set) var criticalFailureMessage: String?

    let preferences: RecordingPreferences

    private let projectCatalog: ProjectCatalog
    private let displayProvider: () -> [CaptureDisplay]
    private var activeSession: RecordingSession?
    private var activeRecoveryAudio: RecoveryAudioRecording?
    private var activeOutputURLs: [URL] = []

    init(
        preferences: RecordingPreferences = RecordingPreferences(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        displayProvider: @escaping () -> [CaptureDisplay] = CaptureDeviceCatalog.displays
    ) {
        self.preferences = preferences
        self.displayProvider = displayProvider
        mode = preferences.recordingMode
        projectCatalog = ProjectCatalog(
            projectsRoot: defaultProjectsRoot(homeDirectory: homeDirectory),
            fallbackOutputRoot: homeDirectory.appendingPathComponent("Movies/record-it-output", isDirectory: true)
        )
    }

    var selectedDestination: ProjectDestination? {
        destinations.first { $0.id == selectedDestinationID }
    }

    var selectedDisplay: CaptureDisplay? {
        displays.first { $0.id == selectedDisplayID }
    }

    var selectedWindow: CaptureWindow? {
        windows.first { $0.id == selectedWindowID }
    }

    var selectedScreenCaptureTarget: ScreenCaptureTarget? {
        switch screenCaptureTargetKind {
        case .display: selectedDisplay.map(ScreenCaptureTarget.display)
        case .window: selectedWindow.map(ScreenCaptureTarget.window)
        }
    }

    var selectedCamera: CaptureCamera? {
        cameras.first { $0.id == selectedCameraID }
    }

    var selectedMicrophone: CaptureAudioDevice? {
        microphones.first { $0.id == selectedMicrophoneID }
    }

    var recoveryMicrophone: CaptureAudioDevice? {
        guard let selectedMicrophone else { return nil }
        return preferredRecoveryAudioDevice(primaryID: selectedMicrophone.id, in: microphones)
    }

    var resolvedFileName: String? {
        normalizedRecordingBaseName(fileName)
    }

    var selectedEncoder: HardwareVideoEncoder? {
        availableEncoders.first { $0.id == preferences.selectedEncoderID }
    }

    var encoderConfiguration: EncoderConfiguration? {
        guard let encoder = selectedEncoder else { return nil }
        return EncoderConfiguration(
            encoder: encoder,
            rateControl: preferences.rateControl,
            bitRateMbps: preferences.bitRateMbps,
            maximumBitRateMbps: max(preferences.bitRateMbps, preferences.maximumBitRateMbps),
            qualityParameter: preferences.qualityParameter
        )
    }

    var encoderSummary: String {
        encoderConfiguration?.summary ?? "No compatible hardware encoder found"
    }

    var canRecord: Bool {
        recordingPrerequisitesAreAvailable(
            mode: mode,
            screenCaptureTargetKind: screenCaptureTargetKind,
            hasDestination: selectedDestination != nil,
            hasValidFileName: resolvedFileName != nil,
            hasVideoEncoder: encoderConfiguration != nil,
            hasDisplay: selectedDisplay != nil,
            hasWindow: selectedWindow != nil,
            hasCamera: selectedCamera != nil,
            hasAudioInput: selectedMicrophone != nil,
            hasRecoveryAudioInput: recoveryMicrophone != nil,
            isBusy: isBusy
        )
    }

    var activeTelemetry: [RecordingTelemetry] {
        [.screen, .camera, .audio].compactMap { recordingTelemetry[$0] }
    }

    var recordingHealth: RecordingHealth {
        overallRecordingHealth(activeTelemetry.map(\.health))
    }

    func load() async {
        isBusy = true
        defer { isBusy = false }

        availableEncoders = HardwareVideoEncoderCatalog.availableEncoders()
        preferences.reconcileEncoderSelection(in: availableEncoders)

        do {
            destinations = try projectCatalog.destinations()
            selectedDestinationID = destinations.first?.id ?? ""
        } catch {
            presentedError = "Projects could not be loaded: \(error.localizedDescription)"
        }

        cameras = CaptureDeviceCatalog.cameras()
        selectedCameraID = preferredCamera(in: cameras)?.id ?? ""

        microphones = CaptureDeviceCatalog.microphones()
        selectedMicrophoneID = preferredAudioDevice(in: microphones)?.id ?? ""

        refreshDisplays()
        statusMessage = displays.isEmpty ? "No displays found" : "Ready to record"
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func resetFileName(at date: Date = Date(), timeZone: TimeZone = .current) {
        fileName = defaultRecordingBaseName(startedAt: date, timeZone: timeZone)
    }

    func refreshDisplaysAfterSystemChange() {
        refreshDisplays()
        if !isRecording {
            statusMessage = displays.isEmpty ? "No displays found" : "Ready to record"
        }
    }

    func refreshWindows() async {
        guard !isRefreshingWindows, !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            presentedError = "Screen Recording access is required to list windows. Enable Record It in Privacy & Security → Screen & System Audio Recording, then relaunch the app."
            return
        }

        isRefreshingWindows = true
        defer { isRefreshingWindows = false }
        let previousID = selectedWindowID
        do {
            windows = try await CaptureDeviceCatalog.windows()
            selectedWindowID = windows.first(where: { $0.id == previousID })?.id
                ?? windows.first?.id
                ?? 0
        } catch {
            windows = []
            selectedWindowID = 0
            presentedError = "Windows could not be loaded: \(error.localizedDescription)"
        }
    }

    func startRecording() async {
        guard
            canRecord,
            let destination = selectedDestination,
            let outputBaseName = resolvedFileName
        else { return }
        isBusy = true
        statusMessage = "Starting…"
        recordingTelemetry = [:]
        let startedAt = Date()
        fileName = outputBaseName

        do {
            let outputDirectory = try prepareOutputDirectory(for: destination)
            let recoveryDirectory = recoveryAudioDirectory()
            try cleanupExpiredRecoveryAudio(in: recoveryDirectory)
            let outputs = recordingOutputURLs(
                mode: mode,
                directory: outputDirectory,
                startedAt: startedAt,
                baseName: outputBaseName
            )
            var recorders: [any CaptureRecording] = []
            let startGate = mode == .both ? RecordingStartGate() : nil
            var recoveryAudio: RecoveryAudioRecording?

            if mode.capturesCamera || mode.capturesAudio {
                guard let recoveryMicrophone else {
                    throw RecordItError.message(
                        "A separate MacBook Pro microphone is required for recovery audio. "
                            + "Record It will not begin without an independent backup input."
                    )
                }
                let recoveryURL = recoveryAudioURL(
                    baseName: outputBaseName,
                    directory: recoveryDirectory
                )
                recoveryAudio = RecoveryAudioRecording(
                    device: recoveryMicrophone,
                    outputURL: recoveryURL,
                    onFailure: { [weak self] error in
                        Task { @MainActor [weak self] in
                            await self?.handleCaptureFailure(error, source: .recoveryAudio)
                        }
                    }
                )
                activeRecoveryAudio = recoveryAudio
                try await recoveryAudio?.start()
            }

            if mode.capturesScreen {
                guard
                    let captureTarget = selectedScreenCaptureTarget,
                    let outputURL = outputs[.screen],
                    let encoderConfiguration
                else {
                    throw RecordItError.message("Choose a display or window before recording.")
                }
                recorders.append(
                    ScreenRecorder(
                        target: captureTarget,
                        audioSource: screenAudioSource,
                        outputURL: outputURL,
                        encoderConfiguration: encoderConfiguration,
                        startGate: startGate,
                        onFailure: { [weak self] error in
                            Task { @MainActor [weak self] in
                                await self?.handleCaptureFailure(error, source: .screen)
                            }
                        },
                        onTelemetry: { [weak self] telemetry in
                            Task { @MainActor [weak self] in
                                self?.recordingTelemetry[.screen] = telemetry
                            }
                        }
                    )
                )
            }
            if mode.capturesCamera {
                guard
                    let camera = selectedCamera,
                    let outputURL = outputs[.camera],
                    let encoderConfiguration
                else {
                    throw RecordItError.message("Choose a camera before recording.")
                }
                recorders.append(
                    CameraRecorder(
                        camera: camera,
                        microphone: selectedMicrophone,
                        outputURL: outputURL,
                        encoderConfiguration: encoderConfiguration,
                        startGate: startGate,
                        onFailure: { [weak self] error in
                            Task { @MainActor [weak self] in
                                await self?.handleCaptureFailure(error, source: .camera)
                            }
                        },
                        onTelemetry: { [weak self] telemetry in
                            Task { @MainActor [weak self] in
                                self?.recordingTelemetry[.camera] = telemetry
                            }
                        }
                    )
                )
            }
            if mode.capturesAudio {
                guard let audioDevice = selectedMicrophone, let outputURL = outputs[.audio] else {
                    throw RecordItError.message("Choose an audio input before recording.")
                }
                recorders.append(
                    AudioRecorder(
                        audioDevice: audioDevice,
                        outputURL: outputURL,
                        onFailure: { [weak self] error in
                            Task { @MainActor [weak self] in
                                await self?.handleCaptureFailure(error, source: .audio)
                            }
                        },
                        onTelemetry: { [weak self] telemetry in
                            Task { @MainActor [weak self] in
                                self?.recordingTelemetry[.audio] = telemetry
                            }
                        }
                    )
                )
            }

            let session = RecordingSession(recorders: recorders, startGate: startGate)
            do {
                try await session.start()
            } catch {
                try? await recoveryAudio?.stop()
                activeRecoveryAudio = nil
                throw error
            }
            activeSession = session
            activeOutputURLs = Array(outputs.values)
            recordingStartedAt = startedAt
            isRecording = true
            statusMessage = mode == .audio ? "Recording audio" : "Recording at 30 fps"
        } catch {
            activeSession = nil
            if let activeRecoveryAudio {
                try? await activeRecoveryAudio.stop()
                self.activeRecoveryAudio = nil
            }
            activeOutputURLs = []
            presentedError = error.localizedDescription
            statusMessage = "Ready to record"
        }
        isBusy = false
    }

    func stopRecording(revealInFinder: Bool = true) async {
        guard let activeSession else { return }
        isBusy = true
        statusMessage = "Finishing files…"

        do {
            try await activeSession.stop()
            try await activeRecoveryAudio?.stop()
            let completedURLs = activeOutputURLs
            resetActiveRecording()
            resetFileName()
            statusMessage = "Saved \(completedURLs.count == 1 ? "recording" : "recordings")"
            if revealInFinder && preferences.openFinderAfterRecording {
                NSWorkspace.shared.activateFileViewerSelecting(completedURLs)
            }
        } catch {
            try? await activeRecoveryAudio?.stop()
            resetActiveRecording()
            resetFileName()
            statusMessage = "Recording stopped with an error"
            presentedError = error.localizedDescription
        }
        isBusy = false
    }

    private func refreshDisplays(preferredName: String? = nil) {
        let previousID = selectedDisplayID
        let previousName = preferredName ?? selectedDisplay?.name
        displays = displayProvider()
        selectedDisplayID = displays.first(where: { $0.id == previousID })?.id
            ?? displays.first(where: { $0.name == previousName })?.id
            ?? preferredDisplay(in: displays)?.id
            ?? 0
    }

    private func handleCaptureFailure(_ error: Error, source: CaptureSource) async {
        guard isRecording, !isBusy else { return }
        let message = criticalCaptureFailureMessage(
            source: source,
            reason: error.localizedDescription,
            recoveryAudioURL: activeRecoveryAudio?.outputURL
        )
        criticalFailureMessage = message
        statusMessage = "RECORDING FAILED. STOPPING NOW."
        CriticalRecordingAlarm.shared.start()
        await stopRecording(revealInFinder: false)
        // stopRecording can surface a finalization error, but the capture
        // failure is the primary warning and must remain impossible to miss.
        presentedError = nil
        criticalFailureMessage = message
        statusMessage = "RECORDING FAILED. VIDEO AND AUDIO ARE NOT COMPLETE."
    }

    func dismissCriticalFailure() {
        CriticalRecordingAlarm.shared.stop()
        criticalFailureMessage = nil
        statusMessage = "Ready to record"
    }

    private func resetActiveRecording() {
        activeSession = nil
        activeRecoveryAudio = nil
        activeOutputURLs = []
        recordingTelemetry = [:]
        recordingStartedAt = nil
        isRecording = false
    }
}

func criticalCaptureFailureMessage(
    source: CaptureSource,
    reason: String,
    recoveryAudioURL: URL? = nil
) -> String {
    var message = "\(source.displayName.uppercased()) CAPTURE FAILED. RECORDING STOPPED. "
        + "VIDEO AND AUDIO ARE NOT COMPLETE. Do not continue this take. \(reason)"
    if let recoveryAudioURL {
        message += " Recovery audio may be available at: \(recoveryAudioURL.path)"
    }
    return message
}
