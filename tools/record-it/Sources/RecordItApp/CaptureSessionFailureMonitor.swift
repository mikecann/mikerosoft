import AVFoundation
import Foundation

final class CaptureSessionFailureMonitor: @unchecked Sendable {
    private let session: AVCaptureSession
    private let deviceIDs: Set<String>
    private let notificationCenter: NotificationCenter
    private let onFailure: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    init(
        session: AVCaptureSession,
        deviceIDs: Set<String>,
        notificationCenter: NotificationCenter = .default,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.session = session
        self.deviceIDs = deviceIDs
        self.notificationCenter = notificationCenter
        self.onFailure = onFailure
    }

    func start() {
        lock.withLock {
            guard observers.isEmpty else { return }
            observers = [
                notificationCenter.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification,
                    object: session,
                    queue: nil
                ) { [weak self] notification in
                    let underlying = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                    let detail = underlying?.localizedDescription ?? "Unknown AVFoundation runtime error."
                    self?.report("The capture session reported a runtime error: \(detail)")
                },
                notificationCenter.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification,
                    object: session,
                    queue: nil
                ) { [weak self] _ in
                    self?.report("The capture session was interrupted and can no longer be trusted.")
                },
                notificationCenter.addObserver(
                    forName: AVCaptureDevice.wasDisconnectedNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] notification in
                    guard
                        let self,
                        let device = notification.object as? AVCaptureDevice,
                        self.deviceIDs.contains(device.uniqueID)
                    else { return }
                    self.report("The capture device '\(device.localizedName)' was disconnected.")
                }
            ]
        }
    }

    func stop() {
        let removed = lock.withLock { () -> [NSObjectProtocol] in
            defer { observers = [] }
            return observers
        }
        for observer in removed {
            notificationCenter.removeObserver(observer)
        }
    }

    private func report(_ message: String) {
        onFailure(RecordItError.message(message))
    }

    deinit {
        stop()
    }
}
