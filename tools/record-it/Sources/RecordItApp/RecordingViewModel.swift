import AppKit
import Combine
import Foundation

@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var mode: RecordingMode = .both
    @Published private(set) var destinations: [ProjectDestination] = []
    @Published var selectedDestinationID = ""
    @Published private(set) var displays: [CaptureDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID = 0
    @Published private(set) var cameras: [CaptureCamera] = []
    @Published var selectedCameraID = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var statusMessage = "Loading devices…"
    @Published var presentedError: String?

    let preferences: RecordingPreferences

    private let projectCatalog: ProjectCatalog
    private var activeSession: RecordingSession?
    private var activeOutputURLs: [URL] = []

    init(
        preferences: RecordingPreferences = RecordingPreferences(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.preferences = preferences
        projectCatalog = ProjectCatalog(
            projectsRoot: homeDirectory.appendingPathComponent("Movies/Projects", isDirectory: true),
            fallbackOutputRoot: homeDirectory.appendingPathComponent("Movies/record-it-output", isDirectory: true)
        )
    }

    var selectedDestination: ProjectDestination? {
        destinations.first { $0.id == selectedDestinationID }
    }

    var selectedDisplay: CaptureDisplay? {
        displays.first { $0.id == selectedDisplayID }
    }

    var selectedCamera: CaptureCamera? {
        cameras.first { $0.id == selectedCameraID }
    }

    var canRecord: Bool {
        guard selectedDestination != nil, !isBusy else { return false }
        if mode.capturesScreen && selectedDisplay == nil { return false }
        if mode.capturesCamera && selectedCamera == nil { return false }
        return true
    }

    func load() async {
        isBusy = true
        defer { isBusy = false }

        do {
            destinations = try projectCatalog.destinations()
            selectedDestinationID = destinations.first?.id ?? ""
        } catch {
            presentedError = "Projects could not be loaded: \(error.localizedDescription)"
        }

        cameras = CaptureDeviceCatalog.cameras()
        selectedCameraID = preferredCamera(in: cameras)?.id ?? ""

        displays = CaptureDeviceCatalog.displays()
        selectedDisplayID = preferredDisplay(in: displays)?.id ?? 0
        statusMessage = displays.isEmpty ? "No displays found" : "Ready to record"
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        guard canRecord, let destination = selectedDestination else { return }
        isBusy = true
        statusMessage = "Starting…"
        let startedAt = Date()

        do {
            let outputDirectory = try prepareOutputDirectory(for: destination)
            let outputs = recordingOutputURLs(
                mode: mode,
                directory: outputDirectory,
                startedAt: startedAt
            )
            var recorders: [any CaptureRecording] = []
            let startGate = mode == .both ? RecordingStartGate() : nil

            if mode.capturesScreen {
                guard let display = selectedDisplay, let outputURL = outputs[.screen] else {
                    throw RecordItError.message("Choose a display before recording.")
                }
                recorders.append(
                    ScreenRecorder(display: display, outputURL: outputURL, startGate: startGate)
                )
            }
            if mode.capturesCamera {
                guard let camera = selectedCamera, let outputURL = outputs[.camera] else {
                    throw RecordItError.message("Choose a camera before recording.")
                }
                recorders.append(
                    CameraRecorder(camera: camera, outputURL: outputURL, startGate: startGate)
                )
            }

            let session = RecordingSession(recorders: recorders, startGate: startGate)
            try await session.start()
            activeSession = session
            activeOutputURLs = Array(outputs.values)
            recordingStartedAt = startedAt
            isRecording = true
            statusMessage = "Recording at 30 fps"
        } catch {
            activeSession = nil
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
            let completedURLs = activeOutputURLs
            resetActiveRecording()
            statusMessage = "Saved \(completedURLs.count == 1 ? "recording" : "recordings")"
            if revealInFinder && preferences.openFinderAfterRecording {
                NSWorkspace.shared.activateFileViewerSelecting(completedURLs)
            }
        } catch {
            resetActiveRecording()
            statusMessage = "Recording stopped with an error"
            presentedError = error.localizedDescription
        }
        isBusy = false
    }

    private func resetActiveRecording() {
        activeSession = nil
        activeOutputURLs = []
        recordingStartedAt = nil
        isRecording = false
    }
}
