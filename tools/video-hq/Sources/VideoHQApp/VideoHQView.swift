import SwiftUI

struct VideoHQView: View {
    @StateObject private var model = VideoHQModel()
    @ObservedObject private var openCoordinator = VideoOpenCoordinator.shared
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.videoURL == nil {
                emptyState
            } else {
                loadedVideo
            }

            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            guard let video = urls.first else { return false }
            return model.loadVideo(video)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoHQOpenVideo)) { _ in
            model.openVideoPanel()
        }
        .onReceive(openCoordinator.$requestedURL.compactMap { $0 }) { url in
            model.loadVideo(url)
            openCoordinator.consume(url)
        }
        .alert("Video HQ", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Something went wrong.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Video HQ")
                    .font(.title2.weight(.semibold))
                Text("Your video production command center")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.videoURL != nil {
                Button("Change Video", systemImage: "folder") {
                    model.openVideoPanel()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 92, height: 92)
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 39, weight: .medium))
                    .foregroundStyle(.tint)
            }
            VStack(spacing: 7) {
                Text(isDropTargeted ? "Drop your video" : "Choose a video")
                    .font(.title2.weight(.semibold))
                Text("Drag a video into this window, or choose one from Finder.")
                    .foregroundStyle(.secondary)
            }
            Button("Choose Video...", systemImage: "folder") {
                model.openVideoPanel()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 3 : 2, dash: [9, 7])
                )
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
                )
                .padding(34)
        }
    }

    private var loadedVideo: some View {
        HSplitView {
            videoPane
                .frame(minWidth: 430, idealWidth: 580)
            toolsPane
                .frame(minWidth: 410, idealWidth: 500)
        }
    }

    private var videoPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let videoURL = model.videoURL {
                VStack(alignment: .leading, spacing: 3) {
                    Text(videoURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(videoURL.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let player = model.player {
                MacVideoPlayer(player: player)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.08))
                    }
            }
        }
        .padding(20)
    }

    private var toolsPane: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(VideoHQModel.Tool.allCases, id: \.self) { tool in
                    toolCard(tool)
                }
            }
            resultPanel
        }
        .padding(20)
    }

    private func toolCard(_ tool: VideoHQModel.Tool) -> some View {
        let isSelected = model.selectedTool == tool
        let isComplete = model.hasResult(for: tool)
        let isWorking = model.workingTool == tool

        return Button {
            model.selectOrRun(tool)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: tool.icon)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(tool.rawValue)
                    .font(.headline)
                Text(isComplete ? "Saved beside video" : "Click to run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isSelected ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking && !isWorking)
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.selectedTool.rawValue, systemImage: model.selectedTool.icon)
                    .font(.headline)
                Spacer()
                if !model.activeText.isEmpty {
                    Button("Reveal", systemImage: "folder") {
                        model.revealActiveSidecar()
                    }
                    Button("Copy", systemImage: "doc.on.doc") {
                        model.copyActiveText()
                    }
                }
                Button(model.hasResult(for: model.selectedTool) ? "Run Again" : "Run") {
                    model.run(model.selectedTool)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }
            .padding(14)

            Divider()

            if model.workingTool == model.selectedTool {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.activeText.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.selectedTool.icon)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No \(model.selectedTool.rawValue.lowercased()) yet")
                        .font(.headline)
                    Text(model.selectedTool == .description
                         ? "A transcript will be generated first if this video does not have one."
                         : "The transcript will be saved as an SRT beside the video.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 330)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(model.activeText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.videoURL == nil ? "info.circle" : "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}
