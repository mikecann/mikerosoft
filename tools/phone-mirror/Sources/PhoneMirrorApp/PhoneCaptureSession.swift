import AVFoundation
import CoreMedia

/// Streams one phone's screen. Runs the capture session on its own queue because
/// `startRunning` blocks until the phone starts sending frames.
final class PhoneCaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()

    /// Called on the main thread whenever the phone's screen size changes (e.g. it rotates).
    var onVideoSize: ((CGSize) -> Void)?
    /// Called on the main thread when the session can't start or stops with an error.
    var onError: ((String) -> Void)?

    private let device: AVCaptureDevice
    private let queue = DispatchQueue(label: "phone-mirror.capture-session")
    private var observers: [NSObjectProtocol] = []

    init(device: AVCaptureDevice) {
        self.device = device
    }

    func start() {
        queue.async { [self] in
            session.beginConfiguration()
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                session.commitConfiguration()
                report("Couldn't open \(device.localizedName): \(error.localizedDescription)")
                return
            }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                report("\(device.localizedName) is busy. Quit other apps that are showing its screen, like QuickTime.")
                return
            }
            session.addInput(input)
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in self?.observe(input) }
            session.startRunning()
            Log.info("started \(device.localizedName) running=\(session.isRunning)")
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        queue.async { [session] in
            session.stopRunning()
        }
    }

    /// Runs on the main thread, like `stop`, so `observers` is only touched there.
    private func observe(_ input: AVCaptureDeviceInput) {
        let center = NotificationCenter.default
        if let port = input.ports.first(where: { $0.mediaType == .video }) {
            observers.append(center.addObserver(
                forName: AVCaptureInput.Port.formatDescriptionDidChangeNotification,
                object: port,
                queue: .main
            ) { [weak self] _ in
                self?.publishVideoSize(of: port)
            })
            publishVideoSize(of: port)
        }
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?(error?.localizedDescription ?? "The phone stopped sending its screen.")
        })
    }

    private func publishVideoSize(of port: AVCaptureInput.Port) {
        guard let description = port.formatDescription else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        guard size.width > 0, size.height > 0 else { return }
        Log.info("\(device.localizedName) video \(Int(size.width))x\(Int(size.height))")
        onVideoSize?(size)
    }

    private func report(_ message: String) {
        Log.info(message)
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}
