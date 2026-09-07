import AppKit
import ApplicationServices

// Workspace events cover switching apps; AX focus events cover switching
// windows within one app. The existing one-second poll remains the fallback.
final class TaskbarFocusMonitor {
    private let center: NotificationCenter
    private let observeAccessibility: Bool
    private let onChange: () -> Void
    private var tokens: [NSObjectProtocol] = []
    private var observer: AXObserver?
    private var observedPID: pid_t?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         observeAccessibility: Bool = true, onChange: @escaping () -> Void) {
        self.center = center
        self.observeAccessibility = observeAccessibility
        self.onChange = onChange
    }

    func start() {
        guard tokens.isEmpty else { return }
        let events = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                      NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                      NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification]
        tokens = events.map { event in
            center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.updateFocusedApplication()
                self?.onChange()
            }
        }
        updateFocusedApplication()
    }

    func updateFocusedApplication() {
        guard observeAccessibility, AXIsProcessTrusted() else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard pid != observedPID else { return }
        removeAccessibilityObserver()
        guard let pid else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<TaskbarFocusMonitor>.fromOpaque(context).takeUnretainedValue().onChange()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, app, kAXFocusedWindowChangedNotification as CFString, context) == .success else { return }
        observer = created
        observedPID = pid
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func removeAccessibilityObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = nil
    }

    func stop() {
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
        removeAccessibilityObserver()
    }

    deinit { stop() }
}
