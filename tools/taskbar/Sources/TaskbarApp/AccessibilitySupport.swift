import ApplicationServices
import Foundation

let taskbarAccessibilityMessagingTimeout: Float = 0.25

@discardableResult
func setTaskbarAccessibilityMessagingTimeout(_ element: AXUIElement) -> AXError {
    AXUIElementSetMessagingTimeout(element, taskbarAccessibilityMessagingTimeout)
}

func configureTaskbarAccessibilityMessagingTimeout() {
    setTaskbarAccessibilityMessagingTimeout(AXUIElementCreateSystemWide())
}

private let accessibilityWindowActionQueue = DispatchQueue(
    label: "mikerosoft.taskbar.accessibility-actions",
    qos: .userInitiated
)

func performAccessibilityWindowAction(_ name: String, _ action: @escaping () -> Void) {
    accessibilityWindowActionQueue.async {
        TaskbarPerformanceDiagnostics.measure(name, threshold: 0.15, action)
    }
}
