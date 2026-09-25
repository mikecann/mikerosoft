import SwiftUI
import TandemCore

/// The viewer and its transport bar.
struct ViewerPanel: View {
    let model: EditorModel
    let actions: EditorActions
    @State private var viewerZoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            ViewerRepresentable(model: model, zoom: viewerZoom)
            TransportBar(model: model, actions: actions, zoom: $viewerZoom)
        }
        .background(Theme.viewer.color)
    }
}

struct ViewerRepresentable: NSViewRepresentable {
    let model: EditorModel
    let zoom: CGFloat

    func makeNSView(context: Context) -> ViewerView {
        ViewerView(model: model)
    }

    func updateNSView(_ view: ViewerView, context: Context) {
        if view.zoom != zoom {
            view.zoom = zoom
            if zoom == 1 { view.pan = .zero }
        }
    }
}

/// Timecode, transport buttons, proxy and fit, as in the design.
struct TransportBar: View {
    let model: EditorModel
    let actions: EditorActions
    @Binding var zoom: CGFloat

    var body: some View {
        let playback = model.playback
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Timecode.string(playback.time, rate: model.frameRate))
                    .font(.system(size: 19, weight: .light).monospacedDigit())
                    .foregroundStyle(Theme.text.color)
                Text("/ " + Timecode.string(model.project.duration, rate: model.frameRate))
                    .font(.ui(12).monospacedDigit())
                    .foregroundStyle(Theme.textFainter.color)
                if playback.isPlaying && abs(playback.rate) != 1 {
                    Text(String(format: "%@%.0f×", playback.rate < 0 ? "−" : "", abs(playback.rate)))
                        .font(.ui(11, .semibold))
                        .foregroundStyle(Theme.amber.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 18) {
                TransportIcon(name: "backward.end.fill", help: "Previous edit (↑)") { actions.perform(.previousEdit) }
                Button {
                    actions.perform(.playPause)
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.onAmber.color)
                        .offset(x: playback.isPlaying ? 0 : 1)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.text.color))
                }
                .buttonStyle(.plain)
                .help("Play or pause (Space). J, K and L shuttle.")
                TransportIcon(name: "forward.end.fill", help: "Next edit (↓)") { actions.perform(.nextEdit) }
            }

            HStack(spacing: 12) {
                Button {
                    model.showSafeMargins.toggle()
                } label: {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 12))
                        .foregroundStyle(model.showSafeMargins ? Theme.text.color : Theme.textMuted.color)
                }
                .buttonStyle(.plain)
                .help("Safe margins")
                ToggleText(title: "Proxy", on: playback.useProxies, help: "Play from 1080p proxies where they're ready. Off plays the original files.") {
                    playback.useProxies.toggle()
                }
                Menu {
                    Button("Fit") { zoom = 1 }
                    Button("150%") { zoom = 1.5 }
                    Button("200%") { zoom = 2 }
                    Button("400%") { zoom = 4 }
                } label: {
                    Text(zoom == 1 ? "Fit" : "\(Int(zoom * 100))%")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.controlBorder.color, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.Metrics.transportHeight)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderSubtle.color).frame(height: 1) }
    }
}

private struct TransportIcon: View {
    let name: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
