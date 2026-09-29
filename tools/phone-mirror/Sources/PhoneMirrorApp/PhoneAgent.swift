import CoreGraphics
import Foundation

/// Sends taps, drags, and typing to WebDriverAgent on one phone. Commands run one at a time,
/// in the order they were given, so a tap never overtakes the drag before it.
final class PhoneAgent: @unchecked Sendable {
    struct AgentError: LocalizedError {
        let errorDescription: String?
    }

    let baseURL: URL
    /// Called on the main thread when a command fails, which usually means the helper stopped.
    var onFailure: ((Error) -> Void)?

    private let http: URLSession
    private let lock = NSLock()
    private var sessionID: String?
    private var size: CGSize = .zero
    private var tail: Task<Void, Never>?
    private var pendingText = ""
    private var typingQueued = false

    /// The phone's screen in points, in its current orientation.
    var screenSize: CGSize { lock.withLock { size } }

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        http = URLSession(configuration: configuration)
    }

    /// Opens a session that doesn't wait for apps to settle before each gesture, which is
    /// what makes taps feel immediate.
    func connect() async throws {
        let response = try await request("POST", "session", [
            "capabilities": ["alwaysMatch": ["shouldWaitForQuiescence": false]],
        ])
        let value = response["value"] as? [String: Any]
        guard let id = (value?["sessionId"] ?? response["sessionId"]) as? String else {
            throw AgentError(errorDescription: "The phone helper didn't start a session")
        }
        lock.withLock { sessionID = id }
        _ = try await request("POST", "session/\(id)/appium/settings", [
            "settings": ["waitForIdleTimeout": 0, "animationCoolOffTimeout": 0],
        ])
        try await refreshScreenSize()
    }

    func refreshScreenSize() async throws {
        let response = try await request("GET", try sessionPath("window/size"))
        guard let value = response["value"] as? [String: Any],
              let width = (value["width"] as? NSNumber)?.doubleValue,
              let height = (value["height"] as? NSNumber)?.doubleValue else {
            throw AgentError(errorDescription: "The phone helper didn't report its screen size")
        }
        lock.withLock { size = CGSize(width: width, height: height) }
        Log.info("agent screen \(Int(width))x\(Int(height)) points")
    }

    /// Whether the phone is showing its lock screen, when touches and typing do nothing.
    func isLocked() async throws -> Bool {
        let response = try await request("GET", "wda/locked")
        return response["value"] as? Bool ?? false
    }

    // MARK: - Commands

    func tap(_ point: CGPoint) {
        enqueue { [self] in
            _ = try await request("POST", try sessionPath("wda/tap"), ["x": point.x, "y": point.y])
        }
    }

    func longPress(_ point: CGPoint, duration: TimeInterval) {
        enqueue { [self] in
            _ = try await request("POST", try sessionPath("wda/touchAndHold"), ["x": point.x, "y": point.y, "duration": duration])
        }
    }

    func drag(_ path: [TimedPoint], holdAtEnd: TimeInterval = 0) {
        guard path.count > 1 else { return }
        enqueue { [self] in
            _ = try await request("POST", try sessionPath("actions"), TouchActions.drag(path, holdAtEnd: holdAtEnd))
        }
    }

    /// Typing that arrives while a command is running is sent together with the next request.
    func type(_ text: String) {
        let shouldQueue: Bool = lock.withLock {
            pendingText += text
            if typingQueued { return false }
            typingQueued = true
            return true
        }
        guard shouldQueue else { return }
        enqueue { [self] in
            let text = lock.withLock {
                defer { pendingText = ""; typingQueued = false }
                return pendingText
            }
            guard !text.isEmpty else { return }
            _ = try await request("POST", try sessionPath("wda/keys"), ["value": [text]])
        }
    }

    func pressHome() {
        enqueue { [self] in
            _ = try await request("POST", "wda/homescreen", [:])
        }
    }

    func updateScreenSize() {
        enqueue { [self] in try await refreshScreenSize() }
    }

    // MARK: - Plumbing

    private func enqueue(_ command: @escaping @Sendable () async throws -> Void) {
        lock.lock()
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            do {
                try await command()
            } catch {
                Log.info("agent command failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.onFailure?(error) }
            }
        }
        lock.unlock()
    }

    private func sessionPath(_ path: String) throws -> String {
        guard let id = lock.withLock({ sessionID }) else {
            throw AgentError(errorDescription: "Not connected to the phone helper")
        }
        return "session/\(id)/\(path)"
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await http.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            let message = ((json["value"] as? [String: Any])?["message"] as? String) ?? "HTTP error"
            throw AgentError(errorDescription: "\(path): \(message)")
        }
        return json
    }
}
