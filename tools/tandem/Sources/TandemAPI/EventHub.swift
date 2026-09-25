import Foundation
import TandemCore
import TandemMedia

/// Something that happened to the project while it was open: an edit, an
/// undo, a job moving along, an export finishing. `watch` streams these.
public struct ServiceEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case edit, undo, redo, reload
        /// Background analysis jobs changed (`jobs` holds all of them).
        case jobs
        /// An export or review clip moved along (`export` holds it).
        case export
    }

    /// Increases by one per event, per server process. SSE clients resume
    /// with it (`Last-Event-ID`).
    public var seq: Int
    public var kind: Kind
    public var date: Date
    public var revision: Int?
    public var label: String?
    public var author: String?
    public var jobs: [JobStatus]?
    public var export: ExportJob?

    public init(
        seq: Int,
        kind: Kind,
        date: Date = Date(),
        revision: Int? = nil,
        label: String? = nil,
        author: String? = nil,
        jobs: [JobStatus]? = nil,
        export: ExportJob? = nil
    ) {
        self.seq = seq
        self.kind = kind
        self.date = date
        self.revision = revision
        self.label = label
        self.author = author
        self.jobs = jobs
        self.export = export
    }

    /// True for events that change the project.
    public var isChange: Bool {
        switch kind {
        case .edit, .undo, .redo, .reload: return true
        case .jobs, .export: return false
        }
    }
}

/// An export or review clip the service is rendering.
public struct ExportJob: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, done, failed }

    public var id: String
    public var output: String
    public var preset: String
    public var progress: Double
    public var state: State
    public var message: String?

    public init(id: String, output: String, preset: String, progress: Double = 0, state: State = .running, message: String? = nil) {
        self.id = id
        self.output = output
        self.preset = preset
        self.progress = progress
        self.state = state
        self.message = message
    }
}

/// Fans service events out to watchers and keeps the recent ones so a
/// watcher that reconnects can catch up.
public final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [ServiceEvent] = []
    private var nextSeq = 1
    private var subscribers: [UUID: AsyncStream<ServiceEvent>.Continuation] = [:]
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    /// The sequence number of the newest event, or 0.
    public var lastSeq: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextSeq - 1
    }

    /// Records an event and hands it to every subscriber. `make` gets the
    /// event's sequence number.
    @discardableResult
    public func publish(_ make: (Int) -> ServiceEvent) -> ServiceEvent {
        lock.lock()
        let event = make(nextSeq)
        nextSeq += 1
        buffer.append(event)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let targets = Array(subscribers.values)
        lock.unlock()
        for continuation in targets { continuation.yield(event) }
        return event
    }

    /// Buffered events newer than `seq`, oldest first.
    public func events(after seq: Int) -> [ServiceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.filter { $0.seq > seq }
    }

    /// A stream of events from now on, after replaying buffered events newer
    /// than `replayAfter` (when given). The stream ends when the consumer
    /// stops iterating or `finishAll` is called.
    public func subscribe(replayAfter: Int? = nil) -> AsyncStream<ServiceEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1000)) { continuation in
            lock.lock()
            if let replayAfter {
                for event in buffer where event.seq > replayAfter { continuation.yield(event) }
            }
            subscribers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Ends every subscriber's stream, for shutdown.
    public func finishAll() {
        lock.lock()
        let targets = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }

    /// Waits up to `timeout` seconds for an event matching `where`, and
    /// returns it, or nil on timeout. `unless` is checked once the
    /// subscription is in place, so a change that lands just before the
    /// wait isn't missed: when it's already true this returns nil at once.
    public func next(
        timeout: Double,
        unless alreadyDone: () -> Bool = { false },
        where matches: @escaping @Sendable (ServiceEvent) -> Bool
    ) async -> ServiceEvent? {
        let stream = subscribe()
        if alreadyDone() { return nil }
        return await withTaskGroup(of: ServiceEvent?.self) { group in
            group.addTask {
                for await event in stream where matches(event) { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
