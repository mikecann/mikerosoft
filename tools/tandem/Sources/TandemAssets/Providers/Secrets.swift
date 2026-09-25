import Foundation

/// Where API keys come from.
public protocol SecretStore: Sendable {
    /// The key stored under `service`, or nil when there isn't one.
    func secret(service: String) -> String?
}

/// Keys in the login Keychain, read the same way Mike reads them in a
/// shell: `security find-generic-password -s <service> -w`.
///
/// Going through the `security` tool rather than `SecItemCopyMatching`
/// matters: the items were added with `security`, so it's already trusted
/// and reading never pops a Keychain permission dialog, which would hang a
/// CLI or an overnight agent.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String: (value: String, at: Date)] = [:]
    private var missingSince: [String: Date] = [:]
    /// How long a missing key is remembered before asking again, so adding
    /// a key while the app runs is noticed.
    private let recheckAfter: TimeInterval = 30
    /// How long a found key is reused, so a replaced key is picked up
    /// without restarting.
    private let reuseFor: TimeInterval = 600

    public init() {}

    public func secret(service: String) -> String? {
        lock.lock()
        if let hit = found[service], Date().timeIntervalSince(hit.at) < reuseFor {
            lock.unlock()
            return hit.value
        }
        if let since = missingSince[service], Date().timeIntervalSince(since) < recheckAfter {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let value = Self.lookUp(service: service)
        lock.lock()
        defer { lock.unlock() }
        if let value {
            found[service] = (value, Date())
            missingSince[service] = nil
        } else {
            found[service] = nil
            missingSince[service] = Date()
        }
        return value
    }

    private static func lookUp(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // If the Keychain ever asks for permission instead of answering,
        // give up rather than hang a headless run.
        if finished.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// Fixed keys, for tests.
public struct StaticSecretStore: SecretStore {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func secret(service: String) -> String? { values[service] }
}
