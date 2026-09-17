import Foundation
import XCTest
@testable import MeetingArchiveApp

final class WorkerStatusTests: XCTestCase {
    func testScopedResponseDerivesProcessingPublishedAndAttentionStates() throws {
        let queuedID = UUID()
        let publishedID = UUID()
        let failedID = UUID()
        let data = statusFixture(
            jobs: [
                job(id: 1, meetingID: queuedID, state: "ready"),
                job(id: 2, meetingID: publishedID, state: "succeeded"),
                job(id: 3, meetingID: failedID, state: "permanent_failure", error: "audio is corrupt"),
            ],
            publications: [
                publication(processingJobID: 2, state: "succeeded"),
            ]
        )

        let response = try JSONDecoder().decode(WorkerStatusResponse.self, from: data)
        let statuses = try response.statuses(for: [queuedID, publishedID, failedID])

        XCTAssertEqual(statuses[queuedID]?.phase, .processing)
        XCTAssertEqual(statuses[queuedID]?.speakerReview, .waitingForProcessing)
        XCTAssertEqual(statuses[publishedID]?.phase, .published)
        XCTAssertEqual(statuses[publishedID]?.speakerReview, .available)
        XCTAssertEqual(statuses[failedID]?.phase, .needsAttention)
        XCTAssertEqual(statuses[failedID]?.retryStage, .processing)
        XCTAssertEqual(statuses[failedID]?.lastError, "audio is corrupt")
        XCTAssertEqual(statuses[publishedID]?.manifestRevision, 1)
        XCTAssertNil(statuses[publishedID]?.totalSpeakerCount)
        XCTAssertNil(statuses[publishedID]?.unconfirmedSpeakerCount)
    }

    func testSpeakerCountsAndCurrentRevisionReachStatusDetails() throws {
        let queuedID = UUID()
        let activeID = UUID()
        let publishedID = UUID()
        let completeID = UUID()
        let response = try JSONDecoder().decode(
            WorkerStatusResponse.self,
            from: statusFixture(
                jobs: [
                    job(id: 20, meetingID: queuedID, state: "ready"),
                    job(id: 21, meetingID: activeID, state: "leased"),
                    job(
                        id: 22,
                        meetingID: publishedID,
                        state: "succeeded",
                        totalSpeakerCount: 3,
                        unconfirmedSpeakerCount: 2
                    ),
                    job(
                        id: 23,
                        meetingID: completeID,
                        state: "succeeded",
                        totalSpeakerCount: 2,
                        unconfirmedSpeakerCount: 0
                    ),
                ],
                publications: [
                    publication(processingJobID: 22, state: "succeeded"),
                    publication(processingJobID: 23, state: "publishing"),
                ]
            )
        )

        let statuses = try response.statuses(
            for: [queuedID, activeID, publishedID, completeID]
        )

        XCTAssertEqual(statuses[queuedID]?.detail, "Archived • transcription and speaker separation queued")
        XCTAssertEqual(statuses[activeID]?.detail, "Transcribing and separating speakers")
        XCTAssertEqual(statuses[publishedID]?.manifestRevision, 1)
        XCTAssertEqual(statuses[publishedID]?.totalSpeakerCount, 3)
        XCTAssertEqual(statuses[publishedID]?.unconfirmedSpeakerCount, 2)
        XCTAssertEqual(statuses[publishedID]?.detail, "Published to Notion • 2 speakers need names")
        XCTAssertEqual(statuses[completeID]?.detail, "Speaker review complete • publishing to Notion")
    }

    func testRejectsPartialOrImpossibleSpeakerCounts() throws {
        let meetingID = UUID()
        for counts in [(2, nil), (nil, 1), (1, 2), (-1, 0)] as [(Int?, Int?)] {
            let response = try JSONDecoder().decode(
                WorkerStatusResponse.self,
                from: statusFixture(
                    jobs: [
                        job(
                            id: 30,
                            meetingID: meetingID,
                            state: "succeeded",
                            totalSpeakerCount: counts.0,
                            unconfirmedSpeakerCount: counts.1
                        ),
                    ],
                    publications: []
                )
            )

            XCTAssertThrowsError(try response.statuses(for: [meetingID]))
        }
    }

    func testPublicationIsJoinedToItsProcessingJobRatherThanGlobalPhase() throws {
        let publishingID = UUID()
        let failedID = UUID()
        let response = try JSONDecoder().decode(
            WorkerStatusResponse.self,
            from: statusFixture(
                jobs: [
                    job(id: 10, meetingID: publishingID, state: "succeeded"),
                    job(id: 11, meetingID: failedID, state: "succeeded"),
                ],
                publications: [
                    publication(processingJobID: 10, state: "publishing"),
                    publication(processingJobID: 11, state: "retry_wait", error: "Notion offline"),
                ]
            )
        )

        let statuses = try response.statuses(for: [publishingID, failedID])

        XCTAssertEqual(statuses[publishingID]?.phase, .processing)
        XCTAssertEqual(statuses[publishingID]?.publicationState, .publishing)
        XCTAssertEqual(statuses[failedID]?.phase, .needsAttention)
        XCTAssertEqual(statuses[failedID]?.retryStage, .publication)
        XCTAssertEqual(statuses[failedID]?.lastError, "Notion offline")
    }

    func testMissingScopedJobIsReportedAsArchivedWithoutInventingProcessingState() throws {
        let meetingID = UUID()
        let response = try JSONDecoder().decode(
            WorkerStatusResponse.self,
            from: statusFixture(jobs: [], publications: [])
        )

        let status = try XCTUnwrap(response.statuses(for: [meetingID])[meetingID])

        XCTAssertEqual(status.phase, .archived)
        XCTAssertNil(status.processingState)
        XCTAssertEqual(status.detail, "Archived on Bruce; processing status is not available")
    }

    func testStatusCommandQuotesOneBoundedRemoteCommandAndAllMeetingIDs() throws {
        let ids = [UUID(), UUID()]
        let request = try WorkerStatusCommandBuilder.status(
            meetingIDs: ids,
            configuration: .bruce
        )

        XCTAssertEqual(request.executable.path, "/usr/bin/ssh")
        let command = try XCTUnwrap(request.arguments.last)
        XCTAssertTrue(command.contains("'status' '--db'"))
        for id in ids {
            XCTAssertTrue(command.contains("'--meeting-id' '\(id.uuidString.lowercased())'"))
        }
        XCTAssertThrowsError(
            try WorkerStatusCommandBuilder.status(
                meetingIDs: (0 ... 100).map { _ in UUID() },
                configuration: .bruce
            )
        )
    }

    func testClientCachesOneScopedRequestAndForcedRefreshRunsAgain() async throws {
        let meetingID = UUID()
        let fixture = statusFixture(
            jobs: [job(id: 1, meetingID: meetingID, state: "ready")],
            publications: []
        )
        let runner = WorkerStatusStubRunner(results: [
            .init(exitCode: 0, stdout: fixture, stderr: ""),
            .init(exitCode: 0, stdout: fixture, stderr: ""),
        ])
        let client = WorkerStatusClient(processRunner: runner, cacheDuration: 60)

        _ = try await client.fetch(meetingIDs: [meetingID], configuration: .bruce)
        _ = try await client.fetch(meetingIDs: [meetingID], configuration: .bruce)
        _ = try await client.fetch(meetingIDs: [meetingID], configuration: .bruce, force: true)

        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testRetryValidatesIdentityAndInvalidatesCachedStatus() async throws {
        let meetingID = UUID()
        let status = statusFixture(
            jobs: [job(id: 3, meetingID: meetingID, state: "permanent_failure", error: "bad")],
            publications: []
        )
        let retry = Data("""
        {"schema_version":1,"meeting_id":"\(meetingID.uuidString.lowercased())","retried":true,
         "processing":{"job_id":3,"state":"ready","retried":true},"publication":null}
        """.utf8)
        let refreshed = statusFixture(
            jobs: [job(id: 3, meetingID: meetingID, state: "ready")],
            publications: []
        )
        let runner = WorkerStatusStubRunner(results: [
            .init(exitCode: 0, stdout: status, stderr: ""),
            .init(exitCode: 0, stdout: retry, stderr: ""),
            .init(exitCode: 0, stdout: refreshed, stderr: ""),
        ])
        let client = WorkerStatusClient(processRunner: runner, cacheDuration: 60)
        _ = try await client.fetch(meetingIDs: [meetingID], configuration: .bruce)

        let result = try await client.retry(meetingID: meetingID, configuration: .bruce)
        let after = try await client.fetch(meetingIDs: [meetingID], configuration: .bruce)

        XCTAssertTrue(result.retried)
        XCTAssertEqual(after[meetingID]?.processingState, .ready)
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(try XCTUnwrap(requests[1].arguments.last).contains("'retry'"))
    }

    func testRetryWaitsForOlderStatusRequestSoStaleResponseCannotWin() async throws {
        let meetingID = UUID()
        let failedStatus = statusFixture(
            jobs: [job(id: 9, meetingID: meetingID, state: "permanent_failure", error: "old failure")],
            publications: []
        )
        let retry = Data("""
        {"schema_version":1,"meeting_id":"\(meetingID.uuidString.lowercased())","retried":true,
         "processing":{"job_id":9,"state":"ready","retried":true},"publication":null}
        """.utf8)
        let readyStatus = statusFixture(
            jobs: [job(id: 9, meetingID: meetingID, state: "ready")],
            publications: []
        )
        let runner = OrderedWorkerStatusRunner(results: [
            .init(exitCode: 0, stdout: failedStatus, stderr: ""),
            .init(exitCode: 0, stdout: retry, stderr: ""),
            .init(exitCode: 0, stdout: readyStatus, stderr: ""),
        ])
        let client = WorkerStatusClient(processRunner: runner, cacheDuration: 60)

        let oldFetch = Task {
            try await client.fetch(
                meetingIDs: [meetingID],
                configuration: .bruce,
                force: true
            )
        }
        await runner.waitForFirstRequest()
        let retryTask = Task {
            try await client.retry(meetingID: meetingID, configuration: .bruce)
        }
        await Task.yield()

        let blockedRequestCount = await runner.requestCount()
        XCTAssertEqual(blockedRequestCount, 1)
        await runner.releaseFirstRequest()
        let oldStatus = try await oldFetch.value
        let retryResult = try await retryTask.value
        XCTAssertEqual(oldStatus[meetingID]?.phase, .needsAttention)
        XCTAssertTrue(retryResult.retried)

        let refreshed = try await client.fetch(
            meetingIDs: [meetingID],
            configuration: .bruce,
            force: true
        )

        XCTAssertEqual(refreshed[meetingID]?.phase, .processing)
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(try XCTUnwrap(requests[0].arguments.last).contains("'status'"))
        XCTAssertTrue(try XCTUnwrap(requests[1].arguments.last).contains("'retry'"))
        XCTAssertTrue(try XCTUnwrap(requests[2].arguments.last).contains("'status'"))
    }

    func testCachedStatusDoesNotBypassRetryInFlight() async throws {
        let meetingID = UUID()
        let failedStatus = statusFixture(
            jobs: [job(id: 12, meetingID: meetingID, state: "permanent_failure", error: "old failure")],
            publications: []
        )
        let retry = Data("""
        {"schema_version":1,"meeting_id":"\(meetingID.uuidString.lowercased())","retried":true,
         "processing":{"job_id":12,"state":"ready","retried":true},"publication":null}
        """.utf8)
        let readyStatus = statusFixture(
            jobs: [job(id: 12, meetingID: meetingID, state: "ready")],
            publications: []
        )
        let runner = RetryBlockingWorkerStatusRunner(results: [
            .init(exitCode: 0, stdout: failedStatus, stderr: ""),
            .init(exitCode: 0, stdout: retry, stderr: ""),
            .init(exitCode: 0, stdout: readyStatus, stderr: ""),
        ])
        let client = WorkerStatusClient(processRunner: runner, cacheDuration: 60)
        _ = try await client.fetch(meetingIDs: [meetingID], configuration: .bruce)

        let retryTask = Task {
            try await client.retry(meetingID: meetingID, configuration: .bruce)
        }
        await runner.waitForRetryRequest()
        let refreshDuringRetry = Task {
            try await client.fetch(meetingIDs: [meetingID], configuration: .bruce)
        }
        await Task.yield()
        await runner.releaseRetryRequest()
        _ = try await retryTask.value
        let refreshed = try await refreshDuringRetry.value

        XCTAssertEqual(refreshed[meetingID]?.phase, .processing)
        let requestCount = await runner.requestCount()
        XCTAssertEqual(requestCount, 3)
    }

    private func statusFixture(jobs: [[String: Any]], publications: [[String: Any]]) -> Data {
        let value: [String: Any] = [
            "schema_version": 1,
            "counts": [:],
            "jobs": jobs,
            "publication": [
                "counts": [:],
                "phase": publications.isEmpty ? "not_queued" : "succeeded",
                "last_error": NSNull(),
                "jobs": publications,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: value)
    }

    private func job(
        id: Int,
        meetingID: UUID,
        state: String,
        error: String? = nil,
        totalSpeakerCount: Int? = nil,
        unconfirmedSpeakerCount: Int? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "meeting_id": meetingID.uuidString.lowercased(),
            "manifest_revision": 1,
            "manifest_sha256": String(repeating: "a", count: 64),
            "archive_path": "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/\(meetingID.uuidString.lowercased())",
            "state": state,
            "attempts": state == "ready" ? 0 : 1,
            "available_at": 100.0,
            "lease_owner": NSNull(),
            "lease_expires_at": NSNull(),
            "last_error": error ?? NSNull(),
        ]
        if let totalSpeakerCount {
            value["total_speaker_count"] = totalSpeakerCount
        }
        if let unconfirmedSpeakerCount {
            value["unconfirmed_speaker_count"] = unconfirmedSpeakerCount
        }
        return value
    }

    private func publication(
        processingJobID: Int,
        state: String,
        error: String? = nil
    ) -> [String: Any] {
        [
            "processing_job_id": processingJobID,
            "archive_path": "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/id",
            "state": state,
            "attempts": 1,
            "available_at": 100.0,
            "last_error": error ?? NSNull(),
            "lease_owner": NSNull(),
            "lease_expires_at": NSNull(),
            "refresh_requested": 0,
        ]
    }
}

private actor WorkerStatusStubRunner: ArchiveProcessRunning {
    private var results: [ArchiveProcessResult]
    private var requests: [ArchiveProcessRequest] = []

    init(results: [ArchiveProcessResult]) {
        self.results = results
    }

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        requests.append(request)
        guard !results.isEmpty else {
            throw WorkerStatusError.invalidResponse("Unexpected process request")
        }
        return results.removeFirst()
    }

    func recordedRequests() -> [ArchiveProcessRequest] { requests }
}

private actor OrderedWorkerStatusRunner: ArchiveProcessRunning {
    private var results: [ArchiveProcessResult]
    private var requests: [ArchiveProcessRequest] = []
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRequestRelease: CheckedContinuation<Void, Never>?

    init(results: [ArchiveProcessResult]) {
        self.results = results
    }

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        requests.append(request)
        if requests.count == 1 {
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstRequestRelease = continuation
            }
        }
        guard !results.isEmpty else {
            throw WorkerStatusError.invalidResponse("Unexpected process request")
        }
        return results.removeFirst()
    }

    func waitForFirstRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func releaseFirstRequest() {
        firstRequestRelease?.resume()
        firstRequestRelease = nil
    }

    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [ArchiveProcessRequest] { requests }
}

private actor RetryBlockingWorkerStatusRunner: ArchiveProcessRunning {
    private var results: [ArchiveProcessResult]
    private var requests: [ArchiveProcessRequest] = []
    private var retryWaiters: [CheckedContinuation<Void, Never>] = []
    private var retryRelease: CheckedContinuation<Void, Never>?

    init(results: [ArchiveProcessResult]) {
        self.results = results
    }

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        requests.append(request)
        if requests.count == 2 {
            let waiters = retryWaiters
            retryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                retryRelease = continuation
            }
        }
        guard !results.isEmpty else {
            throw WorkerStatusError.invalidResponse("Unexpected process request")
        }
        return results.removeFirst()
    }

    func waitForRetryRequest() async {
        if requests.count >= 2 { return }
        await withCheckedContinuation { continuation in
            retryWaiters.append(continuation)
        }
    }

    func releaseRetryRequest() {
        retryRelease?.resume()
        retryRelease = nil
    }

    func requestCount() -> Int { requests.count }
}
