import AppKit
import AVFoundation
import SwiftUI

protocol CameraPreviewSessionControlling: AnyObject {
    var session: AVCaptureSession { get }

    func start(cameraID: String) async throws
    func stop() async
}

enum CameraPreviewState: Equatable {
    case idle
    case starting
    case running
    case stopping
    case failed(String)
}

@MainActor
final class CameraPreviewModel: ObservableObject {
    @Published private(set) var state: CameraPreviewState = .idle

    let cameraID: String
    private let controller: any CameraPreviewSessionControlling
    private var stopRequested = false

    init(
        cameraID: String,
        controller: any CameraPreviewSessionControlling = SystemCameraPreviewSessionController()
    ) {
        self.cameraID = cameraID
        self.controller = controller
    }

    var session: AVCaptureSession { controller.session }

    func start() async {
        guard state != .running, state != .starting else { return }
        stopRequested = false
        state = .starting

        do {
            try await controller.start(cameraID: cameraID)
            guard !stopRequested, !Task.isCancelled else {
                await controller.stop()
                state = .idle
                return
            }
            state = .running
        } catch {
            state = stopRequested || Task.isCancelled
                ? .idle
                : .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard state != .idle, state != .stopping else { return }
        stopRequested = true
        state = .stopping
        await controller.stop()
        state = .idle
    }
}

final class SystemCameraPreviewSessionController: CameraPreviewSessionControlling, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.mikerosoft.record-it.camera-preview")
    private var configuredCameraID: String?

    func start(cameraID: String) async throws {
        guard await requestCameraPreviewAccess() else {
            throw RecordItError.message(
                "Camera access is required. Enable it in Privacy & Security → Camera."
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    if configuredCameraID != cameraID {
                        try configureSession(cameraID: cameraID)
                    }
                    if !session.isRunning {
                        session.startRunning()
                    }
                    guard session.isRunning else {
                        throw RecordItError.message("The camera preview could not be started.")
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    private func configureSession(cameraID: String) throws {
        guard let device = CaptureDeviceCatalog.camera(withID: cameraID) else {
            throw RecordItError.message("The selected camera is no longer available.")
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecordItError.message("The selected camera could not be added to the preview.")
        }
        session.addInput(input)
        configuredCameraID = cameraID
    }
}

@MainActor
struct CameraPreviewSheet: View {
    let camera: CaptureCamera

    @StateObject private var model: CameraPreviewModel
    @State private var isClosing = false
    @Environment(\.dismiss) private var dismiss

    init(camera: CaptureCamera) {
        self.camera = camera
        _model = StateObject(wrappedValue: CameraPreviewModel(cameraID: camera.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Camera Preview")
                        .font(.title2.bold())
                    Text(camera.name)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                previewStatus
            }

            ZStack {
                CameraPreviewSurface(session: model.session)
                    .accessibilityLabel("Live camera preview for \(camera.name)")

                switch model.state {
                case .idle, .starting:
                    ProgressView("Starting camera…")
                        .padding(16)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash.fill")
                            .font(.system(size: 30))
                        Text(message)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task { await model.start() }
                        }
                    }
                    .frame(maxWidth: 360)
                    .padding(22)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
                case .running, .stopping:
                    EmptyView()
                }
            }
            .foregroundStyle(.white)
            .frame(width: 800, height: 450)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Text("Preview only. Nothing is being recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isClosing ? "Closing…" : "Done") {
                    isClosing = true
                    Task {
                        await model.stop()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isClosing)
            }
        }
        .padding(24)
        .task { await model.start() }
        .onDisappear {
            Task { await model.stop() }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var previewStatus: some View {
        switch model.state {
        case .running:
            Label("Live", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle, .starting, .stopping:
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct CameraPreviewSurface: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.session = session
    }
}

private final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    var session: AVCaptureSession? {
        get { previewLayer.session }
        set { previewLayer.session = newValue }
    }

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

func cameraPreviewButtonIsDisabled(
    hasSelectedCamera: Bool,
    isRecording: Bool,
    isBusy: Bool
) -> Bool {
    !hasSelectedCamera || isRecording || isBusy
}

private func requestCameraPreviewAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        true
    case .notDetermined:
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    case .denied, .restricted:
        false
    @unknown default:
        false
    }
}
