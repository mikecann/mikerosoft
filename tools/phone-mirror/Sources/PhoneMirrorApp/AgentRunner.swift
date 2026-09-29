import Foundation

/// Starts and looks after the WebDriverAgent helper for one phone. It builds the helper when the
/// phone is new to your developer team or its signing has expired, waits while the phone is
/// locked, and restarts it if it stops.
@MainActor
final class AgentRunner {
    enum State: Equatable {
        case idle
        case starting
        case building
        case locked
        case ready
        case failed(String)
    }

    let phoneName: String
    var onStateChange: ((State) -> Void)?
    /// Set once the helper is running and has a session.
    private(set) var agent: PhoneAgent?

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            Log.info("\(phoneName) helper \(state)")
            onStateChange?(state)
        }
    }

    private var process: Process?
    private var stopped = true
    private var builtThisLaunch = false
    private var connecting = false
    private var lockCheck: Timer?

    init(phoneName: String) {
        self.phoneName = phoneName
    }

    func start() {
        guard stopped else { return }
        stopped = false
        state = .starting
        Task { await launch() }
    }

    func stop() {
        stopped = true
        stopLockCheck()
        process?.terminate()
        process = nil
        agent = nil
        state = .idle
    }

    /// A command can fail because the phone locked (the helper is fine) or because the helper
    /// died. Only the second needs a restart.
    func commandFailed() {
        guard let agent else { return }
        Task {
            if let locked = try? await agent.isLocked() {
                guard self.agent === agent else { return }
                state = locked ? .locked : .ready
            } else {
                restart()
            }
        }
    }

    func restart() {
        guard !stopped else { return }
        stopLockCheck()
        agent = nil
        process?.terminate()
    }

    /// The helper keeps running while the phone is locked, but touches do nothing then,
    /// so the window says so.
    private func startLockCheck() {
        stopLockCheck()
        lockCheck = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let agent = self.agent, let locked = try? await agent.isLocked() else { return }
                guard self.agent === agent else { return }
                self.state = locked ? .locked : .ready
            }
        }
    }

    private func stopLockCheck() {
        lockCheck?.invalidate()
        lockCheck = nil
    }

    private func launch() async {
        guard !stopped else { return }
        guard let info = await DeviceDirectory.lookup(name: phoneName) else {
            state = .failed("Xcode can't see \(phoneName)")
            retry(after: 5)
            return
        }
        state = .starting
        run(["run", info.udid], onLine: { [weak self] line in
            if line.contains("ServerURLHere->") {
                self?.connect(info)
            } else if line.contains("is locked") || line.contains("to Continue") {
                self?.state = .locked
            }
        }, completion: { [weak self] status, output in
            self?.helperExited(status: status, output: output, info: info)
        })
    }

    private func helperExited(status: Int32, output: String, info: PhoneDeviceInfo) {
        process = nil
        agent = nil
        stopLockCheck()
        guard !stopped else { return }
        if Self.needsBuild(status: status, output: output) && !builtThisLaunch {
            build(info)
        } else {
            state = .failed(Self.summary(of: output))
            retry(after: 3)
        }
    }

    private func build(_ info: PhoneDeviceInfo) {
        builtThisLaunch = true
        state = .building
        run(["build", info.udid], onLine: nil) { [weak self] status, output in
            guard let self, !self.stopped else { return }
            self.process = nil
            if status == 0 {
                Task { await self.launch() }
            } else {
                self.state = .failed("Couldn't build the phone helper. " + Self.summary(of: output))
            }
        }
    }

    /// Talks to the helper through the USB tunnel Xcode keeps open to the phone.
    private func connect(_ info: PhoneDeviceInfo) {
        guard !connecting else { return }
        connecting = true
        let commandFailed: () -> Void = { [weak self] in self?.commandFailed() }
        Task {
            defer { connecting = false }
            let tunnel = await DeviceDirectory.lookup(name: phoneName)?.tunnelAddress ?? info.tunnelAddress
            guard let tunnel, let url = URL(string: "http://[\(tunnel)]:8100") else {
                state = .failed("No USB tunnel to \(phoneName). Is the cable plugged in?")
                return
            }
            let agent = PhoneAgent(baseURL: url)
            agent.onFailure = { _ in commandFailed() }
            do {
                try await agent.connect()
                guard !stopped else { return }
                self.agent = agent
                state = .ready
                startLockCheck()
            } catch {
                state = .failed("Couldn't reach the phone helper: \(error.localizedDescription)")
                restart()
            }
        }
    }

    private func retry(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.stopped, self.process == nil else { return }
            Task { await self.launch() }
        }
    }

    // MARK: - Running agent.sh

    private func run(_ arguments: [String], onLine: ((String) -> Void)?, completion: @escaping (Int32, String) -> Void) {
        guard let script = Bundle.main.url(forResource: "agent", withExtension: "sh") else {
            state = .failed("agent.sh is missing from the app bundle")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let transcript = AgentTranscript(phoneName: phoneName)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let lines = transcript.append(handle.availableData)
            guard let onLine, !lines.isEmpty else { return }
            DispatchQueue.main.async { lines.forEach(onLine) }
        }
        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            DispatchQueue.main.async { completion(status, transcript.tail) }
        }
        do {
            try process.run()
            self.process = process
            Log.info("\(phoneName) agent.sh \(arguments.joined(separator: " "))")
        } catch {
            state = .failed("Couldn't start agent.sh: \(error.localizedDescription)")
        }
    }

    // MARK: - Reading the helper's output

    /// A failed run means a build is needed when there's nothing built yet (exit 3) or the phone
    /// isn't covered by the signing: a new phone, or signing that expired after a year.
    nonisolated static func needsBuild(status: Int32, output: String) -> Bool {
        if status == 3 { return true }
        let lowered = output.lowercased()
        return ["provisioning profile", "code signature", "codesign", "could not be verified",
                "certificate", "not registered", "application verification"]
            .contains { lowered.contains($0) }
    }

    /// The most useful line of xcodebuild's output for showing the user.
    nonisolated static func summary(of output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.last { $0.localizedCaseInsensitiveContains("error") } ?? lines.last ?? "The phone helper stopped"
        return String(line.prefix(160))
    }
}

/// Collects a helper's output: whole lines for the caller, the recent tail for error messages,
/// and everything in ~/Library/Logs/Phone Mirror/helper-<phone>.log.
private final class AgentTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private var recent: [String] = []
    private let file: FileHandle?

    init(phoneName: String) {
        let url = Log.url.deletingLastPathComponent().appendingPathComponent("helper-\(phoneName).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    var tail: String { lock.withLock { recent.joined(separator: "\n") } }

    func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        try? file?.write(contentsOf: data)
        return lock.withLock {
            partial += String(decoding: data, as: UTF8.self)
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            recent = Array((recent + lines).suffix(80))
            return lines
        }
    }
}
