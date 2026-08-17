import AppKit
import Foundation

struct ControlCenterLightEndpoint: Equatable {
    let id: String
    let host: String
    let port: Int

    var lightsURL: URL {
        // Bonjour commonly returns a fully-qualified host with a trailing dot.
        // URL accepts that form and it avoids making our own DNS assumptions.
        URL(string: "http://\(host):\(port)/elgato/lights")!
    }
}

struct ControlCenterLightsSnapshot: Equatable {
    var discoveredCount = 0
    var reachableCount = 0
    var onCount = 0
    var isBusy = false

    var allReachableLightsAreOn: Bool {
        reachableCount > 0 && onCount == reachableCount
    }
}

private struct ControlCenterLightsResponse: Decodable {
    struct Light: Decodable {
        let on: Int
    }

    let lights: [Light]
}

private struct ControlCenterLightsPowerRequest: Encodable {
    struct Light: Encodable {
        let on: Int
    }

    let numberOfLights = 1
    let lights: [Light]
}

func controlCenterLightPowerState(from data: Data) throws -> Bool {
    let response = try JSONDecoder().decode(ControlCenterLightsResponse.self, from: data)
    guard let light = response.lights.first else {
        throw CocoaError(.coderReadCorrupt)
    }
    return light.on != 0
}

func controlCenterLightPowerRequestData(isOn: Bool) throws -> Data {
    try JSONEncoder().encode(
        ControlCenterLightsPowerRequest(lights: [.init(on: isOn ? 1 : 0)])
    )
}

func controlCenterLightsToggleTarget(for states: [Bool]) -> Bool? {
    guard !states.isEmpty else { return nil }
    return !states.allSatisfy { $0 }
}

final class ControlCenterLightsController: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = ControlCenterLightsController()

    private let browser = NetServiceBrowser()
    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "com.mikerosoft.taskbar.control-center-lights")
    private var services: [String: NetService] = [:]
    private var endpoints: [String: ControlCenterLightEndpoint] = [:]
    private var powerStates: [String: Bool] = [:]
    private var isBusy = false
    private var hasStarted = false

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        session = URLSession(configuration: configuration)
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        browser.searchForServices(ofType: "_elg._tcp.", inDomain: "local.")
        log("Control Center Lights discovery started")
    }

    func stop() {
        guard hasStarted else { return }
        browser.stop()
        hasStarted = false
    }

    func snapshot() -> ControlCenterLightsSnapshot {
        stateQueue.sync {
            ControlCenterLightsSnapshot(
                discoveredCount: endpoints.count,
                reachableCount: powerStates.count,
                onCount: powerStates.values.filter { $0 }.count,
                isBusy: isBusy
            )
        }
    }

    func refresh() {
        let currentEndpoints = stateQueue.sync { Array(endpoints.values) }
        fetchPowerStates(from: currentEndpoints) { [weak self] states in
            self?.stateQueue.async {
                self?.powerStates = states
            }
        }
    }

    func toggleAll(completion: @escaping (Bool?) -> Void = { _ in }) {
        let currentEndpoints = stateQueue.sync { () -> [ControlCenterLightEndpoint] in
            guard !isBusy else { return [] }
            isBusy = true
            return Array(endpoints.values)
        }
        guard !currentEndpoints.isEmpty else {
            stateQueue.async { [weak self] in self?.isBusy = false }
            log("Control Center Lights toggle skipped: no devices discovered")
            completion(nil)
            return
        }

        fetchPowerStates(from: currentEndpoints) { [weak self] states in
            guard let self else { return }
            guard let target = controlCenterLightsToggleTarget(for: Array(states.values)) else {
                self.stateQueue.async { self.isBusy = false }
                log("Control Center Lights toggle failed: no devices reachable")
                completion(nil)
                return
            }

            // The caller can apply the same intent to related studio hardware
            // while the independent light requests are in flight.
            completion(target)

            let reachableEndpoints = currentEndpoints.filter { states[$0.id] != nil }
            self.setPower(target, on: reachableEndpoints) { updatedIDs in
                self.stateQueue.async {
                    self.powerStates = states
                    for id in updatedIDs {
                        self.powerStates[id] = target
                    }
                    self.isBusy = false
                }
                log("Control Center Lights set \(updatedIDs.count)/\(reachableEndpoints.count) device(s) \(target ? "on" : "off")")
            }
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        services[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        services.removeValue(forKey: service.name)
        stateQueue.async { [weak self] in
            self?.endpoints.removeValue(forKey: service.name)
            self?.powerStates.removeValue(forKey: service.name)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let endpoint = ControlCenterLightEndpoint(id: sender.name, host: host, port: sender.port)
        stateQueue.async { [weak self] in
            self?.endpoints[sender.name] = endpoint
        }
        fetchPowerState(from: endpoint) { [weak self] state in
            guard let state else { return }
            self?.stateQueue.async {
                self?.powerStates[endpoint.id] = state
            }
        }
        log("Control Center Lights discovered \(sender.name) at \(host):\(sender.port)")
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        log("Control Center Lights could not resolve \(sender.name): \(errorDict)")
    }

    private func fetchPowerStates(
        from endpoints: [ControlCenterLightEndpoint],
        completion: @escaping ([String: Bool]) -> Void
    ) {
        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "com.mikerosoft.taskbar.control-center-lights.fetch")
        var states: [String: Bool] = [:]

        for endpoint in endpoints {
            group.enter()
            fetchPowerState(from: endpoint) { state in
                if let state {
                    resultQueue.sync { states[endpoint.id] = state }
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            completion(resultQueue.sync { states })
        }
    }

    private func fetchPowerState(
        from endpoint: ControlCenterLightEndpoint,
        completion: @escaping (Bool?) -> Void
    ) {
        var request = URLRequest(url: endpoint.lightsURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let data,
                  let state = try? controlCenterLightPowerState(from: data)
            else {
                completion(nil)
                return
            }
            completion(state)
        }.resume()
    }

    private func setPower(
        _ isOn: Bool,
        on endpoints: [ControlCenterLightEndpoint],
        completion: @escaping (Set<String>) -> Void
    ) {
        guard let body = try? controlCenterLightPowerRequestData(isOn: isOn) else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "com.mikerosoft.taskbar.control-center-lights.put")
        var updatedIDs = Set<String>()
        for endpoint in endpoints {
            group.enter()
            var request = URLRequest(url: endpoint.lightsURL)
            request.httpMethod = "PUT"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            session.dataTask(with: request) { _, response, error in
                if error == nil,
                   let response = response as? HTTPURLResponse,
                   response.statusCode == 200 {
                    _ = resultQueue.sync { updatedIDs.insert(endpoint.id) }
                }
                group.leave()
            }.resume()
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            completion(resultQueue.sync { updatedIDs })
        }
    }
}

struct ControlCenterLightsWidgetPlugin: TaskbarWidgetPlugin {
    let id: TaskbarWidgetID = .controlCenterLights
    let title = "Control Center Lights"
    let symbolName = "lightbulb"

    func isEnabled(in values: TaskbarSettingValues) -> Bool {
        values.controlCenterLightsWidget.isEnabled
    }

    func minimumWidth(in values: TaskbarSettingValues, height: CGFloat) -> CGFloat {
        values.controlCenterLightsWidget.isEnabled ? min(36, max(28, height)) : 0
    }

    func preferredWidth(in values: TaskbarSettingValues, height: CGFloat, availableWidth: CGFloat) -> CGFloat {
        min(minimumWidth(in: values, height: height), availableWidth)
    }

    func draw(in rect: NSRect, values: TaskbarSettingValues, date: Date) {
        guard values.controlCenterLightsWidget.isEnabled else { return }
        let snapshot = ControlCenterLightsController.shared.snapshot()
        let isOn = snapshot.allReachableLightsAreOn
        let foreground = isOn
            ? NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.32, alpha: 1)
            : NSColor(calibratedWhite: snapshot.reachableCount > 0 ? 0.86 : 0.48, alpha: 1)
        let fill = isOn
            ? NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.08, alpha: 0.55)
            : NSColor(calibratedWhite: 1, alpha: 0.07)

        let buttonRect = rect.insetBy(dx: 3, dy: 5)
        fill.setFill()
        NSBezierPath(roundedRect: buttonRect, xRadius: 7, yRadius: 7).fill()

        let pointSize = min(17, max(12, buttonRect.height - 8))
        let baseConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let colorConfiguration = NSImage.SymbolConfiguration(hierarchicalColor: foreground)
        let configuration = baseConfiguration.applying(colorConfiguration)
        guard let image = NSImage(systemSymbolName: "power", accessibilityDescription: "Toggle Control Center lights")?
            .withSymbolConfiguration(configuration)
        else { return }

        let imageRect = NSRect(
            x: rect.midX - image.size.width / 2,
            y: rect.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: snapshot.isBusy ? 0.45 : 1)
    }
}
