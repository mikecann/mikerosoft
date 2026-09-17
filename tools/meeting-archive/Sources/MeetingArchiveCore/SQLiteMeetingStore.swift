import CSQLite
import Foundation

public enum MeetingStoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case missingMeeting(UUID)
    case meetingMustBeAccepted(UUID)
    case jobMeetingMismatch(job: UUID, meeting: UUID)
    case missingJob(UUID)

    public var description: String {
        switch self {
        case .openFailed(let message): "Could not open Meeting Archive database: \(message)"
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .missingMeeting(let id): "Meeting does not exist: \(id.canonicalString)"
        case .meetingMustBeAccepted(let id): "Meeting must be accepted before queue insertion: \(id.canonicalString)"
        case .jobMeetingMismatch(let job, let meeting): "Job \(job.canonicalString) does not belong to meeting \(meeting.canonicalString)"
        case .missingJob(let id): "Archive job does not exist: \(id.canonicalString)"
        }
    }
}

public final class SQLiteMeetingStore: @unchecked Sendable {
    private let database: OpaquePointer
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw MeetingStoreError.openFailed(message)
        }
        database = opened
        sqlite3_busy_timeout(database, 5_000)

        do {
            try executeUnlocked("PRAGMA journal_mode=WAL")
            try executeUnlocked("PRAGMA foreign_keys=ON")
            try migrateUnlocked()
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    public func saveRecorderState(_ state: RecorderState) throws {
        let data = try ModelCodec.encoder.encode(state)
        try withLock {
            let statement = try prepareUnlocked(
                "INSERT INTO app_state(key, value) VALUES('recorder', ?) "
                    + "ON CONFLICT(key) DO UPDATE SET value=excluded.value"
            )
            defer { sqlite3_finalize(statement) }
            bind(data, to: 1, in: statement)
            try stepDoneUnlocked(statement)
        }
    }

    public func loadRecorderState() throws -> RecorderState {
        try withLock {
            let statement = try prepareUnlocked("SELECT value FROM app_state WHERE key='recorder'")
            defer { sqlite3_finalize(statement) }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return try ModelCodec.decoder.decode(RecorderState.self, from: data(from: statement, column: 0))
            case SQLITE_DONE:
                return RecorderState()
            default:
                throw lastErrorUnlocked()
            }
        }
    }

    public func insertMeeting(_ meeting: MeetingRecord) throws {
        try withLock { try insertMeetingUnlocked(meeting) }
    }

    public func updateMeeting(_ meeting: MeetingRecord) throws {
        try withLock { try updateMeetingUnlocked(meeting) }
    }

    public func fetchMeeting(id: UUID) throws -> MeetingRecord? {
        try withLock { try fetchMeetingUnlocked(id: id) }
    }

    public func listMeetings() throws -> [MeetingRecord] {
        try withLock {
            let statement = try prepareUnlocked("SELECT record FROM meetings ORDER BY id ASC")
            defer { sqlite3_finalize(statement) }
            var meetings: [MeetingRecord] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    meetings.append(try ModelCodec.decoder.decode(MeetingRecord.self, from: data(from: statement, column: 0)))
                case SQLITE_DONE:
                    return meetings
                default:
                    throw lastErrorUnlocked()
                }
            }
        }
    }

    @discardableResult
    public func resolveAcceptance(
        meetingID: UUID,
        resolution: AcceptanceResolution,
        at date: Date
    ) throws -> MeetingRecord {
        try withLock {
            try transactionUnlocked {
                guard let existing = try fetchMeetingUnlocked(id: meetingID) else {
                    throw MeetingStoreError.missingMeeting(meetingID)
                }
                let resolved = existing.resolvingAcceptance(resolution, at: date)
                if resolved != existing { try updateMeetingUnlocked(resolved) }
                return resolved
            }
        }
    }

    @discardableResult
    public func resolveAcceptance(
        id: UUID,
        resolution: AcceptanceResolution,
        at date: Date
    ) throws -> MeetingRecord {
        try resolveAcceptance(meetingID: id, resolution: resolution, at: date)
    }

    /// Resolves an already-persisted prompt and adds its first archive job in
    /// the same SQLite transaction. The unique meeting/revision key makes a
    /// retry safe after an uncertain caller result.
    @discardableResult
    public func resolveAcceptanceAndEnqueue(
        id: UUID,
        resolution: AcceptanceResolution,
        at date: Date,
        job: ArchiveJob
    ) throws -> MeetingRecord {
        guard job.meetingID == id else { throw MeetingStoreError.jobMeetingMismatch(job: job.id, meeting: id) }
        return try withLock {
            try transactionUnlocked {
                guard let existing = try fetchMeetingUnlocked(id: id) else {
                    throw MeetingStoreError.missingMeeting(id)
                }
                let resolved = existing.resolvingAcceptance(resolution, at: date)
                if resolved != existing { try updateMeetingUnlocked(resolved) }
                if case .accepted = resolved.acceptance { try insertJobUnlocked(job) }
                return resolved
            }
        }
    }

    /// Keeping the meeting and its first archive job in one transaction means
    /// an accepted meeting cannot be durable while its processing work is lost.
    public func insertAcceptedMeeting(_ meeting: MeetingRecord, job: ArchiveJob) throws {
        guard case .accepted = meeting.acceptance else { throw MeetingStoreError.meetingMustBeAccepted(meeting.id) }
        try withLock {
            try transactionUnlocked {
                try insertMeetingUnlocked(meeting)
                try insertJobUnlocked(job)
            }
        }
    }

    public func claimNextJob(now: Date, leaseDuration: TimeInterval) throws -> ArchiveJob? {
        try withLock {
            try transactionUnlocked {
                let query = try prepareUnlocked(
                    "SELECT record FROM archive_jobs "
                        + "WHERE status IN ('queued', 'retry_scheduled', 'leased') "
                        + "AND available_at <= ? AND (lease_until IS NULL OR lease_until <= ?) "
                        + "ORDER BY created_at ASC LIMIT 1"
                )
                defer { sqlite3_finalize(query) }
                sqlite3_bind_double(query, 1, now.timeIntervalSince1970)
                sqlite3_bind_double(query, 2, now.timeIntervalSince1970)
                let result = sqlite3_step(query)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW else { throw lastErrorUnlocked() }

                var job = try ModelCodec.decoder.decode(ArchiveJob.self, from: data(from: query, column: 0))
                job.leaseUntil = now.addingTimeInterval(leaseDuration)
                job.attemptCount += 1
                job.status = .leased
                job.lastError = nil
                try updateJobUnlocked(job)
                return job
            }
        }
    }

    public func completeJob(id: UUID) throws {
        try withLock {
            guard var job = try fetchJobUnlocked(id: id) else { throw MeetingStoreError.missingJob(id) }
            job.status = .succeeded
            job.leaseUntil = nil
            job.lastError = nil
            try updateJobUnlocked(job)
        }
    }

    public func fetchJob(id: UUID) throws -> ArchiveJob? {
        try withLock { try fetchJobUnlocked(id: id) }
    }

    public func listJobs() throws -> [ArchiveJob] {
        try withLock {
            let statement = try prepareUnlocked("SELECT record FROM archive_jobs ORDER BY created_at ASC, id ASC")
            defer { sqlite3_finalize(statement) }
            var jobs: [ArchiveJob] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    jobs.append(try ModelCodec.decoder.decode(ArchiveJob.self, from: data(from: statement, column: 0)))
                case SQLITE_DONE:
                    return jobs
                default:
                    throw lastErrorUnlocked()
                }
            }
        }
    }

    public func scheduleRetry(jobID: UUID, availableAt: Date, error: String) throws {
        try withLock {
            guard var job = try fetchJobUnlocked(id: jobID) else { throw MeetingStoreError.missingJob(jobID) }
            job.status = .retryScheduled
            job.availableAt = availableAt
            job.leaseUntil = nil
            job.lastError = error
            try updateJobUnlocked(job)
        }
    }

    public func acknowledgeJob(id: UUID, acknowledgement: ArchiveAcknowledgement) throws {
        try withLock {
            guard var job = try fetchJobUnlocked(id: id) else { throw MeetingStoreError.missingJob(id) }
            guard acknowledgement.meetingID == job.meetingID,
                  acknowledgement.manifestRevision == job.manifestRevision
            else { throw MeetingStoreError.jobMeetingMismatch(job: id, meeting: job.meetingID) }
            job.status = .succeeded
            job.leaseUntil = nil
            job.lastError = nil
            job.acknowledgement = acknowledgement
            try updateJobUnlocked(job)
        }
    }

    private func migrateUnlocked() throws {
        try executeUnlocked(
            "CREATE TABLE IF NOT EXISTS app_state ("
                + "key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)"
        )
        try executeUnlocked(
            "CREATE TABLE IF NOT EXISTS meetings ("
                + "id TEXT PRIMARY KEY NOT NULL, record BLOB NOT NULL)"
        )
        try executeUnlocked(
            "CREATE TABLE IF NOT EXISTS archive_jobs ("
                + "id TEXT PRIMARY KEY NOT NULL, meeting_id TEXT NOT NULL, record BLOB NOT NULL, "
                + "manifest_revision INTEGER NOT NULL, created_at REAL NOT NULL, available_at REAL NOT NULL, "
                + "lease_until REAL, status TEXT NOT NULL, "
                + "FOREIGN KEY(meeting_id) REFERENCES meetings(id))"
        )
        try executeUnlocked("CREATE INDEX IF NOT EXISTS archive_jobs_claim ON archive_jobs(available_at, lease_until, created_at)")
        try executeUnlocked("CREATE UNIQUE INDEX IF NOT EXISTS archive_jobs_meeting_revision ON archive_jobs(meeting_id, manifest_revision)")
        try executeUnlocked("PRAGMA user_version=1")
    }

    private func insertMeetingUnlocked(_ meeting: MeetingRecord) throws {
        let statement = try prepareUnlocked("INSERT INTO meetings(id, record) VALUES(?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(meeting.id.canonicalString, to: 1, in: statement)
        bind(try ModelCodec.encoder.encode(meeting), to: 2, in: statement)
        try stepDoneUnlocked(statement)
    }

    private func updateMeetingUnlocked(_ meeting: MeetingRecord) throws {
        let statement = try prepareUnlocked("UPDATE meetings SET record=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(try ModelCodec.encoder.encode(meeting), to: 1, in: statement)
        bind(meeting.id.canonicalString, to: 2, in: statement)
        try stepDoneUnlocked(statement)
        guard sqlite3_changes(database) == 1 else { throw MeetingStoreError.missingMeeting(meeting.id) }
    }

    private func fetchMeetingUnlocked(id: UUID) throws -> MeetingRecord? {
        let statement = try prepareUnlocked("SELECT record FROM meetings WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.canonicalString, to: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try ModelCodec.decoder.decode(MeetingRecord.self, from: data(from: statement, column: 0))
        case SQLITE_DONE:
            return nil
        default:
            throw lastErrorUnlocked()
        }
    }

    private func insertJobUnlocked(_ job: ArchiveJob) throws {
        let statement = try prepareUnlocked(
            "INSERT OR IGNORE INTO archive_jobs(id, meeting_id, record, manifest_revision, created_at, available_at, lease_until, status) VALUES(?, ?, ?, ?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        bind(job.id.canonicalString, to: 1, in: statement)
        bind(job.meetingID.canonicalString, to: 2, in: statement)
        bind(try ModelCodec.encoder.encode(job), to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, sqlite3_int64(job.manifestRevision))
        sqlite3_bind_double(statement, 5, job.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, job.availableAt.timeIntervalSince1970)
        bindOptionalDate(job.leaseUntil, to: 7, in: statement)
        bind(job.status.rawValue, to: 8, in: statement)
        try stepDoneUnlocked(statement)
    }

    private func updateJobUnlocked(_ job: ArchiveJob) throws {
        let statement = try prepareUnlocked("UPDATE archive_jobs SET record=?, available_at=?, lease_until=?, status=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(try ModelCodec.encoder.encode(job), to: 1, in: statement)
        sqlite3_bind_double(statement, 2, job.availableAt.timeIntervalSince1970)
        bindOptionalDate(job.leaseUntil, to: 3, in: statement)
        bind(job.status.rawValue, to: 4, in: statement)
        bind(job.id.canonicalString, to: 5, in: statement)
        try stepDoneUnlocked(statement)
    }

    private func fetchJobUnlocked(id: UUID) throws -> ArchiveJob? {
        let statement = try prepareUnlocked("SELECT record FROM archive_jobs WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.canonicalString, to: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try ModelCodec.decoder.decode(ArchiveJob.self, from: data(from: statement, column: 0))
        case SQLITE_DONE:
            return nil
        default:
            throw lastErrorUnlocked()
        }
    }

    private func transactionUnlocked<T>(_ body: () throws -> T) throws -> T {
        try executeUnlocked("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try executeUnlocked("COMMIT")
            return value
        } catch {
            try? executeUnlocked("ROLLBACK")
            throw error
        }
    }

    private func executeUnlocked(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw MeetingStoreError.sqlite(code: result, message: message)
        }
    }

    private func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw lastErrorUnlocked(code: result) }
        return statement
    }

    private func stepDoneUnlocked(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw lastErrorUnlocked(code: result) }
    }

    private func lastErrorUnlocked(code: Int32? = nil) -> MeetingStoreError {
        MeetingStoreError.sqlite(code: code ?? sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
    }

    private func bindOptionalDate(_ value: Date?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func data(from statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
