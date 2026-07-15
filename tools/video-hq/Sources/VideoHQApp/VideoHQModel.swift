import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class VideoHQModel: ObservableObject {
    enum Tool: String, CaseIterable {
        case transcript = "Transcribe"
        case description = "Video Description"

        var icon: String {
            switch self {
            case .transcript: return "captions.bubble"
            case .description: return "text.quote"
            }
        }
    }

    @Published private(set) var videoURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var transcript = ""
    @Published private(set) var description = ""
    @Published var selectedTool: Tool = .transcript
    @Published private(set) var workingTool: Tool?
    @Published private(set) var statusMessage = "Choose a video to get started."
    @Published var errorMessage: String?

    private let configuration: VideoHQConfiguration?
    private let configurationError: Error?

    init() {
        do {
            configuration = try VideoHQConfiguration.load()
            configurationError = nil
        } catch {
            configuration = nil
            configurationError = error
        }
    }

    var activeText: String {
        selectedTool == .transcript ? transcript : description
    }

    var isWorking: Bool {
        workingTool != nil
    }

    func hasResult(for tool: Tool) -> Bool {
        switch tool {
        case .transcript: return !transcript.isEmpty
        case .description: return !description.isEmpty
        }
    }

    @discardableResult
    func loadVideo(_ url: URL) -> Bool {
        guard VideoFile.isSupported(url) else {
            errorMessage = "That file is not a supported video. Choose an MP4, MOV, MKV, or another common video format."
            return false
        }

        do {
            player?.pause()
            let sidecars = try VideoSidecars.load(for: url)
            videoURL = url
            player = AVPlayer(url: url)
            transcript = sidecars.transcript
            description = sidecars.description
            selectedTool = description.isEmpty ? .transcript : .description

            let loadedCount = [transcript, description].filter { !$0.isEmpty }.count
            statusMessage = loadedCount == 0
                ? "Video loaded. Choose a tool to begin."
                : "Video loaded with \(loadedCount) existing result\(loadedCount == 1 ? "" : "s")."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video"
        panel.prompt = "Choose Video"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadVideo(url)
        }
    }

    func selectOrRun(_ tool: Tool) {
        selectedTool = tool
        if !hasResult(for: tool) {
            run(tool)
        }
    }

    func run(_ tool: Tool) {
        guard !isWorking, videoURL != nil else { return }
        selectedTool = tool
        switch tool {
        case .transcript:
            runTranscription()
        case .description:
            runDescription()
        }
    }

    func copyActiveText() {
        guard !activeText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(activeText, forType: .string)
        statusMessage = "Copied \(selectedTool.rawValue.lowercased()) to the clipboard."
    }

    func revealActiveSidecar() {
        guard let videoURL else { return }
        let sidecarURL = selectedTool == .transcript
            ? VideoSidecars.transcriptURL(for: videoURL)
            : VideoSidecars.descriptionURL(for: videoURL)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sidecarURL])
    }

    private func runTranscription() {
        guard let videoURL else { return }
        guard let configuration else {
            errorMessage = configurationError?.localizedDescription ?? "Video HQ could not locate the repository."
            return
        }

        workingTool = .transcript
        statusMessage = "Transcribing \(videoURL.lastPathComponent)..."
        let executableURL = configuration.transcribeExecutableURL

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try VideoTranscriber(executableURL: executableURL).transcribe(videoURL: videoURL)
                }.value
                transcript = result
                statusMessage = "Transcript saved as \(VideoSidecars.transcriptURL(for: videoURL).lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Transcription failed."
            }
            workingTool = nil
        }
    }

    private func runDescription() {
        guard let videoURL else { return }
        guard let configuration else {
            errorMessage = configurationError?.localizedDescription ?? "Video HQ could not locate the repository."
            return
        }

        workingTool = .description
        Task {
            do {
                if transcript.isEmpty {
                    statusMessage = "No transcript found. Transcribing first..."
                    let executableURL = configuration.transcribeExecutableURL
                    transcript = try await Task.detached(priority: .userInitiated) {
                        try VideoTranscriber(executableURL: executableURL).transcribe(videoURL: videoURL)
                    }.value
                }

                guard let apiKey = configuration.openRouterAPIKey else {
                    throw VideoHQError.missingOpenRouterAPIKey(configuration.repoRoot.appendingPathComponent(".env"))
                }

                statusMessage = "Generating the video description..."
                description = try await VideoDescriptionWorkflow(
                    generator: OpenRouterDescriptionGenerator(apiKey: apiKey)
                ).generate(for: videoURL)
                statusMessage = "Description saved as \(VideoSidecars.descriptionURL(for: videoURL).lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Video description failed."
            }
            workingTool = nil
        }
    }
}
