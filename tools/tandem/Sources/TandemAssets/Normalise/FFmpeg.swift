import Foundation

/// The ffmpeg command line tool, for the formats AVFoundation can't read
/// (WebM with alpha, Ogg audio).
public struct FFmpeg: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Finds ffmpeg: `TANDEM_FFMPEG`, then the PATH, then the usual install
    /// folders. Apps opened from the Finder get a minimal PATH, so the
    /// folders matter.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> FFmpeg? {
        var candidates: [String] = []
        if let explicit = environment["TANDEM_FFMPEG"], !explicit.isEmpty { candidates.append(explicit) }
        for folder in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(folder)/ffmpeg")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return FFmpeg(url: URL(fileURLWithPath: path))
        }
        return nil
    }

    /// ffprobe from the same folder, if it's there.
    public var ffprobe: URL? {
        let url = self.url.deletingLastPathComponent().appendingPathComponent("ffprobe")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Runs ffmpeg and waits. Throws with the end of its error output.
    public func run(_ arguments: [String]) throws {
        _ = try Self.execute(url, arguments)
    }

    /// The streams of a file as ffprobe reports them.
    func probeStreams(_ file: URL) throws -> [[String: Any]] {
        guard let ffprobe else { return [] }
        let output = try Self.execute(ffprobe, ["-v", "error", "-show_streams", "-of", "json", file.path])
        let json = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        return json?["streams"] as? [[String: Any]] ?? []
    }

    private static func execute(_ tool: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain both pipes before waiting so a chatty tool can't block on a
        // full pipe.
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AssetError.normaliseFailed("\(tool.lastPathComponent) failed (\(process.terminationStatus)): \(message.suffix(500))")
        }
        return outputData
    }
}
