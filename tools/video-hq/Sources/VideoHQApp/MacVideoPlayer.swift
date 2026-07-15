import AVKit
import SwiftUI

/// Uses AppKit's stable AVPlayerView directly. SwiftUI's VideoPlayer wrapper
/// aborts in _AVKit_SwiftUI on this machine when inserted after file selection.
struct MacVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
