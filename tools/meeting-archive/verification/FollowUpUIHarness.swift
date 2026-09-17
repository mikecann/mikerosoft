import AppKit
import Darwin
import Foundation
import MeetingArchiveCore
import SwiftUI

private enum HarnessFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

@MainActor
private final class FollowUpHarnessDelegate: NSObject, NSApplicationDelegate {
    private var controller: ArchiveController?
    private var controlsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try validateIsolatedDataRoot()
            let controller = ArchiveController(startServices: false)
            guard controller.failure == nil else {
                throw HarnessFailure.message(controller.failure ?? "The isolated controller could not start.")
            }
            guard let meeting = controller.meetings.first(where: {
                if case .accepted = $0.acceptance { return true }
                return false
            }) else {
                throw HarnessFailure.message("The database backup contains no accepted meetings.")
            }
            guard controller.jobs.contains(where: {
                $0.meetingID == meeting.id
                    && $0.manifestRevision == meeting.metadataRevision
                    && $0.status == .succeeded
                    && $0.acknowledgement != nil
            }) else {
                throw HarnessFailure.message("The newest accepted meeting has no completed archive acknowledgement.")
            }

            controller.workerStatuses[meeting.id] = WorkerMeetingStatus(
                meetingID: meeting.id,
                phase: .processing,
                processingState: .leased,
                publicationState: nil,
                speakerReview: .waitingForProcessing,
                retryStage: nil,
                lastError: nil,
                manifestRevision: meeting.metadataRevision,
                totalSpeakerCount: nil,
                unconfirmedSpeakerCount: nil
            )
            self.controller = controller
            showControls(controller: controller, meeting: meeting)
            controller.showFollowUp(meeting.id, refreshStatus: false)
        } catch {
            let message = "Follow-up UI verification: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            if let rawRoot = getenv("MEETING_ARCHIVE_DATA_DIR") {
                let root = URL(fileURLWithPath: String(cString: rawRoot), isDirectory: true)
                try? Data(message.utf8).write(to: root.appendingPathComponent("harness-error.txt"), options: .atomic)
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func showControls(controller: ArchiveController, meeting: MeetingRecord) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting Archive UI Verification"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: HarnessControls(controller: controller, meeting: meeting)
        )
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x - 390, y: window.frame.origin.y + 180))
        window.makeKeyAndOrderFront(nil)
        controlsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func validateIsolatedDataRoot() throws {
        guard let rawRootPointer = getenv("MEETING_ARCHIVE_DATA_DIR")
        else {
            throw HarnessFailure.message("MEETING_ARCHIVE_DATA_DIR is required.")
        }
        let rawRoot = String(cString: rawRootPointer)
        guard !rawRoot.isEmpty else { throw HarnessFailure.message("MEETING_ARCHIVE_DATA_DIR is empty.") }
        let suppliedRoot = URL(fileURLWithPath: rawRoot, isDirectory: true)
        let suppliedValues = try suppliedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard suppliedValues.isDirectory == true, suppliedValues.isSymbolicLink != true else {
            throw HarnessFailure.message("The verification data root must be a real directory.")
        }
        let root = suppliedRoot.resolvingSymlinksInPath()
        let canonicalTemporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().path == canonicalTemporaryDirectory.path,
              root.lastPathComponent.hasPrefix("meeting-archive-ui-verification."),
              root.lastPathComponent.count > "meeting-archive-ui-verification.".count
        else {
            throw HarnessFailure.message("The verification data root must be a unique directory under /private/tmp.")
        }
        let database = root.appendingPathComponent("meetings.sqlite", isDirectory: false)
        let databaseValues = try database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard databaseValues.isRegularFile == true, databaseValues.isSymbolicLink != true else {
            throw HarnessFailure.message("The verification root needs a regular meetings.sqlite backup.")
        }
    }
}

@MainActor
private struct HarnessControls: View {
    @ObservedObject var controller: ArchiveController
    let meeting: MeetingRecord
    @State private var status = "The follow-up window is showing a simulated leased processing job."
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Follow-up UI verification").font(.title3)
            Text(meeting.title).font(.headline).lineLimit(1)
            Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Finish simulated processing") {
                    isRefreshing = true
                    status = "Reading the real speaker count from Bruce…"
                    Task {
                        await controller.refreshWorkerStatuses(force: true)
                        isRefreshing = false
                        if let failure = controller.workerStatusFailure {
                            status = "Bruce status failed: \(failure)"
                        } else if controller.workerStatuses[meeting.id]?.speakerReview == .available {
                            status = "Real speaker review loaded. The follow-up window should now show the review UI."
                        } else {
                            status = "Bruce still reports that processing is incomplete."
                        }
                    }
                }
                .disabled(isRefreshing)
                if isRefreshing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Quit verification") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .frame(width: 420, height: 210)
    }
}

@main
private enum FollowUpUIHarness {
    private static var delegate: FollowUpHarnessDelegate?

    @MainActor
    static func main() {
        if getenv("MEETING_ARCHIVE_DATA_DIR") == nil {
            guard let marker = Bundle.main.url(forResource: "data-root", withExtension: "txt"),
                  let data = try? Data(contentsOf: marker),
                  let root = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !root.isEmpty
            else {
                FileHandle.standardError.write(Data("Follow-up UI verification: prepared data root is missing.\n".utf8))
                Darwin.exit(EX_CONFIG)
            }
            setenv("MEETING_ARCHIVE_DATA_DIR", root, 1)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = FollowUpHarnessDelegate()
        self.delegate = delegate
        application.delegate = delegate
        application.run()
    }
}
