import AppKit
import Foundation
import MeetingArchiveCore
import SwiftUI

// Display real worker output with the production review view, but make it
// impossible for UI verification to confirm an identity in the real archive.
private struct FixtureSpeakerClient: SpeakerReviewServing {
    let response: SpeakerReviewResponse
    let video: URL

    func load(meetingID: UUID, revision: Int, configuration: ArchiveTransferConfiguration) async throws -> SpeakerReviewResponse {
        try response.validate(meetingID: meetingID, revision: revision)
        return response
    }

    func identify(meetingID: UUID, revision: Int, speakerID: String, name: String, configuration: ArchiveTransferConfiguration) async throws -> SpeakerIdentificationResponse {
        throw SpeakerReviewError.invalidResponse("This verification window does not save speaker identities.")
    }

    func fetchPlayback(meetingID: UUID, destination: URL, configuration: ArchiveTransferConfiguration) async throws -> URL { video }
}

@MainActor
private final class SuggestionsDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
            let response = try ModelCodec.decoder.decode(SpeakerReviewResponse.self, from: Data(contentsOf: resources.appendingPathComponent("review.json")))
            let client = FixtureSpeakerClient(response: response, video: resources.appendingPathComponent("meeting.mp4"))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Speaker suggestions verification"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SpeakerReviewView(
                meetingID: response.meetingID, revision: response.manifestRevision,
                configuration: .bruce, client: client,
                onComplete: { NSApp.terminate(nil) }, onLater: { NSApp.terminate(nil) }
            ))
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            FileHandle.standardError.write(Data("Verification failed: \(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
private enum SpeakerSuggestionsHarness {
    static func main() {
        let app = NSApplication.shared
        let delegate = SuggestionsDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
