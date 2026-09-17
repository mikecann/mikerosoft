import AppKit
import AVFoundation
import Combine
import MeetingArchiveCore
import UserNotifications

struct CaptureJournal: Codable {
    let id: UUID
    let session: MeetingSessionDescriptor
    let startedAt: Date
    let microphoneUID: String
    let microphoneName: String
}

@MainActor
final class ArchiveController: ObservableObject {
    @Published var status = "Starting…"
    @Published var failure: String?
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var meetings: [MeetingRecord] = []
    @Published var jobs: [ArchiveJob] = []
    @Published var workerStatuses: [UUID: WorkerMeetingStatus] = [:]
    @Published var workerStatusFailure: String?
    @Published var pending: MeetingRecord?
    @Published var titleDraft = ""
    @Published var calendarChoices: [CalendarSuggestion] = []
    @Published private(set) var followUpMeetingID: UUID?
    let settings = AppSettings()
    let calendar = CalendarService()
    private var store: SQLiteMeetingStore?
    private var machine = CaptureStateMachine()
    private var detector = MeetingSignalProvider()
    private var timer: Task<Void, Never>?
    private var recorder: NativeRecording?
    private var journal: CaptureJournal?
    private var captureLifecycle = CaptureLifecycleCoordinator()
    private var sourcesReady = false
    private var startupCompleted = false
    private var uploading = false
    private var lastQueuePoll = Date.distantPast
    private var lastWorkerStatusPoll = Date.distantPast
    private var cleanedMeetingIDs = Set<UUID>()
    private var lockFD: Int32 = -1
    private var pendingWindow: NSWindow?
    private var followUpWindow: NamingWindow?
    private var attentionTracker = SpeakerAttentionTracker()
    private var refreshingWorkerStatuses = false
    private var workerRefreshRequested = false
    private var hasPolledMeetingState = false
    private var meetingInteractionBlocksAttention = true
    private let transfer = ArchiveTransfer()
    private let workerStatusClient = WorkerStatusClient(cacheDuration: 10)

    init(startServices: Bool = true) {
        do {
            for directory in [AppPaths.root, AppPaths.spool, AppPaths.index] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            lockFD = open(AppPaths.root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            // Acquire before reading or restoring state. A second launch must
            // never turn the first instance's live session into crash recovery.
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
            let database = try SQLiteMeetingStore(url: AppPaths.root.appendingPathComponent("meetings.sqlite"))
            store = database
            machine = CaptureStateMachine(restoringPersistedState: try database.loadRecorderState())
            detector = MeetingSignalProvider(restoring: machine.state.currentSession?.descriptor)
            try database.saveRecorderState(machine.state)
        } catch {
            store = nil
            machine = CaptureStateMachine()
            detector = MeetingSignalProvider()
            failure = error.localizedDescription
        }
        isPaused = machine.state.isPaused
        if let data = try? Data(contentsOf: AppPaths.root.appendingPathComponent("speaker-attention.json")),
           let saved = try? JSONDecoder().decode(SpeakerAttentionTracker.self, from: data) {
            attentionTracker = saved
        }
        refresh()
        // The isolated UI verification harness uses the real controller and
        // views without polling devices, recording, uploading, or recovering.
        guard startServices else {
            hasPolledMeetingState = true
            meetingInteractionBlocksAttention = false
            return
        }
        timer = Task { [weak self] in
            await self?.recoverInterruptedCaptures()
            await self?.refreshWorkerStatuses()
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recorder != nil else { return }
                self.fail("Capture stopped because the Mac is going to sleep. The partial meeting will be saved.")
                if let entry = self.journal { self.dispatch(.captureInterrupted(sessionID: entry.session.id, at: Date())) }
            }
        }
    }

    func refresh() {
        do {
            meetings = try store?.listMeetings().sorted { $0.startedAt > $1.startedAt } ?? []
            jobs = try store?.listJobs() ?? []
        } catch { fail(error.localizedDescription) }
    }

    func refreshWorkerStatuses(force: Bool = false) async {
        guard !refreshingWorkerStatuses else {
            workerRefreshRequested = workerRefreshRequested || force
            return
        }
        refreshingWorkerStatuses = true
        defer {
            refreshingWorkerStatuses = false
            if workerRefreshRequested {
                workerRefreshRequested = false
                Task { await refreshWorkerStatuses(force: true) }
            }
        }
        lastWorkerStatusPoll = Date()
        var archivedIDs = meetings
            .filter { meeting in
                self.jobs.contains { job in
                    job.meetingID == meeting.id
                        && job.status == .succeeded
                        && job.acknowledgement != nil
                }
            }
            .map(\.id)
        // Opening an older recording must still fetch its review, even when
        // the routine recent-history batch is full.
        if let focused = followUpMeetingID, archivedIDs.contains(focused) {
            archivedIDs.removeAll { $0 == focused }
            archivedIDs.insert(focused, at: 0)
        }
        guard !archivedIDs.isEmpty else {
            workerStatuses = [:]
            workerStatusFailure = nil
            return
        }
        do {
            let fetched = try await workerStatusClient.fetch(
                meetingIDs: Array(archivedIDs.prefix(100)),
                configuration: transferConfiguration,
                force: force
            )
            workerStatuses.merge(fetched) { _, fresh in fresh }
            workerStatusFailure = nil
            presentReadySpeakerReview()
        } catch {
            workerStatusFailure = error.localizedDescription
        }
    }

    func retryWorker(_ meetingID: UUID) {
        Task {
            do {
                _ = try await workerStatusClient.retry(
                    meetingID: meetingID,
                    configuration: transferConfiguration
                )
                await refreshWorkerStatuses(force: true)
            } catch {
                workerStatusFailure = error.localizedDescription
            }
        }
    }

    private func tick() {
        guard store != nil else { return }
        let snapshot = detector.poll()
        hasPolledMeetingState = true
        // Unknown camera controls or missing Accessibility are not proof that
        // it is safe to raise a window over the user's current meeting.
        meetingInteractionBlocksAttention = !SpeakerAttentionTracker.interactionIsSafe(
            noSupportedMeeting: snapshot.status == .noSupportedMeeting, cameraActive: snapshot.cameraActive
        )
        recorder?.checkHealth()
        recorder?.setVideoAllowed(snapshot.videoSafe)
        if let session = snapshot.session {
            if snapshot.cameraActive == false { dispatch(.cameraOff(sessionID: session.id, at: Date()), windowID: snapshot.windowID) }
            else if snapshot.cameraActive == true, snapshot.videoSafe { dispatch(.cameraOn(session, at: Date()), windowID: snapshot.windowID) }
        }
        retryDeferredCapture(using: snapshot)
        if !isRecording, recorder == nil {
            if failure != nil { status = "Needs attention" }
            else if isPaused { status = "Paused" }
            else {
                switch snapshot.status {
                case .ready: status = "Meeting detected"
                case .noSupportedMeeting: status = "Waiting for a meeting camera"
                case .accessibilityPermissionRequired: status = "Enable Accessibility to detect meetings"
                case .ambiguous(let reason): status = reason
                }
            }
        } else if !snapshot.videoSafe, isRecording { status = "Recording audio • meeting video unavailable" }
        for meeting in meetings {
            if case .pending(let deadline) = meeting.acceptance, Date() >= deadline {
                resolve(meeting.id, resolution: .accept(trigger: .deadline))
            }
        }
        if !uploading, Date().timeIntervalSince(lastQueuePoll) >= 15 {
            lastQueuePoll = Date()
            Task { await uploadNext() }
        }
        if Date().timeIntervalSince(lastWorkerStatusPoll) >= (processingMeetings.isEmpty ? 60 : 15) {
            lastWorkerStatusPoll = Date()
            Task { await refreshWorkerStatuses() }
        }
        presentReadySpeakerReview()
    }

    private func dispatch(_ event: CaptureEvent, windowID: CGWindowID? = nil) {
        cancelExactStartupIfNeeded(for: event)
        let effects = machine.handle(event)
        do { try store?.saveRecorderState(machine.state) } catch { fail(error.localizedDescription); return }
        isPaused = machine.state.isPaused
        for effect in effects {
            switch effect {
            case .startCapture(let session):
                guard let windowID else { continue }
                let request = CaptureStartRequest(
                    session: session,
                    meetingID: UUID(),
                    windowID: windowID
                )
                if case .start(let request) = captureLifecycle.requestStart(request) {
                    Task { await start(request) }
                }
            case .stopCapture(let meetingID, let reason):
                if case .finalize(let request) = captureLifecycle.requestStop(meetingID: meetingID, reason: reason) {
                    Task { await finish(request) }
                }
            case .sessionSkipped: status = "Skipping this camera session"
            }
        }
    }

    private func cancelExactStartupIfNeeded(for event: CaptureEvent) {
        guard let current = machine.state.currentSession,
              current.phase == .startRequested,
              let recording = recorder,
              let entry = journal,
              entry.session.id == current.descriptor.id,
              captureLifecycle.ownsActiveStart(meetingID: entry.id)
        else { return }

        let makesStartIneligible: Bool = switch event {
        case .cameraOff(let sessionID, _), .captureInterrupted(let sessionID, _):
            sessionID == current.descriptor.id
        case .skipCurrent:
            true
        case .setPaused(let paused, _):
            paused
        case .cameraOn, .captureStarted, .applicationObserved:
            false
        }
        if makesStartIneligible {
            // The core intentionally emits no stop before a meeting ID is
            // registered. Cut the native startup gate synchronously instead.
            recording.cancelStartup()
        }
    }

    func togglePause() { dispatch(.setPaused(!isPaused, at: Date())) }
    func skip() { dispatch(.skipCurrent(at: Date())) }

    private func start(_ request: CaptureStartRequest) async {
        guard captureLifecycle.ownsActiveStart(meetingID: request.meetingID) else { return }
        guard let current = machine.state.currentSession,
              current.phase == .startRequested,
              current.descriptor == request.session else {
            resumeAfterAbortedStart(meetingID: request.meetingID)
            return
        }
        guard recorder == nil, journal == nil else { return }
        let session = request.session
        let recording = NativeRecording()
        let mic = AVCaptureDevice.default(for: .audio)
        let entry = CaptureJournal(id: request.meetingID, session: session, startedAt: Date(), microphoneUID: mic?.uniqueID ?? "system-default", microphoneName: mic?.localizedName ?? "System default microphone")
        let directory = AppPaths.meeting(entry.id)
        do {
            let capacity = try AppPaths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity > 2 * 1024 * 1024 * 1024 else { throw CaptureFailure.message("Less than 2 GB is available. Recording is paused to preserve existing meetings.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ModelCodec.encoder.encode(entry).write(to: directory.appendingPathComponent("capture-journal.json"), options: .atomic)
            recorder = recording
            journal = entry
            sourcesReady = false
            startupCompleted = false
            status = "Starting recording…"
            recording.onStarted = { [weak self] in
                Task { @MainActor in
                    guard let self, self.journal?.id == entry.id else { return }
                    self.sourcesReady = true
                    self.announceCaptureStart(entry)
                }
            }
            recording.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.journal?.id == entry.id else { return }
                    self.fail(message)
                    self.dispatch(.captureInterrupted(sessionID: entry.session.id, at: Date()))
                }
            }
            let outcome = try await recording.start(windowID: request.windowID, directory: directory)
            if outcome == .cancelled {
                guard recorder === recording, journal?.id == entry.id else { return }
                recorder = nil
                journal = nil
                sourcesReady = false
                startupCompleted = false
                isRecording = false
                removeJournalOnlyCaptureDirectory(directory)
                resumeAfterAbortedStart(meetingID: entry.id)
                return
            }
            // Register the live writer before its first callback. A camera-off
            // during async startup then resolves to a stop rather than a leak.
            dispatch(.captureStarted(sessionID: session.id, meetingID: entry.id, at: Date()))
            startupCompleted = true
            announceCaptureStart(entry)
        } catch {
            fail(error.localizedDescription)
            if recorder === recording, journal?.id == entry.id {
                if !recording.hasCapturedSamples {
                    dispatch(.captureInterrupted(sessionID: session.id, at: Date()))
                    recorder = nil
                    journal = nil
                    sourcesReady = false
                    startupCompleted = false
                    isRecording = false
                    removeJournalOnlyCaptureDirectory(directory)
                    resumeAfterAbortedStart(meetingID: entry.id)
                    return
                }
                // Even when start throws, it may have opened partial writers.
                // Route their cleanup through this meeting ID so a late
                // callback can never finalize a replacement meeting.
                dispatch(.captureStarted(sessionID: session.id, meetingID: entry.id, at: Date()))
                dispatch(.captureInterrupted(sessionID: session.id, at: Date()))
                if captureLifecycle.ownsActiveStart(meetingID: entry.id),
                   case .finalize(let finalization) = captureLifecycle.requestStop(meetingID: entry.id, reason: .interrupted) {
                    await finish(finalization)
                }
            } else {
                dispatch(.captureInterrupted(sessionID: session.id, at: Date()))
                resumeAfterAbortedStart(meetingID: entry.id)
            }
        }
    }

    private func removeJournalOnlyCaptureDirectory(_ directory: URL) {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
            guard try contents.allSatisfy({ url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return url.lastPathComponent == "capture-journal.json"
                    && values.isRegularFile == true
                    && values.isSymbolicLink != true
            }) else { return }
            try FileManager.default.removeItem(at: directory)
        } catch {
            // Cancellation is still complete. Retain anything unexpected for
            // recovery rather than risking deletion of real media.
        }
    }

    private func announceCaptureStart(_ entry: CaptureJournal) {
        guard sourcesReady, startupCompleted, !isRecording,
              captureLifecycle.ownsActiveStart(meetingID: entry.id),
              journal?.id == entry.id, machine.state.currentSession?.phase == .recording,
              machine.state.currentSession?.descriptor.id == entry.session.id else { return }
        isRecording = true
        status = "Recording meeting"
        notify("Recording started", body: "Meeting video, incoming audio and your microphone are being saved.", id: entry.id.uuidString + "-start")
    }

    private func finish(_ request: CaptureFinalizationRequest) async {
        guard captureLifecycle.isFinalizing(meetingID: request.meetingID),
              let recording = recorder,
              let entry = journal,
              entry.id == request.meetingID else { return }
        let ended = Date()
        let directory = AppPaths.meeting(entry.id)
        do {
            let tracks = try await recording.stop()
            try ModelCodec.encoder.encode(tracks).write(to: directory.appendingPathComponent("tracks.json"), options: .atomic)
        } catch { fail(error.localizedDescription) }
        recorder = nil
        journal = nil
        isRecording = false
        var meeting = makeRecord(entry, ended: ended)
        if request.discardAfterFinalization {
            meeting = meeting.resolvingAcceptance(.discard, at: Date())
            do {
                try store?.insertMeeting(meeting)
                try FileManager.default.removeItem(at: directory)
            } catch { fail(error.localizedDescription) }
            status = "Skipped this meeting"
        } else {
            do {
                let events = calendar.suggestions(start: entry.startedAt, end: ended, selectedCalendarIDs: settings.selectedCalendarIDs)
                if let match = CalendarRanking.best(events, start: entry.startedAt, end: ended) { meeting.title = match.title }
                try ModelCodec.encoder.encode(events).write(to: directory.appendingPathComponent("calendar.json"), options: .atomic)
                try store?.insertMeeting(meeting)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("capture-journal.json"))
                calendarChoices = events
                showPrompt(meeting)
                status = "Recording finished • preparing to save"
                notify("Recording finished", body: "Saving \(meeting.title). You can rename or discard it in the brief window.", id: entry.id.uuidString + "-finish")
            } catch { fail(error.localizedDescription) }
        }
        refresh()
        resumeAfterFinalization(meetingID: request.meetingID)
    }

    private func resumeAfterFinalization(meetingID: UUID) {
        _ = captureLifecycle.finalizationCompleted(
            meetingID: meetingID,
            recorderState: machine.state,
            safeWindow: nil
        )
    }

    private func resumeAfterAbortedStart(meetingID: UUID) {
        _ = captureLifecycle.startAborted(
            meetingID: meetingID,
            recorderState: machine.state,
            safeWindow: nil
        )
    }

    private func retryDeferredCapture(using snapshot: MeetingSignalSnapshot) {
        let safeWindow: SafeCaptureWindow?
        if snapshot.cameraActive == true,
           snapshot.videoSafe,
           let session = snapshot.session,
           let windowID = snapshot.windowID {
            safeWindow = SafeCaptureWindow(sessionID: session.id, windowID: windowID)
        } else {
            safeWindow = nil
        }
        if let request = captureLifecycle.retryDeferredStart(
            recorderState: machine.state,
            safeWindow: safeWindow
        ) {
            Task { await start(request) }
        }
    }

    private func makeRecord(_ entry: CaptureJournal, ended: Date) -> MeetingRecord {
        MeetingRecord(id: entry.id, title: "Meeting \(entry.startedAt.formatted(date: .abbreviated, time: .shortened))", sourceApplication: entry.session.sourceApplication, startedAt: entry.startedAt, endedAt: ended, timezoneIdentifier: TimeZone.current.identifier, video: .init(surfaceID: entry.session.surface.id, codec: "hevc", width: 1920, height: 1080), microphone: .init(deviceUID: entry.microphoneUID, displayName: entry.microphoneName, sampleRate: 48000, channels: 1), incomingAudio: .init(sourceApplicationBundleIdentifier: entry.session.sourceApplication.bundleIdentifier, sampleRate: 48000, channels: 2), finalizedAt: Date())
    }

    func resolve(_ id: UUID, resolution: AcceptanceResolution) {
        do {
            guard var record = try store?.fetchMeeting(id: id), record.acceptance.isPending else { return }
            let showProgress: Bool
            if pending?.id == id, case .accept(let trigger) = resolution {
                showProgress = trigger == .keepButton || trigger == .deadline
            } else { showProgress = false }
            if pending?.id == id, !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, titleDraft != record.title {
                record = record.updatingTitle(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines), at: Date())
                try store?.updateMeeting(record)
            }
            let job = ArchiveJob(meetingID: id, manifestRevision: record.metadataRevision, createdAt: Date())
            _ = try store?.resolveAcceptanceAndEnqueue(id: id, resolution: resolution, at: Date(), job: job)
            if case .discard = resolution { try FileManager.default.removeItem(at: AppPaths.meeting(id)) }
            if pending?.id == id { pending = nil; pendingWindow?.close(); pendingWindow = nil }
            refresh()
            if showProgress { showFollowUp(id) }
            if case .accept = resolution { Task { await uploadNext() } }
        } catch { fail(error.localizedDescription) }
    }

    func followUpPhase(for record: MeetingRecord) -> MeetingFollowUpPhase {
        guard let job = jobs.first(where: { $0.meetingID == record.id && $0.manifestRevision == record.metadataRevision }) else {
            return .checking
        }
        if let error = job.lastError, job.status != .succeeded { return .waiting("Transfer waiting to retry: \(error)") }
        guard job.status == .succeeded else { return .transferring }
        let remote = workerStatuses[record.id]
        return .afterArchive(
            expectedRevision: record.metadataRevision, workerRevision: remote?.manifestRevision,
            processingSucceeded: remote?.processingState == .succeeded,
            remainingNames: remote?.unconfirmedSpeakerCount,
            processingError: remote?.retryStage == .processing ? remote?.detail : nil,
            connectionError: workerStatusFailure
        )
    }

    var processingMeetings: [MeetingRecord] {
        meetings.filter { record in
            guard case .accepted = record.acceptance else { return false }
            return followUpPhase(for: record).isBusy
        }
    }

    var speakerAttentionCandidates: [SpeakerAttentionCandidate] {
        meetings.compactMap { record in
            guard case .accepted = record.acceptance,
                  let remote = workerStatuses[record.id],
                  remote.manifestRevision == record.metadataRevision,
                  remote.processingState == .succeeded,
                  let count = remote.unconfirmedSpeakerCount, count > 0 else { return nil }
            return SpeakerAttentionCandidate(meetingID: record.id, revision: record.metadataRevision, remainingCount: count)
        }
    }

    var meetingsNeedingSpeakerNames: [MeetingRecord] {
        let ids = Set(speakerAttentionCandidates.map(\.meetingID))
        return meetings.filter { ids.contains($0.id) }
    }

    var speakersNeedingNames: Int { speakerAttentionCandidates.reduce(0) { $0 + $1.remainingCount } }

    func showFollowUp(_ id: UUID, refreshStatus: Bool = true) {
        guard let record = meetings.first(where: { $0.id == id }) else { return }
        if followUpMeetingID != id {
            closeFollowUp()
            followUpMeetingID = id
            let panel = NamingWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = record.title
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: MeetingFollowUpView(controller: self, meetingID: id))
            panel.onClose = { [weak self] in
                self?.followUpMeetingID = nil
                self?.followUpWindow = nil
            }
            panel.center()
            followUpWindow = panel
        }
        if let candidate = speakerAttentionCandidates.first(where: { $0.meetingID == id }) {
            markSpeakerAttentionPresented(candidate)
        }
        followUpWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if refreshStatus, jobs.contains(where: { $0.meetingID == id && $0.status == .succeeded && $0.acknowledgement != nil }) {
            Task { await refreshWorkerStatuses(force: true) }
        }
    }

    func closeFollowUp() { followUpWindow?.close() }

    func speakerReviewChanged() { Task { await refreshWorkerStatuses(force: true) } }

    private func presentReadySpeakerReview() {
        // Finish the current call and its title prompt before bringing another
        // meeting's review forward. The menu indicator remains available.
        let blocked = !hasPolledMeetingState || meetingInteractionBlocksAttention || isRecording || recorder != nil || pending != nil
        let candidates = speakerAttentionCandidates.filter { followUpMeetingID == nil || $0.meetingID == followUpMeetingID }
        guard let candidate = attentionTracker.nextPresentation(from: candidates, interactionBlocked: blocked) else { return }
        showFollowUp(candidate.meetingID)
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func markSpeakerAttentionPresented(_ candidate: SpeakerAttentionCandidate) {
        attentionTracker.markPresented(candidate)
        do {
            try JSONEncoder().encode(attentionTracker).write(to: AppPaths.root.appendingPathComponent("speaker-attention.json"), options: .atomic)
        } catch { fail("Could not save speaker prompt state: \(error.localizedDescription)") }
    }

    private func showPrompt(_ record: MeetingRecord) {
        if let old = pending { resolve(old.id, resolution: .accept(trigger: .promptClosed)) }
        pending = record
        titleDraft = record.title
        let panel = NamingWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 210), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Recording finished"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: NamingView(controller: self))
        panel.onClose = { [weak self] in self?.resolve(record.id, resolution: .accept(trigger: .promptClosed)) }
        panel.center()
        panel.orderFrontRegardless()
        pendingWindow = panel
    }

    private func recoverInterruptedCaptures() async {
        var issues: [String] = []
        do {
            for directory in try FileManager.default.contentsOfDirectory(at: AppPaths.spool, includingPropertiesForKeys: nil) {
                do {
                let path = directory.appendingPathComponent("capture-journal.json")
                guard let data = try? Data(contentsOf: path) else { continue }
                let entry = try ModelCodec.decoder.decode(CaptureJournal.self, from: data)
                guard try store?.fetchMeeting(id: entry.id) == nil else { continue }
                let media = try SpoolBundle.mediaFiles(in: directory)
                var duration = 0.0
                for (url, _) in media {
                    let value = try await AVURLAsset(url: url).load(.duration).seconds
                    if value.isFinite { duration = max(duration, value) }
                }
                guard duration > 0 else { throw CaptureFailure.message("An interrupted capture needs recovery: \(entry.id)") }
                let record = makeRecord(entry, ended: entry.startedAt.addingTimeInterval(duration))
                try store?.insertMeeting(record)
                resolve(record.id, resolution: .accept(trigger: .restartRecovery))
                try FileManager.default.removeItem(at: path)
                } catch {
                    // One damaged capture must never starve later valid files.
                    issues.append("\(directory.lastPathComponent): \(error.localizedDescription)")
                }
            }
            refresh()
        } catch { issues.append(error.localizedDescription) }
        if !issues.isEmpty { fail("Interrupted files were retained for recovery: " + issues.prefix(3).joined(separator: "; ")) }
    }

    private func uploadNext() async {
        guard !uploading else { return }
        uploading = true
        defer { uploading = false }
        // Implemented through ArchiveTransfer's verified acknowledgement.
        await transferQueuedMeeting()
        await cleanupVerifiedMedia()
    }

    var transferConfiguration: ArchiveTransferConfiguration {
        var configuration = ArchiveTransferConfiguration.bruce
        configuration.host = settings.archiveHost
        configuration.archiveRoot = settings.archiveRoot + "/meetings"
        configuration.incomingRoot = settings.archiveRoot + "/incoming"
        configuration.workerDatabase = settings.archiveRoot + "/worker.sqlite"
        configuration.workerPython = settings.archiveRoot + "/runtime/venv/bin/python3"
        configuration.workerScript = settings.archiveRoot + "/runtime/worker/worker.py"
        return configuration
    }

    private func transferQueuedMeeting() async {
        var claimed: ArchiveJob?
        do {
            // This exceeds the transfer + verify timeouts. Only this actor starts
            // uploads; after a crash the lease becomes available again.
            guard let job = try store?.claimNextJob(now: Date(), leaseDuration: 15_000),
                  let record = try store?.fetchMeeting(id: job.meetingID) else { return }
            claimed = job
            let source = AppPaths.meeting(record.id)
            let manifest = try await Task.detached(priority: .utility) { try SpoolBundle.prepare(record: record, directory: source) }.value
            let acknowledgement = try await transfer.upload(sourceDirectory: source, manifest: manifest, configuration: transferConfiguration)
            try store?.acknowledgeJob(id: job.id, acknowledgement: acknowledgement)
        } catch {
            if let claimed {
                let delay = min(3600.0, 30.0 * pow(2, Double(min(claimed.attemptCount, 7))))
                try? store?.scheduleRetry(jobID: claimed.id, availableAt: Date().addingTimeInterval(delay), error: error.localizedDescription)
            }
        }
        refresh()
        if claimed != nil { await refreshWorkerStatuses(force: true) }
    }

    private func cleanupVerifiedMedia() async {
        guard settings.backupCoverageVerified else { return }
        for job in jobs where job.status == .succeeded {
            guard !cleanedMeetingIDs.contains(job.meetingID) else { continue }
            guard let acknowledgement = job.acknowledgement else { continue }
            let source = AppPaths.meeting(job.meetingID)
            let index = AppPaths.index.appendingPathComponent(job.meetingID.uuidString.lowercased())
            if FileManager.default.fileExists(atPath: index.appendingPathComponent("cleanup-complete.json").path) {
                cleanedMeetingIDs.insert(job.meetingID)
                continue
            }
            do {
                try await Task.detached(priority: .utility) {
                    try ArchiveCleanup.perform(source: source, index: index, acknowledgement: acknowledgement)
                }.value
                cleanedMeetingIDs.insert(job.meetingID)
            } catch { fail("The verified archive is safe on Bruce, but local cleanup needs attention. \(error.localizedDescription)") }
        }
    }

    func openPlayback(_ id: UUID) {
        retrieve(id, relativePath: "playback/meeting.mp4", localName: "meeting.mp4")
    }

    func openTranscript(_ id: UUID) {
        let revision = meetings.first(where: { $0.id == id })?.metadataRevision ?? 1
        retrieve(id, relativePath: "transcripts/v\(revision)/transcript.md", localName: "transcript.md")
    }

    private func retrieve(_ id: UUID, relativePath: String, localName: String) {
        Task {
            do {
                let destination = AppPaths.index.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent(localName)
                let url = try await transfer.fetch(relativePath: relativePath, meetingID: id, destination: destination, configuration: transferConfiguration)
                NSWorkspace.shared.open(url)
            } catch { fail("The archive item is not ready or Bruce is unavailable. \(error.localizedDescription)") }
        }
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func notify(_ title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func fail(_ message: String) {
        failure = message
        status = "Needs attention"
    }

    func quit() async {
        timer?.cancel()
        if let meetingID = journal?.id,
           case .finalize(let request) = captureLifecycle.requestStop(meetingID: meetingID, reason: .interrupted) {
            await finish(request)
        }
        if let pending { resolve(pending.id, resolution: .accept(trigger: .promptClosed)) }
        NSApp.terminate(nil)
    }
}

import SwiftUI

@MainActor
final class NamingWindow: NSWindow {
    var onClose: (() -> Void)?
    override func close() { let action = onClose; onClose = nil; action?(); super.close() }
}
