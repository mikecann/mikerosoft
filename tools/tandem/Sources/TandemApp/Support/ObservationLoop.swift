import Foundation
import Observation

/// Re-runs `onChange` whenever anything `read` touched changes, for AppKit
/// views that draw from `@Observable` models. Changes arriving together are
/// coalesced into one call on the next main run loop turn.
@MainActor
final class ObservationLoop {
    private let read: () -> Void
    private let onChange: () -> Void
    private var active = true

    init(read: @escaping () -> Void, onChange: @escaping () -> Void) {
        self.read = read
        self.onChange = onChange
        track()
    }

    func cancel() {
        active = false
    }

    private func track() {
        guard active else { return }
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fire() }
            }
        }
    }

    private func fire() {
        guard active else { return }
        onChange()
        track()
    }
}
