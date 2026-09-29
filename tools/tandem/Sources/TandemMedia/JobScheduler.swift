import Foundation

/// Runs analysis jobs in the background, most urgent first.
///
/// - Order: priority (`interactive`, `timeline`, `background`), then cheap
///   kinds before expensive ones (a waveform before a matte), then first
///   come first served.
/// - Limits: per kind, a shared limit for the encoder-heavy kinds (proxy
///   and matte), and a total, so the machine stays responsive.
/// - Dedupe: a job ID names one piece of work (kind plus cache key), so
///   asking twice runs it once; asking again with a higher priority moves
///   it up.
/// - Preemption: a long job that calls `checkpoint()` steps aside, keeping
///   its state, when a more urgent job needs its slot, and carries on
///   afterwards.
/// - Cancellation is cooperative: jobs check `checkpoint()` or
///   `checkCancellation()` between frames or chunks.
final class JobScheduler: @unchecked Sendable {
    struct Limits: Sendable {
        var perKind: [AnalysisKind: Int]
        /// Proxy and matte builds together.
        var encoder: Int
        var total: Int

        static let standard = Limits(
            perKind: [.thumbnails: 2, .waveform: 2, .loudness: 2, .transcript: 1, .proxy: 1, .matte: 1, .isolatedVoice: 1, .converted: 1],
            encoder: 1,
            total: 4
        )
    }

    struct Job: Sendable {
        /// Names the work; submitting an ID that's already queued or running
        /// doesn't start it again.
        var id: String
        var kind: AnalysisKind
        var mediaID: String
        var priority: JobPriority
        var work: @Sendable (JobContext) async throws -> Void
    }

    /// Cheap and widely needed kinds go first within a priority. A
    /// conversion goes before everything, since the file's thumbnails,
    /// proxy and matte wait for it.
    static let kindOrder: [AnalysisKind: Int] = [
        .converted: -1, .waveform: 0, .loudness: 1, .thumbnails: 2, .transcript: 3, .proxy: 4, .isolatedVoice: 5, .matte: 6
    ]

    static func usesEncoder(_ kind: AnalysisKind) -> Bool { kind == .proxy || kind == .matte }

    private final class Entry {
        var job: Job
        var status: JobStatus
        var sequence: Int
        var context: JobContext?
        var started = false
        /// Stepped aside for a more urgent job; waiting in `resume`.
        var paused = false
        var resume: CheckedContinuation<Void, Never>?
        var waiters: [CheckedContinuation<JobStatus?, Never>] = []

        init(job: Job, sequence: Int) {
            self.job = job
            self.sequence = sequence
            status = JobStatus(id: job.id, kind: job.kind, mediaID: job.mediaID, state: .queued)
        }

        var isRunning: Bool { started && !paused }
    }

    var limits: Limits {
        get { lock.withLock { storedLimits } }
        set {
            lock.withLock { storedLimits = newValue }
            pump()
        }
    }

    /// Finished jobs kept for `statuses`.
    let historyLimit = 100

    private let lock = NSLock()
    private var storedLimits: Limits
    private var entries: [String: Entry] = [:]
    private var history: [JobStatus] = []
    private var observers: [UUID: @Sendable ([JobStatus]) -> Void] = [:]
    private var sequence = 0
    private var notifyPending = false
    private let notifyQueue = DispatchQueue(label: "com.mikerosoft.tandem.media.jobs", qos: .utility)
    let encoderLock: EncoderLock

    init(limits: Limits = .standard, encoderLock: EncoderLock = .shared) {
        storedLimits = limits
        self.encoderLock = encoderLock
    }

    /// Whatever is still running sees a cancellation at its next checkpoint
    /// (and gives the encoder back through its context); paused jobs wake up
    /// to see it; anyone waiting hears "cancelled".
    deinit {
        for entry in entries.values {
            entry.context?.markCancelled()
            entry.resume?.resume()
            entry.resume = nil
            var status = entry.status
            status.state = .cancelled
            entry.waiters.forEach { $0.resume(returning: status) }
            entry.waiters = []
        }
    }

    // MARK: - Submitting

    /// Queues a job, or raises the priority of the same job if it's already
    /// waiting. Returns the job ID.
    @discardableResult
    func submit(_ job: Job) -> String {
        lock.withLock {
            if let existing = entries[job.id] {
                if job.priority > existing.job.priority { existing.job.priority = job.priority }
                return
            }
            sequence += 1
            entries[job.id] = Entry(job: job, sequence: sequence)
        }
        pump()
        scheduleNotify()
        return job.id
    }

    func cancel(id: String) {
        cancel { $0.job.id == id }
    }

    func cancel(mediaID: String) {
        cancel { $0.job.mediaID == mediaID }
    }

    func cancelAll() {
        cancel { _ in true }
    }

    private func cancel(where matches: (Entry) -> Bool) {
        var resumes: [CheckedContinuation<Void, Never>] = []
        var dropped: [(JobStatus, [CheckedContinuation<JobStatus?, Never>])] = []
        lock.withLock {
            for entry in Array(entries.values) where matches(entry) {
                if entry.started {
                    entry.context?.markCancelled()
                    if entry.paused, let resume = entry.resume {
                        // Let it wake up and see the cancellation.
                        entry.resume = nil
                        entry.paused = false
                        resumes.append(resume)
                    }
                } else {
                    // Removed in the same critical section that found it,
                    // so a pump on another thread can't start it meanwhile.
                    entries.removeValue(forKey: entry.job.id)
                    entry.status.state = .cancelled
                    remember(entry.status)
                    dropped.append((entry.status, entry.waiters))
                    entry.waiters = []
                }
            }
        }
        for (status, waiters) in dropped { waiters.forEach { $0.resume(returning: status) } }
        resumes.forEach { $0.resume() }
        scheduleNotify()
    }

    /// Call with the lock held.
    private func remember(_ status: JobStatus) {
        history.removeAll { $0.id == status.id }
        history.append(status)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    // MARK: - Reading

    /// Running jobs, then queued ones in the order they'll run, then recently
    /// finished ones, newest first.
    var statuses: [JobStatus] {
        lock.withLock {
            let active = entries.values.sorted { a, b in
                if a.isRunning != b.isRunning { return a.isRunning }
                return Self.runsBefore(a, b)
            }.map(\.status)
            return active + history.reversed()
        }
    }

    func status(id: String) -> JobStatus? {
        lock.withLock { entries[id]?.status ?? history.last { $0.id == id } }
    }

    /// Waits for a job to finish and returns its final status, or nil for an
    /// ID the scheduler doesn't know.
    func wait(for id: String) async -> JobStatus? {
        await withCheckedContinuation { (continuation: CheckedContinuation<JobStatus?, Never>) in
            lock.lock()
            if let entry = entries[id] {
                entry.waiters.append(continuation)
                lock.unlock()
            } else {
                let last = history.last { $0.id == id }
                lock.unlock()
                continuation.resume(returning: last)
            }
        }
    }

    @discardableResult
    func observe(_ handler: @escaping @Sendable ([JobStatus]) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    func removeObserver(_ token: UUID) {
        lock.withLock { _ = observers.removeValue(forKey: token) }
    }

    // MARK: - Running

    private static func runsBefore(_ a: Entry, _ b: Entry) -> Bool {
        if a.job.priority != b.job.priority { return a.job.priority > b.job.priority }
        let rankA = kindOrder[a.job.kind] ?? 99
        let rankB = kindOrder[b.job.kind] ?? 99
        if rankA != rankB { return rankA < rankB }
        return a.sequence < b.sequence
    }

    /// What's running, counted the ways the limits count it.
    private struct Load {
        var total = 0
        var encoder = 0
        var perKind: [AnalysisKind: Int] = [:]

        mutating func add(_ kind: AnalysisKind) {
            total += 1
            perKind[kind, default: 0] += 1
            if JobScheduler.usesEncoder(kind) { encoder += 1 }
        }

        mutating func remove(_ kind: AnalysisKind) {
            total -= 1
            perKind[kind, default: 1] -= 1
            if JobScheduler.usesEncoder(kind) { encoder -= 1 }
        }
    }

    /// Call with the lock held.
    private func currentLoad() -> Load {
        var load = Load()
        for entry in entries.values where entry.isRunning { load.add(entry.job.kind) }
        return load
    }

    /// Call with the lock held: can a job of this kind run alongside `load`?
    private func fits(_ kind: AnalysisKind, _ load: Load) -> Bool {
        if load.total >= storedLimits.total { return false }
        if load.perKind[kind, default: 0] >= storedLimits.perKind[kind] ?? 1 { return false }
        if Self.usesEncoder(kind), load.encoder >= storedLimits.encoder { return false }
        return true
    }

    /// Starts or resumes whatever fits, most urgent first.
    private func pump() {
        var toStart: [Entry] = []
        var toResume: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            var load = currentLoad()
            let waiting = entries.values.filter { !$0.isRunning }.sorted(by: Self.runsBefore)
            for entry in waiting where fits(entry.job.kind, load) {
                load.add(entry.job.kind)
                if entry.paused {
                    entry.paused = false
                    entry.status.state = .running
                    entry.status.message = nil
                    if let resume = entry.resume {
                        entry.resume = nil
                        toResume.append(resume)
                    }
                } else if !entry.started {
                    entry.started = true
                    entry.status.state = .running
                    let context = JobContext(id: entry.job.id, kind: entry.job.kind, qos: entry.job.priority.qos.qosClass, scheduler: self)
                    entry.context = context
                    toStart.append(entry)
                }
            }
        }
        for entry in toStart { start(entry) }
        toResume.forEach { $0.resume() }
        if !toStart.isEmpty || !toResume.isEmpty { scheduleNotify() }
    }

    private func start(_ entry: Entry) {
        let job = entry.job
        guard let context = entry.context else { return }
        Task.detached(priority: job.priority.taskPriority) { [weak self] in
            var state = JobState.done
            var message: String?
            do {
                try context.checkCancellation()
                try await job.work(context)
                if context.isCancelled { state = .cancelled } else { message = context.lastNote }
            } catch {
                if context.isCancelled || error is CancellationError {
                    state = .cancelled
                } else {
                    state = .failed
                    message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
            await context.releaseEncoder()
            self?.finish(entry, state: state, message: message)
        }
    }

    private func finish(_ entry: Entry, state: JobState, message: String?) {
        let outcome = lock.withLock { () -> (JobStatus, [CheckedContinuation<JobStatus?, Never>])? in
            // Only this run's entry: a job with the same ID submitted since
            // is a different piece of work.
            guard entries[entry.job.id] === entry else { return nil }
            entries.removeValue(forKey: entry.job.id)
            entry.status.state = state
            entry.status.message = message
            if state == .done { entry.status.progress = 1 }
            remember(entry.status)
            defer { entry.waiters = [] }
            return (entry.status, entry.waiters)
        }
        guard let (final, waiters) = outcome else { return }
        waiters.forEach { $0.resume(returning: final) }
        pump()
        scheduleNotify()
    }

    // MARK: - Called by running jobs

    func annotate(id: String, message: String) {
        lock.withLock { entries[id]?.status.message = message }
        scheduleNotify()
    }

    func report(id: String, progress: Double, message: String?) {
        lock.withLock {
            guard let entry = entries[id] else { return }
            entry.status.progress = min(1, max(0, progress))
            if let message { entry.status.message = message }
        }
        scheduleNotify()
    }

    /// True when a more urgent job is waiting for a slot this job holds:
    /// one with a higher priority, or the same priority and a kind that goes
    /// first. So a new take's proxy doesn't wait 15 minutes behind the
    /// previous take's matte.
    func shouldYield(id: String) -> Bool {
        lock.withLock {
            guard let entry = entries[id], entry.isRunning else { return false }
            let load = currentLoad()
            var without = load
            without.remove(entry.job.kind)
            let rank = Self.kindOrder[entry.job.kind] ?? 99
            return entries.values.contains { other in
                // Only worth stepping aside if that lets the other job start;
                // otherwise this job would pause and resume at every checkpoint.
                guard !other.isRunning, sharesLimit(other.job.kind, entry.job.kind),
                      !fits(other.job.kind, load), fits(other.job.kind, without) else { return false }
                if other.job.priority != entry.job.priority { return other.job.priority > entry.job.priority }
                return (Self.kindOrder[other.job.kind] ?? 99) < rank
            }
        }
    }

    private func sharesLimit(_ a: AnalysisKind, _ b: AnalysisKind) -> Bool {
        a == b || (Self.usesEncoder(a) && Self.usesEncoder(b))
    }

    /// How many times a job has stepped aside, for tests.
    private(set) var pauses = 0

    /// Steps aside until the scheduler picks this job again.
    func pause(id: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = lock.withLock { () -> Bool in
                guard let entry = entries[id], entry.isRunning, !(entry.context?.isCancelled ?? false) else { return true }
                pauses += 1
                entry.paused = true
                entry.resume = continuation
                entry.status.state = .queued
                entry.status.message = "Paused for more urgent work"
                return false
            }
            if proceed {
                continuation.resume()
            } else {
                pump()
                scheduleNotify()
            }
        }
    }

    // MARK: - Observers

    private func scheduleNotify() {
        let schedule = lock.withLock { () -> Bool in
            if notifyPending { return false }
            notifyPending = true
            return true
        }
        guard schedule else { return }
        notifyQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let handlers = self.lock.withLock { () -> [@Sendable ([JobStatus]) -> Void] in
                self.notifyPending = false
                return Array(self.observers.values)
            }
            guard !handlers.isEmpty else { return }
            let snapshot = self.statuses
            handlers.forEach { $0(snapshot) }
        }
    }
}

/// What a running job sees: progress reporting, cancellation, preemption
/// and the shared hardware encoder.
final class JobContext: @unchecked Sendable {
    let id: String
    let kind: AnalysisKind
    /// For the job's blocking work, from its priority.
    let qos: DispatchQoS.QoSClass
    private weak var scheduler: JobScheduler?
    /// Held strongly: a job outliving its scheduler (a project closed
    /// mid-build) must still give the encoder back. Nil without a scheduler,
    /// which makes the encoder calls no-ops (standalone runs in tests).
    private let encoderLock: EncoderLock?
    private let lock = NSLock()
    private var cancelled = false
    private var note: String?
    private var holdsEncoder = false
    private var lastEncoderCheck = Date.distantPast

    init(id: String, kind: AnalysisKind, qos: DispatchQoS.QoSClass = .utility, scheduler: JobScheduler?) {
        self.id = id
        self.kind = kind
        self.qos = qos
        self.scheduler = scheduler
        encoderLock = scheduler?.encoderLock
    }

    var isCancelled: Bool { lock.withLock { cancelled } || Task.isCancelled }

    func markCancelled() { lock.withLock { cancelled = true } }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    /// 0...1, with an optional note such as "Frame 1200 of 43376".
    func progress(_ fraction: Double, message: String? = nil) {
        scheduler?.report(id: id, progress: fraction, message: message)
    }

    /// A line that stays on the job's status after it finishes, such as a
    /// matte falling back to Vision. Shown while it runs too.
    func note(_ message: String) {
        lock.withLock { note = message }
        scheduler?.annotate(id: id, message: message)
    }

    var lastNote: String? { lock.withLock { note } }

    /// Takes the shared hardware encoder at background priority. Exports
    /// (`.export` priority) jump ahead of every queued build.
    func acquireEncoder() async {
        guard let encoderLock, !lock.withLock({ holdsEncoder }) else { return }
        await encoderLock.acquire(priority: .background)
        lock.withLock { holdsEncoder = true }
    }

    func releaseEncoder() async {
        guard let encoderLock, lock.withLock({ holdsEncoder }) else { return }
        lock.withLock { holdsEncoder = false }
        await encoderLock.release()
    }

    /// Call between frames or chunks: throws if the job was cancelled,
    /// hands the encoder to a waiting export, and steps aside for a more
    /// urgent job, carrying on where it left off afterwards.
    func checkpoint() async throws {
        try checkCancellation()
        let holding = lock.withLock { holdsEncoder }
        if holding, let encoderLock {
            // An actor hop per frame is cheap, but there's no need for more
            // than a few checks a second.
            let now = Date()
            let due = lock.withLock { () -> Bool in
                guard now.timeIntervalSince(lastEncoderCheck) > 0.2 else { return false }
                lastEncoderCheck = now
                return true
            }
            if due, await encoderLock.hasWaiters(above: .background) {
                await encoderLock.release()
                await encoderLock.acquire(priority: .background)
            }
        }
        guard let scheduler else { return }
        if scheduler.shouldYield(id: id) {
            if holding { await releaseEncoder() }
            await scheduler.pause(id: id)
            try checkCancellation()
            if holding { await acquireEncoder() }
        }
    }
}

extension JobPriority {
    /// Background work runs at background QoS so the UI and playback stay
    /// smooth; someone waiting gets user-initiated.
    var taskPriority: TaskPriority {
        switch self {
        case .interactive: return .userInitiated
        case .timeline: return .utility
        case .background: return .background
        }
    }

    var qos: DispatchQoS {
        switch self {
        case .interactive: return .userInitiated
        case .timeline: return .utility
        case .background: return .background
        }
    }
}
