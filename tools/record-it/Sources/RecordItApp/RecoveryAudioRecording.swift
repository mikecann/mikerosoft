import Foundation

let recoveryAudioRetention: TimeInterval = 14 * 24 * 60 * 60

func recoveryAudioDirectory(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    homeDirectory.appendingPathComponent(
        "Library/Application Support/Record It/Recovery Audio",
        isDirectory: true
    )
}

func recoveryAudioURL(baseName: String, directory: URL) -> URL {
    directory.appendingPathComponent("\(baseName)-backup-audio.caf")
}

func preferredRecoveryAudioDevice(
    primaryID: String,
    in devices: [CaptureAudioDevice]
) -> CaptureAudioDevice? {
    let alternatives = devices.filter { $0.id != primaryID }
    return alternatives.first {
        $0.name.localizedCaseInsensitiveContains("MacBook Pro Microphone")
    }
}

func cleanupExpiredRecoveryAudio(
    in directory: URL,
    now: Date = Date(),
    retention: TimeInterval = recoveryAudioRetention,
    fileManager: FileManager = .default
) throws {
    guard fileManager.fileExists(atPath: directory.path) else { return }
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
    for url in try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) where url.lastPathComponent.hasSuffix("-backup-audio.caf") {
        let values = try url.resourceValues(forKeys: keys)
        guard
            values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate,
            now.timeIntervalSince(modifiedAt) >= retention
        else { continue }
        try fileManager.removeItem(at: url)
    }
}

func recoveryAudioHelperURL(bundle: Bundle = .main) -> URL {
    bundle.bundleURL
        .appendingPathComponent("Contents/Helpers", isDirectory: true)
        .appendingPathComponent("record-it-recovery-audio")
}

final class RecoveryAudioRecording: @unchecked Sendable {
    let outputURL: URL

    private let device: CaptureAudioDevice
    private let helperURL: URL
    private let readyURL: URL
    private let onFailure: @Sendable (Error) -> Void
    private let process = Process()
    private let stateLock = NSLock()
    private var isStopping = false

    init(
        device: CaptureAudioDevice,
        outputURL: URL,
        helperURL: URL = recoveryAudioHelperURL(),
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.device = device
        self.outputURL = outputURL
        self.helperURL = helperURL
        self.onFailure = onFailure
        readyURL = outputURL.appendingPathExtension("ready")
    }

    func start() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: readyURL)
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw RecordItError.message(
                "The independent recovery-audio helper is missing. Reinstall Record It before recording."
            )
        }

        process.executableURL = helperURL
        process.arguments = [
            "--output", outputURL.path,
            "--ready", readyURL.path,
            "--device-uid", device.id,
            "--device-name", device.name
        ]
        let diagnostics = Pipe()
        process.standardError = diagnostics
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let expected = self.stateLock.withLock { self.isStopping }
            guard !expected else { return }
            let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.flatMap { $0.isEmpty ? nil : $0 }
                ?? "The recovery-audio helper exited unexpectedly "
                    + "with status \(process.terminationStatus)."
            onFailure(RecordItError.message(reason))
        }

        try process.run()
        // Process inherits the pipe's write end. The parent must close its own
        // copy or readDataToEndOfFile never sees EOF when the helper crashes.
        try diagnostics.fileHandleForWriting.close()
        do {
            try await waitUntilReady()
        } catch {
            stateLock.withLock { isStopping = true }
            if process.isRunning { process.terminate() }
            throw error
        }
        RecordingDiagnostics.shared.log(
            "recovery-audio.start device=\(device.name) output=\(outputURL.path)"
        )
    }

    func stop() async throws {
        stateLock.withLock { isStopping = true }
        if process.isRunning {
            process.terminate()
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [process] in
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
        }
        try? FileManager.default.removeItem(at: readyURL)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RecordItError.message("The independent recovery audio file was not created.")
        }
        RecordingDiagnostics.shared.log(
            "recovery-audio.stop status=\(process.terminationStatus) output=\(outputURL.path)"
        )
    }

    private func waitUntilReady() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: readyURL.path) { return }
            if !process.isRunning {
                throw RecordItError.message("The independent recovery-audio helper failed to start.")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw RecordItError.message("The independent recovery microphone did not start within 8 seconds.")
    }
}
