import Foundation

/// One hardware encode at a time. Exports and proxy builds use the same
/// VideoToolbox encoder, and running both slows both, so they take turns.
/// Higher priority waiters go first, so an export jumps ahead of queued
/// proxy work.
public actor EncoderLock {
    public static let shared = EncoderLock()

    public enum Priority: Int, Sendable, Comparable {
        case background = 0
        case export = 10

        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    private var busy = false
    private var waiters: [(priority: Priority, order: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var counter = 0

    public init() {}

    public func acquire(priority: Priority = .background) async {
        if !busy {
            busy = true
            return
        }
        counter += 1
        let order = counter
        await withCheckedContinuation { continuation in
            waiters.append((priority, order, continuation))
        }
    }

    public func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        let next = waiters.indices.max { a, b in
            waiters[a].priority == waiters[b].priority
                ? waiters[a].order > waiters[b].order
                : waiters[a].priority < waiters[b].priority
        }!
        let waiter = waiters.remove(at: next)
        waiter.continuation.resume()
    }

    public var isBusy: Bool { busy }

    /// True when someone is waiting with a higher priority than `priority`.
    /// Long background builds check this between frames and hand the
    /// encoder over, so an export never waits for a whole proxy.
    public func hasWaiters(above priority: Priority) -> Bool {
        waiters.contains { $0.priority > priority }
    }

    /// How many are waiting, for status displays.
    public var waitingCount: Int { waiters.count }
}
