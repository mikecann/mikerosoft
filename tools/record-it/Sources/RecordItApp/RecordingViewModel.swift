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
    @Published private(set) var captureProblems: [CaptureProblem] = []
    @Published private(set) var pendingProblemAlert: CaptureProblem?

    let preferences: RecordingPreferences

    private let projectCatalog: ProjectCatalog
    private let displayProvider: () -> [CaptureDisplay]
    private var activeSession: RecordingSession?
    private var activeRecoveryAudio: RecoveryAudioRecording?
    private var activeOutputURLs: [URL] = []
    private var activeTakeName: String?
    private var activeOutputDirectory: URL?
    private var diskSpaceMonitor: Task<Void, Never>?

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
            let requestedBaseName = resolvedFileName
        else { return }
        isBusy = true
        statusMessage = "Starting…"
        recordingTelemetry = [:]
        captureProblems = []
        pendingProblemAlert = nil
        let startedAt = Date()

        do {
            let outputDirectory = try prepareOutputDirectory(for: destination)
            if let freeBytes = availableRecordingBytes(at: outputDirectory),
               freeBytes < minimumFreeRecordingBytes {
                throw RecordItError.message(
                    "Only \(formattedFreeSpace(freeBytes)) is free on the recording disk. "
                        + "Free at least \(formattedFreeSpace(minimumFreeRecordingBytes)) before recording."
                )
            }
            let recoveryDirectory = recoveryAudioDirectory()
            try cleanupExpiredRecoveryAudio(in: recoveryDirectory)
            let recordingMode = mode
            let outputBaseName = availableRecordingBaseName(requestedBaseName) { candidate in
                let urls = Array(recordingOutputURLs(
                    mode: recordingMode,
                    directory: outputDirectory,
                    startedAt: startedAt,
                    baseName: candidate
                ).values) + [
                    recoveryAudioURL(baseName: candidate, directory: recoveryDirectory),
                    outputDirectory.appendingPathComponent(captureProblemReportName(candidate))
                ]
                return urls.contains { FileManager.default.fileExists(atPath: $0.path) }
            }
            fileName = outputBaseName
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
                    onProblem: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleCaptureProblem(error, source: .recoveryAudio)
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
                        onProblem: { [weak self] error in
                            Task { @MainActor [weak self] in
                                self?.handleCaptureProblem(error, source: .screen)
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
                        onProblem: { [weak self] error in
                            Task { @MainActor [weak self] in
                                self?.handleCaptureProblem(error, source: .camera)
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
                        onProblem: { [weak self] error in
                            Task { @MainActor [weak self] in
                                self?.handleCaptureProblem(error, source: .audio)
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
            activeTakeName = outputBaseName
            activeOutputDirectory = outputDirectory
            recordingStartedAt = startedAt
            isRecording = true
            startDiskSpaceMonitor(for: outputDirectory)
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
        diskSpaceMonitor?.cancel()
        diskSpaceMonitor = nil
        acknowledgeProblem()

        var stopError: Error?
        do {
            try await activeSession.stop()
        } catch {
            stopError = error
        }
        do {
            try await activeRecoveryAudio?.stop()
        } catch {
            // The backup track failing to close never invalidates the main files.
            RecordingDiagnostics.shared.log("recovery-audio.stop error=\(error.localizedDescription)")
        }

        let completedURLs = activeOutputURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        let reportURL = writeProblemReport()
        let problemCount = captureProblems.count
        resetActiveRecording()
        resetFileName()

        if let stopError {
            statusMessage = "Recording stopped with an error"
            presentedError = stopErrorMessage(stopError, savedFiles: completedURLs)
        } else if problemCount > 0 {
            statusMessage = "Saved with \(problemCount) problem\(problemCount == 1 ? "" : "s") noted"
        } else {
            statusMessage = "Saved \(completedURLs.count == 1 ? "recording" : "recordings")"
        }
        if revealInFinder && preferences.openFinderAfterRecording && !completedURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(completedURLs + [reportURL].compactMap { $0 })
        }
        isBusy = false
    }

    /// Keeps the take running and makes the problem impossible to miss. The
    /// user decides whether to carry on, because stopping on their behalf has
    /// thrown away good takes over false alarms.
    private func handleCaptureProblem(_ error: Error, source: CaptureSource) {
        raiseProblem(
            sourceName: source.displayName,
            message: error.localizedDescription,
            soundsAlarm: source != .recoveryAudio
        )
    }

    private func raiseProblem(sourceName: String, message: String, soundsAlarm: Bool) {
        guard isRecording, !isBusy, let recordingStartedAt else { return }
        let problem = CaptureProblem(
            sourceName: sourceName,
            message: message,
            takeTime: Date().timeIntervalSince(recordingStartedAt),
            soundsAlarm: soundsAlarm
        )
        captureProblems.append(problem)
        RecordingDiagnostics.shared.log(
            "take.problem at=\(problem.timecode) source=\(sourceName) alarm=\(soundsAlarm) error=\(message)"
        )
        guard soundsAlarm else { return }
        pendingProblemAlert = problem
        CriticalRecordingAlarm.shared.start()
    }

    func acknowledgeProblem() {
        CriticalRecordingAlarm.shared.stop()
        pendingProblemAlert = nil
    }

    private func startDiskSpaceMonitor(for directory: URL) {
        diskSpaceMonitor = Task { [weak self] in
            var warned = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                guard let freeBytes = availableRecordingBytes(at: directory) else { continue }
                if freeBytes < minimumFreeRecordingBytes / 2, !warned {
                    warned = true
                    raiseProblem(
                        sourceName: "Disk",
                        message: "Only \(formattedFreeSpace(freeBytes)) left on the recording disk. "
                            + "Stop soon or the files will stop growing.",
                        soundsAlarm: true
                    )
                }
            }
        }
    }

    private func writeProblemReport() -> URL? {
        guard
            !captureProblems.isEmpty,
            let activeTakeName,
            let activeOutputDirectory
        else { return nil }
        let url = activeOutputDirectory.appendingPathComponent(captureProblemReportName(activeTakeName))
        do {
            try captureProblemReport(takeName: activeTakeName, problems: captureProblems)
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            RecordingDiagnostics.shared.log("take.problem-report error=\(error.localizedDescription)")
            return nil
        }
    }

    private func stopErrorMessage(_ error: Error, savedFiles: [URL]) -> String {
        guard !savedFiles.isEmpty else { return error.localizedDescription }
        let names = savedFiles.map(\.lastPathComponent).joined(separator: ", ")
        return "\(error.localizedDescription)\n\nThese files were still saved: \(names)"
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

    private func resetActiveRecording() {
        activeSession = nil
        activeRecoveryAudio = nil
        activeOutputURLs = []
        activeTakeName = nil
        activeOutputDirectory = nil
        recordingTelemetry = [:]
        recordingStartedAt = nil
        isRecording = false
    }
}

func captureProblemReportName(_ takeName: String) -> String {
    "\(takeName)-problems.txt"
}

func formattedFreeSpace(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
