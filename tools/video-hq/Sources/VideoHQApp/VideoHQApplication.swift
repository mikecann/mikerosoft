import AppKit
import SwiftUI

final class VideoOpenCoordinator: ObservableObject {
    static let shared = VideoOpenCoordinator()

    @Published private(set) var requestedURL: URL?

    private init() {}

    func request(_ url: URL) {
        requestedURL = url
    }

    func consume(_ url: URL) {
        if requestedURL == url {
            requestedURL = nil
        }
    }
}

final class VideoHQAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let filename = filenames.first else { return }
        let url = URL(fileURLWithPath: filename)
        DispatchQueue.main.async {
            VideoOpenCoordinator.shared.request(url)
        }
        sender.reply(toOpenOrPrint: .success)
    }
}

@main
struct VideoHQApplication: App {
    @NSApplicationDelegateAdaptor(VideoHQAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            VideoHQView()
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video...") {
                    NotificationCenter.default.post(name: .videoHQOpenVideo, object: nil)
                }
                .keyboardShortcut("o")
            }
        }
    }
}

extension Notification.Name {
    static let videoHQOpenVideo = Notification.Name("video-hq.open-video")
}
