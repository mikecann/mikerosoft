import Foundation

/// Appends to ~/Library/Logs/Phone Mirror/phone-mirror.log so connection problems can be diagnosed later.
enum Log {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Phone Mirror/phone-mirror.log")

    private static let queue = DispatchQueue(label: "phone-mirror.log")
    private static let formatter = ISO8601DateFormatter()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
