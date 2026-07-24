import AppKit
import Foundation

final class AppMonitor {
    private static let ignoredBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.SystemUIServer",
        "com.apple.WindowManager",
        "com.mikerosoft.last-window-quits"
    ]

    var onStatusChanged: (() -> Void)?

    private let workspace: NSWorkspace
    private let windowCounter: AccessibilityWindowCounter
    private var decisionEngine = QuitDecisionEngine(gracePeriod: 1)
    private var timer: Timer?
    private var lastAccessibilityGranted: Bool?

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            if !isEnabled {
                // Forget all armed apps. Re-enabling requires seeing a window before
                // a later close can trigger a quit.
                decisionEngine = QuitDecisionEngine(gracePeriod: 1)
            }
            onStatusChanged?()
        }
    }

    init(
        workspace: NSWorkspace = .shared,
        windowCounter: AccessibilityWindowCounter = AccessibilityWindowCounter()
    ) {
        self.workspace = workspace
        self.windowCounter = windowCounter
        if UserDefaults.standard.object(forKey: "isEnabled") == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: "isEnabled")
        }
    }

    func start() {
        AccessibilityPermission.requestIfNeeded()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let accessibilityGranted = AccessibilityPermission.isGranted
        if accessibilityGranted != lastAccessibilityGranted {
            lastAccessibilityGranted = accessibilityGranted
            log("accessibility permission \(accessibilityGranted ? "granted" : "needed")")
            onStatusChanged?()

            if !accessibilityGranted {
                decisionEngine = QuitDecisionEngine(gracePeriod: 1)
            }
        }

        guard isEnabled, accessibilityGranted else {
            return
        }

        let applications = workspace.runningApplications.filter(isEligible)
        var snapshots: [AppSnapshot] = []
        var applicationsByProcessIdentifier: [pid_t: NSRunningApplication] = [:]

        for application in applications {
            guard let windowCount = windowCounter.countWindows(for: application) else {
                // A timeout or inaccessible process is omitted on purpose. It is safer
                // to miss a quit than infer that an unreadable app has no windows.
                continue
            }

            let processIdentifier = application.processIdentifier
            snapshots.append(
                AppSnapshot(
                    processIdentifier: processIdentifier,
                    windowCount: windowCount,
                    isEligible: true
                )
            )
            applicationsByProcessIdentifier[processIdentifier] = application
        }

        let now = ProcessInfo.processInfo.systemUptime
        for processIdentifier in decisionEngine.update(snapshots, now: now) {
            guard let application = applicationsByProcessIdentifier[processIdentifier] else {
                continue
            }

            let name = application.localizedName ?? application.bundleIdentifier ?? "\(processIdentifier)"
            if application.terminate() {
                log("requested quit after last window closed: \(name) pid=\(processIdentifier)")
            } else {
                log("quit request was rejected: \(name) pid=\(processIdentifier)")
            }
        }
    }

    private func isEligible(_ application: NSRunningApplication) -> Bool {
        guard !application.isTerminated,
              application.activationPolicy == .regular,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return false
        }

        guard let bundleIdentifier = application.bundleIdentifier else {
            return true
        }

        return !Self.ignoredBundleIdentifiers.contains(bundleIdentifier)
    }
}
