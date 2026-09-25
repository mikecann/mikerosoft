import XCTest
@testable import TandemMedia

/// Opens once; everyone waiting (and anyone who waits later) carries on.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    var opened: Bool { lock.withLock { isOpen } }
}

/// Thread-safe list of what happened, in order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var counters: [String: (now: Int, peak: Int)] = [:]

    func add(_ event: String) { lock.withLock { items.append(event) } }
    var events: [String] { lock.withLock { items } }

    func enter(_ group: String) {
        lock.withLock {
            var counter = counters[group] ?? (0, 0)
            counter.now += 1
            counter.peak = max(counter.peak, counter.now)
            counters[group] = counter
        }
    }

    func leave(_ group: String) { lock.withLock { counters[group]?.now -= 1 } }
    func peak(_ group: String) -> Int { lock.withLock { counters[group]?.peak ?? 0 } }
}

final class JobSchedulerTests: XCTestCase {
    func job(_ id: String, _ kind: AnalysisKind, _ priority: JobPriority, _ work: @escaping @Sendable (JobContext) async throws -> Void) -> JobScheduler.Job {
        JobScheduler.Job(id: id, kind: kind, mediaID: "med_\(id)", priority: priority, work: work)
    }

    func oneAtATime() -> JobScheduler {
        var limits = JobScheduler.Limits.standard
        limits.total = 1
        return JobScheduler(limits: limits, encoderLock: EncoderLock())
    }

    func testRunsMostUrgentThenCheapestThenOldest() async {
        let scheduler = oneAtATime()
        let gate = Gate()
        let log = EventLog()
        scheduler.submit(job("block", .waveform, .background) { _ in log.add("block"); await gate.wait() })
        for (id, kind, priority) in [("A", AnalysisKind.thumbnails, JobPriority.background), ("B", .matte, .timeline), ("C", .proxy, .interactive), ("D", .waveform, .timeline), ("E", .waveform, .timeline)] {
            scheduler.submit(job(id, kind, priority) { _ in log.add(id) })
        }
        XCTAssertEqual(scheduler.statuses.map(\.id), ["block", "C", "D", "E", "B", "A"])
        gate.open()
        for id in ["A", "B", "C", "D", "E"] { _ = await scheduler.wait(for: id) }
        XCTAssertEqual(log.events, ["block", "C", "D", "E", "B", "A"])
    }

    func testSameJobRunsOnceAndAskingAgainCanRaiseItsPriority() async {
        let scheduler = oneAtATime()
        let gate = Gate()
        let log = EventLog()
        scheduler.submit(job("block", .waveform, .background) { _ in await gate.wait() })
        scheduler.submit(job("X", .loudness, .background) { _ in log.add("X") })
        scheduler.submit(job("Y", .loudness, .background) { _ in log.add("Y") })
        scheduler.submit(job("Y", .loudness, .background) { _ in log.add("Y again") })
        scheduler.submit(job("X", .loudness, .background) { _ in log.add("X again") })
        scheduler.submit(job("Y", .loudness, .interactive) { _ in log.add("Y again") })
        gate.open()
        _ = await scheduler.wait(for: "X")
        _ = await scheduler.wait(for: "Y")
        XCTAssertEqual(log.events, ["Y", "X"])
    }

    func testPerKindAndEncoderLimits() async {
        let scheduler = JobScheduler(limits: .standard, encoderLock: EncoderLock())
        let log = EventLog()
        func work(_ group: String) -> @Sendable (JobContext) async throws -> Void {
            { _ in
                log.enter(group)
                try await Task.sleep(nanoseconds: 30_000_000)
                log.leave(group)
            }
        }
        var ids: [String] = []
        for i in 0..<4 { ids.append(scheduler.submit(job("thumb\(i)", .thumbnails, .background, work("thumbnails")))) }
        for i in 0..<2 { ids.append(scheduler.submit(job("proxy\(i)", .proxy, .background, work("encoder")))) }
        for i in 0..<2 { ids.append(scheduler.submit(job("matte\(i)", .matte, .background, work("encoder")))) }
        for id in ids { _ = await scheduler.wait(for: id) }
        XCTAssertEqual(log.peak("thumbnails"), 2)
        XCTAssertEqual(log.peak("encoder"), 1)
    }

    func testCancellingQueuedAndRunningJobs() async throws {
        let scheduler = oneAtATime()
        let started = Gate()
        let log = EventLog()
        scheduler.submit(job("long", .matte, .background) { context in
            started.open()
            while true {
                try await context.checkpoint()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        })
        scheduler.submit(job("never", .thumbnails, .background) { _ in log.add("never") })
        await started.wait()

        scheduler.cancel(id: "never")
        XCTAssertEqual(scheduler.status(id: "never")?.state, .cancelled)
        scheduler.cancel(id: "long")
        let final = await scheduler.wait(for: "long")
        XCTAssertEqual(final?.state, .cancelled)
        XCTAssertEqual(log.events, [])

        // cancelAll clears everything that's left.
        let gate = Gate()
        scheduler.submit(job("a", .waveform, .background) { _ in await gate.wait() })
        scheduler.submit(job("b", .waveform, .background) { _ in log.add("b") })
        scheduler.cancelAll()
        gate.open()
        _ = await scheduler.wait(for: "a")
        XCTAssertEqual(scheduler.status(id: "b")?.state, .cancelled)
        XCTAssertEqual(log.events, [])
    }

    func testProgressReachesObservers() async throws {
        let scheduler = JobScheduler(encoderLock: EncoderLock())
        let gate = Gate()
        let halfway = expectation(description: "observer sees 50%")
        let done = expectation(description: "observer sees done")
        let seen = EventLog()
        let token = scheduler.observe { statuses in
            guard let status = statuses.first(where: { $0.id == "p" }) else { return }
            if status.state == .running, status.progress == 0.5, status.message == "half", !seen.events.contains("half") {
                seen.add("half")
                halfway.fulfill()
            }
            if status.state == .done, !seen.events.contains("done") {
                seen.add("done")
                done.fulfill()
            }
        }
        scheduler.submit(job("p", .transcript, .timeline) { context in
            context.progress(0.5, message: "half")
            await gate.wait()
        })
        await fulfillment(of: [halfway], timeout: 5)
        gate.open()
        await fulfillment(of: [done], timeout: 5)
        scheduler.removeObserver(token)
        XCTAssertEqual(scheduler.status(id: "p")?.progress, 1)
    }

    func testFailuresCarryTheirMessage() async {
        let scheduler = JobScheduler(encoderLock: EncoderLock())
        scheduler.submit(job("f", .loudness, .background) { _ in throw MediaError.failed("no audio track") })
        let final = await scheduler.wait(for: "f")
        XCTAssertEqual(final?.state, .failed)
        XCTAssertEqual(final?.message, "no audio track")
    }

    func testLongBackgroundJobStepsAsideForUrgentWork() async throws {
        let scheduler = JobScheduler(limits: .standard, encoderLock: EncoderLock())
        let log = EventLog()
        let running = Gate()
        let urgentDone = Gate()
        scheduler.submit(job("matte", .matte, .background) { context in
            await context.acquireEncoder()
            log.add("matte start")
            for i in 0..<3000 {
                try await context.checkpoint()
                if i == 3 { running.open() }
                if urgentDone.opened { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            log.add("matte end")
        })
        await running.wait()
        scheduler.submit(job("proxy", .proxy, .timeline) { context in
            await context.acquireEncoder()
            log.add("proxy")
            urgentDone.open()
        })
        _ = await scheduler.wait(for: "proxy")
        let matte = await scheduler.wait(for: "matte")
        XCTAssertEqual(matte?.state, .done)
        XCTAssertEqual(log.events, ["matte start", "proxy", "matte end"])
    }

    func testEncoderIsHandedToAnExportBetweenFrames() async throws {
        let lock = EncoderLock()
        let scheduler = JobScheduler(encoderLock: lock)
        let log = EventLog()
        let holding = Gate()
        let exportDone = Gate()
        scheduler.submit(job("proxy", .proxy, .background) { context in
            await context.acquireEncoder()
            holding.open()
            for _ in 0..<5000 {
                try await context.checkpoint()
                if exportDone.opened { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            log.add("proxy end")
        })
        await holding.wait()
        await lock.acquire(priority: .export)
        log.add("export")
        await lock.release()
        exportDone.open()
        _ = await scheduler.wait(for: "proxy")
        XCTAssertEqual(log.events, ["export", "proxy end"])
        let busy = await lock.isBusy
        XCTAssertFalse(busy, "the job gives the encoder back when it ends")
    }
}
