import AppKit
import MeetingArchiveCore
import ServiceManagement
import SwiftUI

struct MeetingArchiveApplication: App {
    @StateObject private var controller = ArchiveController()
    var body: some Scene {
        MenuBarExtra {
            Text(controller.status)
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
                    guard url.scheme == "meetingarchive", let id = UUID(uuidString: url.lastPathComponent) else { return }
                    controller.openPlayback(id)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What was this meeting about?").font(.title3)
            TextField("Meeting title", text: $controller.titleDraft)
            if !controller.calendarChoices.isEmpty {
                Menu("Use a calendar event") {
                    ForEach(controller.calendarChoices) { event in Button(event.title) { controller.titleDraft = event.title } }
                }
            }
            Text("Saves automatically after 20 seconds, or when you close this window.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Discard recording", role: .destructive) {
                    if let pending = controller.pending { controller.resolve(pending.id, resolution: .discard) }
                }
                Spacer()
                Button("Save recording") {
                    if let pending = controller.pending { controller.resolve(pending.id, resolution: .accept(trigger: .keepButton)) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20)
    }
}

struct LibraryView: View {
    @ObservedObject var controller: ArchiveController
    @State private var search = ""
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
                    Button("Dismiss") { controller.failure = nil }
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let failure = controller.workerStatusFailure {
                HStack(alignment: .top) {
                    Image(systemName: "network.slash").foregroundStyle(.secondary)
                    Text("Bruce status is unavailable: \(failure)").font(.callout).textSelection(.enabled)
                    Spacer()
                }.padding(10).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("Search meeting titles", text: $search)
            List {
                ForEach(controller.meetings.filter { record in
                    if case .discarded = record.acceptance { return false }
                    return search.isEmpty || record.title.localizedCaseInsensitiveContains(search)
                }, id: \.id) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.title).font(.headline)
                            Text("\(record.startedAt.formatted()) · \(Int(record.endedAt.timeIntervalSince(record.startedAt))) seconds · \(record.sourceApplication.displayName)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(jobLabel(record)).font(.caption).foregroundStyle(.secondary)
                            if controller.followUpPhase(for: record).isBusy {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Spacer()
                        Button("Play") { controller.openPlayback(record.id) }
                        Button("Transcript") { controller.openTranscript(record.id) }
                        Button(currentWorkerStatus(record)?.unconfirmedSpeakerCount ?? 0 > 0 ? "Name speakers…" : "Speakers…") { controller.showFollowUp(record.id) }
                        if currentWorkerStatus(record)?.retryStage != nil {
                            Button("Retry") { controller.retryWorker(record.id) }
                        }
                    }.padding(.vertical, 6)
                }
            }.overlay {
                if controller.meetings.isEmpty { ContentUnavailableView("No meetings yet", systemImage: "video", description: Text("Grant the permissions in Settings. Eligible calls will appear here after recording.")) }
            }
        }.padding(20)
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
                        calendars = controller.calendar.calendars()
                    }
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
        calendars = controller.calendar.calendars()
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
