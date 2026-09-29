import AppKit
import MeetingArchiveCore
import ServiceManagement
import SwiftUI

struct MeetingArchiveApplication: App {
    @StateObject private var controller = ArchiveController()
    var body: some Scene {
        MenuBarExtra {
            Text(controller.status)
            if let failure = controller.failure {
                Text(failure).lineLimit(3)
                Button("Clear warning") { controller.clearFailure() }
            }
            if controller.isRecording { Button("Skip this meeting") { controller.skip() } }
            Button(controller.isPaused ? "Resume automatic recording" : "Pause automatic recording") { controller.togglePause() }
            Divider()
            if !controller.meetingsNeedingSpeakerNames.isEmpty {
                Text("\(controller.speakersNeedingNames) speaker\(controller.speakersNeedingNames == 1 ? " needs a name" : "s need names")")
                ForEach(controller.meetingsNeedingSpeakerNames, id: \.id) { meeting in
                    Button("Review speakers: \(meeting.title)") { controller.showFollowUp(meeting.id) }
                }
                Divider()
            }
            if !controller.processingMeetings.isEmpty {
                ForEach(controller.processingMeetings, id: \.id) { meeting in
                    Button("Processing: \(meeting.title)") { controller.showFollowUp(meeting.id) }
                }
                Divider()
            }
            WindowButton()
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit Meeting Archive") { Task { await controller.quit() } }.keyboardShortcut("q")
        } label: {
            HStack(spacing: 3) {
                Image(systemName: controller.isRecording ? "record.circle.fill" : controller.speakersNeedingNames > 0 ? "person.crop.circle.badge.exclamationmark" : controller.failure != nil ? "exclamationmark.circle" : controller.isPaused ? "pause.circle" : "video.badge.waveform")
                if controller.speakersNeedingNames > 0 { Text("\(controller.speakersNeedingNames)") }
                else if !controller.processingMeetings.isEmpty { Image(systemName: "hourglass") }
            }
            .foregroundStyle(controller.isRecording ? .red : .primary)
            .accessibilityLabel(controller.speakersNeedingNames > 0 ? "Meeting Archive: \(controller.speakersNeedingNames) speakers need names" : "Meeting Archive")
        }
        Window("Meeting Archive", id: "library") {
            LibraryView(controller: controller)
                .onOpenURL { url in
                    // The viewer's "open in Mac app" link lands here; show the
                    // meeting's speakers rather than bouncing back to the viewer.
                    guard url.scheme == "meetingarchive", let id = UUID(uuidString: url.lastPathComponent) else { return }
                    controller.showFollowUp(id)
                }
        }.defaultSize(width: 820, height: 540)
            .defaultLaunchBehavior(CommandLine.arguments.contains("--background") ? .suppressed : .presented)
        Settings { ArchiveSettingsView(controller: controller, settings: controller.settings).frame(width: 600, height: 580) }
    }
}

private struct WindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Open meeting library") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) } }
}

struct NamingView: View {
    @ObservedObject var controller: ArchiveController
    @FocusState private var titleFocused: Bool
    @State private var confirmingDiscard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What was this meeting about?").font(.title3)
            TextField("Meeting title", text: $controller.titleDraft)
                .focused($titleFocused)
                .onChange(of: controller.titleDraft) { controller.titleDraftEdited() }
                .onSubmit { save() }
            if !controller.calendarChoices.isEmpty {
                Menu("Use a calendar event") {
                    ForEach(controller.calendarChoices) { event in Button(event.title) { controller.titleDraft = event.title } }
                }
            } else if controller.settings.selectedCalendarIDs.isEmpty {
                Text("Select calendars in Settings to get title suggestions.").font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(countdown(at: context.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Button("Discard recording", role: .destructive) { confirmingDiscard = true }
                    .confirmationDialog("Delete this recording?", isPresented: $confirmingDiscard) {
                        Button("Delete recording", role: .destructive) {
                            if let pending = controller.pending { controller.resolve(pending.id, resolution: .discard) }
                        }
                    } message: { Text("The video and audio are removed from this Mac and never sent to Bruce.") }
                Spacer()
                Button("Save recording") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { titleFocused = true }
    }

    private func save() {
        if let pending = controller.pending { controller.resolve(pending.id, resolution: .accept(trigger: .keepButton)) }
    }

    private func countdown(at now: Date) -> String {
        guard let deadline = controller.promptDeadline else { return "" }
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return "Saves automatically in \(seconds)s. Typing gives you more time; Esc saves as is."
    }
}

private struct RenameMeetingSheet: View {
    @ObservedObject var controller: ArchiveController
    let record: MeetingRecord
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename meeting").font(.title3)
            Text("\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.sourceApplication.displayName)")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Meeting title", text: $title).onSubmit(save)
            Text("Updates the title on Bruce and in Notion. Nothing is re-uploaded or re-transcribed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { title = record.title }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let renamed = await controller.rename(record.id, to: title)
            saving = false
            if renamed { dismiss() }
        }
    }
}

struct LibraryView: View {
    @ObservedObject var controller: ArchiveController
    @State private var search = ""
    @State private var renaming: MeetingRecord?
    @State private var transcriptResults: [WorkerSearchResult] = []
    @State private var transcriptSearchStatus: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.status).font(.headline)
                Spacer()
                Button("Refresh") {
                    controller.refresh()
                    Task { await controller.refreshWorkerStatuses(force: true) }
                }
                SettingsLink { Image(systemName: "gear") }
            }
            if let failure = controller.failure {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(failure).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { controller.clearFailure() }
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let failure = controller.workerStatusFailure {
                HStack(alignment: .top) {
                    Image(systemName: "network.slash").foregroundStyle(.secondary)
                    Text("Bruce status is unavailable: \(failure)").font(.callout).textSelection(.enabled)
                    Spacer()
                }.padding(10).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("Search titles and transcripts", text: $search)
                .task(id: search) { await searchTranscripts() }
            if let transcriptSearchStatus {
                Text(transcriptSearchStatus).font(.caption).foregroundStyle(.secondary)
            }
            if !transcriptResults.isEmpty {
                GroupBox("Said in meetings") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(transcriptResults) { result in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button(controller.meetings.first { $0.id == result.meetingID }?.title ?? result.title ?? "Meeting") {
                                        controller.openInViewer(result.meetingID)
                                    }.buttonStyle(.link)
                                    ForEach(Array(result.matches.enumerated()), id: \.offset) { _, match in
                                        Text("\(Duration.seconds(match.startSeconds).formatted(.time(pattern: .minuteSecond))) \(match.speaker.map { "\($0): " } ?? "")\(match.text)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                }
            }
            List {
                ForEach(controller.meetings.filter { record in
                    if case .discarded = record.acceptance { return false }
                    return search.isEmpty || record.title.localizedCaseInsensitiveContains(search)
                }, id: \.id) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.title).font(.headline)
                            Text("\(record.startedAt.formatted()) · \(Duration.seconds(record.endedAt.timeIntervalSince(record.startedAt)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) · \(record.sourceApplication.displayName)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(jobLabel(record)).font(.caption).foregroundStyle(.secondary)
                            if controller.followUpPhase(for: record).isBusy {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Spacer()
                        if controller.canRename(record) {
                            Button("Rename…") { renaming = record }
                        }
                        Button("Open") { controller.openInViewer(record.id) }
                            .help("Watch with the transcript in Bruce's viewer")
                        Button("Transcript") { controller.openTranscript(record.id) }
                            .help("Download the transcript as Markdown")
                        Button(currentWorkerStatus(record)?.unconfirmedSpeakerCount ?? 0 > 0 ? "Name speakers…" : "Speakers…") { controller.showFollowUp(record.id) }
                        if currentWorkerStatus(record)?.retryStage != nil {
                            Button("Retry") { controller.retryWorker(record.id) }
                        }
                    }.padding(.vertical, 6)
                }
            }
            .sheet(item: $renaming) { record in
                RenameMeetingSheet(controller: controller, record: record)
            }
            .overlay {
                if controller.meetings.isEmpty { ContentUnavailableView("No meetings yet", systemImage: "video", description: Text("Grant the permissions in Settings. Eligible calls will appear here after recording.")) }
            }
        }.padding(20)
    }

    private func searchTranscripts() async {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            transcriptResults = []
            transcriptSearchStatus = nil
            return
        }
        // Debounce: each keystroke restarts this task, so only a pause searches.
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        transcriptSearchStatus = "Searching transcripts on Bruce…"
        do {
            let results = try await controller.searchTranscripts(query)
            guard !Task.isCancelled else { return }
            transcriptResults = results
            transcriptSearchStatus = results.isEmpty ? "No transcript matches" : nil
        } catch {
            guard !Task.isCancelled else { return }
            transcriptResults = []
            transcriptSearchStatus = "Transcript search unavailable: \(error.localizedDescription)"
        }
    }

    private func jobLabel(_ record: MeetingRecord) -> String {
        if record.acceptance.isPending { return "Saving shortly" }
        guard let job = controller.jobs.first(where: { $0.meetingID == record.id }) else { return "Saved locally" }
        if let error = job.lastError { return "Waiting to retry: \(error)" }
        if job.status == .succeeded {
            return currentWorkerStatus(record)?.detail
                ?? (controller.workerStatusFailure == nil
                    ? "Archived • checking processing status"
                    : "Archived • remote status unavailable")
        }
        return "Archive: \(job.status.rawValue)"
    }

    private func currentWorkerStatus(_ record: MeetingRecord) -> WorkerMeetingStatus? {
        guard let status = controller.workerStatuses[record.id], status.manifestRevision == record.metadataRevision else { return nil }
        return status
    }
}

struct MeetingFollowUpView: View {
    @ObservedObject var controller: ArchiveController
    let meetingID: UUID

    var body: some View {
        if let record = controller.meetings.first(where: { $0.id == meetingID }) {
            let phase = controller.followUpPhase(for: record)
            VStack(alignment: .leading, spacing: 16) {
                Text(record.title).font(.title2).lineLimit(2)
                if controller.workerStatuses[meetingID]?.speakerReview == .available,
                   controller.workerStatuses[meetingID]?.manifestRevision == record.metadataRevision {
                    SpeakerReviewView(
                        meetingID: meetingID,
                        revision: record.metadataRevision,
                        configuration: controller.transferConfiguration,
                        onComplete: { controller.closeFollowUp(); controller.speakerReviewChanged() },
                        onReviewChanged: { controller.speakerReviewChanged() },
                        onLater: { controller.closeFollowUp() }
                    )
                } else {
                    Spacer()
                    HStack(spacing: 12) {
                        if phase.isBusy { ProgressView().controlSize(.large) }
                        else { Image(systemName: "clock.badge.exclamationmark").font(.largeTitle) }
                        Text(phase.detail).font(.headline)
                    }
                    Text("Your recording is saved. You can close this window. It will open again when speaker names are ready to review, and the menu bar will show anything that still needs your attention.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack {
                        if controller.workerStatuses[meetingID]?.manifestRevision == record.metadataRevision,
                           controller.workerStatuses[meetingID]?.retryStage != nil {
                            Button("Retry") { controller.retryWorker(meetingID) }
                        }
                        Button("Refresh") { controller.speakerReviewChanged() }
                        Spacer()
                        Button("Continue in background") { controller.closeFollowUp() }
                    }
                }
            }.padding(20)
        }
    }
}

struct ArchiveSettingsView: View {
    @ObservedObject var controller: ArchiveController
    @ObservedObject var settings: AppSettings
    @StateObject private var permissions = AppPermissions()
    @State private var calendars: [(id: String, title: String)] = []
    @State private var loginStatus = ""
    private var service: SMAppService { .agent(plistName: "com.mikerosoft.meeting-archive.plist") }

    var body: some View {
        Form {
            if let failure = permissions.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("Recording") {
                Text("Meeting window at 1080p, up to 15 fps. Your system-default microphone at recording start stays active even while muted in the call.")
                Text("Preview: automatic Google Meet recording is not enabled yet. Chrome audio can include other tabs; browser capture still needs validation.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach([
                    AppPermissionKind.accessibility,
                    .screenRecording,
                    .microphone,
                    .notifications,
                ]) { permission in
                    PermissionRow(permission: permission, status: permissions.status(for: permission)) {
                        Task { await permissions.performAction(for: permission, calendar: controller.calendar) }
                    }
                }
            }
            Section("Start automatically") {
                HStack {
                    Button("Enable at login") {
                        do { try service.register(); loginStatus = service.status == .enabled ? "Enabled" : "Allow Meeting Archive in Login Items" }
                        catch { controller.fail(error.localizedDescription) }
                    }
                    Button("Disable at login") { Task { do { try await service.unregister(); loginStatus = "Disabled" } catch { controller.fail(error.localizedDescription) } } }
                    Text(loginStatus).foregroundStyle(.secondary)
                }
            }
            Section("Calendar suggestions") {
                Text("Select your personal and Convex calendars. Accounts must be added in macOS Internet Accounts.").font(.caption).foregroundStyle(.secondary)
                PermissionRow(permission: .calendar, status: permissions.status(for: .calendar)) {
                    Task {
                        await permissions.performAction(for: .calendar, calendar: controller.calendar)
                        loadCalendars()
                    }
                }
                if !calendars.isEmpty, settings.selectedCalendarIDs.isEmpty {
                    Label("No calendars selected, so meetings are not named from your calendar.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                ForEach(calendars, id: \.id) { calendar in
                    Toggle(calendar.title, isOn: Binding(get: { settings.selectedCalendarIDs.contains(calendar.id) }, set: { selected in
                        if selected { settings.selectedCalendarIDs.insert(calendar.id) } else { settings.selectedCalendarIDs.remove(calendar.id) }
                    }))
                }
            }
            Section("Bruce archive") {
                TextField("SSH host", text: $settings.archiveHost)
                TextField("Archive directory", text: $settings.archiveRoot)
                TextField("Viewer address", text: $settings.viewerURL)
                Toggle("This directory is covered by Bruce’s backup; remove verified local media", isOn: $settings.backupCoverageVerified)
                    .help("Media is removed only after Bruce verifies every file and saves its processing job.")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = service.status == .enabled ? "Enabled" : "Disabled" }
        .task { await refreshPermissionsAndCalendars() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissionsAndCalendars() }
        }
    }

    private func refreshPermissionsAndCalendars() async {
        await permissions.refresh()
        loadCalendars()
    }

    private func loadCalendars() {
        controller.calendar.reload()
        calendars = controller.calendar.calendars()
        if settings.selectedCalendarIDs.isEmpty {
            settings.selectedCalendarIDs = controller.calendar.defaultCalendarIDs()
        }
    }
}

private struct PermissionRow: View {
    let permission: AppPermissionKind
    let status: AppPermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Text(permission.title)
            Spacer()
            Button(buttonTitle, action: action)
                .disabled(status == .granted)
        }
    }

    private var buttonTitle: String {
        switch status {
        case .notRequested:
            return permission == .calendar ? "Not requested · Connect" : "Not requested · Allow"
        case .needsAccess:
            return "Needs access · Open Settings"
        case .granted:
            return "Granted"
        case .denied:
            return "Denied · Open Settings"
        case .restricted:
            return "Restricted · Open Settings"
        case .unknown:
            return "Unknown · Open Settings"
        }
    }
}
