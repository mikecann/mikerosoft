import Foundation

/// The recovery helper prefixes stderr lines with this when the backup
/// microphone has a problem it is recording through.
let recoveryAudioProblemPrefix = "problem:"

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
    private let onProblem: @Sendable (Error) -> Void
    private let process = Process()
    private let stateLock = NSLock()
    private var isStopping = false
    private var pendingDiagnostics = ""
    private var lastDiagnosticLine: String?

    init(
        device: CaptureAudioDevice,
        outputURL: URL,
        helperURL: URL = recoveryAudioHelperURL(),
        onProblem: @escaping @Sendable (Error) -> Void
    ) {
        self.device = device
        self.outputURL = outputURL
        self.helperURL = helperURL
        self.onProblem = onProblem
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
        // The helper keeps recording through problems and reports each one as
        // a line on stderr, so read lines as they arrive rather than at exit.
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.receiveDiagnostics(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            // Drain whatever the helper wrote just before exiting so the
            // reported reason includes its last message.
            let reader = diagnostics.fileHandleForReading
            reader.readabilityHandler = nil
            let remaining = reader.readDataToEndOfFile()
            if !remaining.isEmpty {
                self.receiveDiagnostics(String(decoding: remaining, as: UTF8.self) + "\n")
            }
            let (expected, lastLine) = self.stateLock.withLock { (self.isStopping, self.lastDiagnosticLine) }
            guard !expected else { return }
            let reason = "The backup audio helper exited with status \(process.terminationStatus)"
                + (lastLine.map { ": \($0)" } ?? ".")
                + " The main recording is unaffected."
            onProblem(RecordItError.message(reason))
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

    private func receiveDiagnostics(_ text: String) {
        let lines = stateLock.withLock { () -> [String] in
            pendingDiagnostics += text
            var parts = pendingDiagnostics.components(separatedBy: "\n")
            pendingDiagnostics = parts.removeLast()
            let lines = parts
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let last = lines.last { lastDiagnosticLine = last }
            return lines
        }
        let isStopping = stateLock.withLock { self.isStopping }
        for line in lines {
            RecordingDiagnostics.shared.log("recovery-audio.helper \(line)")
            if !isStopping, line.hasPrefix(recoveryAudioProblemPrefix) {
                let message = line.dropFirst(recoveryAudioProblemPrefix.count)
                    .trimmingCharacters(in: .whitespaces)
                onProblem(RecordItError.message(message))
            }
        }
    }

    private func waitUntilReady() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: readyURL.path) { return }
            if !process.isRunning {
                let detail = stateLock.withLock { lastDiagnosticLine }
                throw RecordItError.message(
                    "The independent recovery-audio helper failed to start."
                        + (detail.map { " \($0)" } ?? "")
                )
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw RecordItError.message("The independent recovery microphone did not start within 8 seconds.")
    }
}
