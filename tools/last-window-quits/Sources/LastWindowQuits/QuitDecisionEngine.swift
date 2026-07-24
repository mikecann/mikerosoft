import Foundation

struct AppSnapshot: Equatable {
    let processIdentifier: pid_t
    let windowCount: Int
    let isEligible: Bool
}

struct QuitDecisionEngine {
    private struct State {
        var hasSeenWindow = false
        var zeroWindowsSince: TimeInterval?
        var quitRequested = false
    }

    private let gracePeriod: TimeInterval
    private var states: [pid_t: State] = [:]

    init(gracePeriod: TimeInterval) {
        self.gracePeriod = gracePeriod
    }

    mutating func update(_ snapshots: [AppSnapshot], now: TimeInterval) -> [pid_t] {
        let liveProcessIdentifiers = Set(snapshots.map(\.processIdentifier))
        states = states.filter { liveProcessIdentifiers.contains($0.key) }

        var processesToQuit: [pid_t] = []

        for snapshot in snapshots {
            guard snapshot.isEligible else {
                states.removeValue(forKey: snapshot.processIdentifier)
                continue
            }

            var state = states[snapshot.processIdentifier] ?? State()

            if snapshot.windowCount > 0 {
                state.hasSeenWindow = true
                state.zeroWindowsSince = nil
                state.quitRequested = false
            } else if state.hasSeenWindow && !state.quitRequested {
                if let zeroWindowsSince = state.zeroWindowsSince {
                    if now - zeroWindowsSince >= gracePeriod {
                        state.quitRequested = true
                        processesToQuit.append(snapshot.processIdentifier)
                    }
                } else {
                    state.zeroWindowsSince = now
                }
            }

            states[snapshot.processIdentifier] = state
        }

        return processesToQuit
    }
}
