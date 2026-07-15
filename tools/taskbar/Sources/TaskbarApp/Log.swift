import Foundation

private let logDateFormatter = ISO8601DateFormatter()
private let logDateFormatterLock = NSLock()

func log(_ message: String) {
    logDateFormatterLock.lock()
    let timestamp = logDateFormatter.string(from: Date())
    logDateFormatterLock.unlock()
    let line = "\(timestamp) \(message)\n"
    fputs(line, stderr)
}
