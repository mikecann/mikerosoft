import Foundation

/// Keeps mirrored phones from auto-locking by sending a Shift press every so often. It types
/// nothing, but it's input, so it resets the phone's auto-lock timer. The shortest Auto-Lock
/// setting is 30 seconds, so every 20 seconds is enough. A locked phone is left alone, since
/// a nudge would only wake its lock screen.
enum KeepAwake {
    static let interval: TimeInterval = 20
    private static let defaultsKey = "keepPhonesAwake"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func shouldNudge(isOn: Bool, isReady: Bool, lastNudge: Date?, now: Date) -> Bool {
        guard isOn, isReady else { return false }
        guard let lastNudge else { return true }
        return now.timeIntervalSince(lastNudge) >= interval
    }
}
