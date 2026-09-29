import os

/// Notice and above are kept by the unified log long enough to diagnose a
/// meeting after the fact:
/// `log show --predicate 'subsystem == "com.mikerosoft.meeting-archive"' --last 1d`
enum Log {
    static let capture = Logger(subsystem: "com.mikerosoft.meeting-archive", category: "capture")
    static let detector = Logger(subsystem: "com.mikerosoft.meeting-archive", category: "detector")
    static let controller = Logger(subsystem: "com.mikerosoft.meeting-archive", category: "controller")
    static let transfer = Logger(subsystem: "com.mikerosoft.meeting-archive", category: "transfer")
}
