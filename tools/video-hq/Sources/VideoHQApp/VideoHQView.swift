import SwiftUI

struct VideoHQView: View {
    @StateObject private var model = VideoHQModel()
    @ObservedObject private var openCoordinator = VideoOpenCoordinator.shared
    @State private var isDropTargeted = false
    @State private var pendingNotionPageID: String?
    @State private var isReplaceConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.selectedProject == nil && model.videoURL == nil {
                emptyState
            } else {
                workspace
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
        .sheet(isPresented: $model.isNotionImporterPresented) {
            notionImporter
        }
        .alert("Video HQ", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Something went wrong.")
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
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
                Button("Choose Video", systemImage: "folder") {
                    model.openVideoPanel()
                }
            }

            HStack(spacing: 10) {
                Label("Project", systemImage: "folder.fill")
                    .font(.headline)
                if model.projects.isEmpty {
                    Text("No projects found")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Project", selection: projectSelection) {
                        ForEach(model.projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refreshProjects()
                }
                .labelStyle(.iconOnly)
                .help("Refresh projects")
                Spacer()
                if let selectedProject = model.selectedProject {
                    Text(selectedProject.directoryURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                Text(isDropTargeted ? "Drop your video" : "No video projects found")
                    .font(.title2.weight(.semibold))
                Text("Add a folder to ~/Movies/Projects, drag in a video, or choose one from Finder.")
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

    private var workspace: some View {
        HSplitView {
            videoPane
                .frame(minWidth: 430, idealWidth: 580)
            toolsPane
                .frame(minWidth: 500, idealWidth: 590)
        }
    }

    private var videoPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedProject?.name ?? "Selected Video")
                        .font(.headline)
                    if model.renderedVideos.count == 1, let videoURL = model.videoURL {
                        Text(videoURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.renderedVideos.isEmpty {
                        Text("No MP4 render in the project root")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.renderedVideos.count > 1 {
                    Picker("Render", selection: renderSelection) {
                        ForEach(model.renderedVideos, id: \.self) { video in
                            Text(video.lastPathComponent).tag(video)
                        }
                    }
                    .frame(maxWidth: 280)
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
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("No rendered video found")
                        .font(.headline)
                    Text("Video HQ looks for MP4 files directly inside the project folder.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Choose a Video", systemImage: "folder") {
                        model.openVideoPanel()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(20)
    }

    private var toolsPane: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(VideoHQModel.Panel.allCases) { panel in
                    panelCard(panel)
                }
            }
            resultPanel
        }
        .padding(20)
    }

    private func panelCard(_ panel: VideoHQModel.Panel) -> some View {
        let isSelected = model.selectedPanel == panel
        let isComplete = model.hasResult(for: panel)
        let isWorking = model.workingPanel == panel

        return Button {
            model.selectOrRun(panel)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: panel.icon)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(panel.rawValue)
                    .font(.headline)
                    .lineLimit(1)
                Text(panelSubtitle(panel, isComplete: isComplete))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
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

    private func panelSubtitle(_ panel: VideoHQModel.Panel, isComplete: Bool) -> String {
        if isComplete {
            return panel == .script ? "Found in project" : "Saved beside video"
        }
        return panel == .script ? "Download from Notion" : "Click to run"
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.selectedPanel.rawValue, systemImage: model.selectedPanel.icon)
                    .font(.headline)
                Spacer()
                if !model.activeText.isEmpty {
                    Button("Reveal", systemImage: "folder") {
                        model.revealActiveFile()
                    }
                    Button("Copy", systemImage: "doc.on.doc") {
                        model.copyActiveText()
                    }
                }
                if model.selectedPanel == .script {
                    Button(model.hasProjectScript ? "Replace from Notion" : "Download from Notion") {
                        model.openNotionImporter()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedProject == nil || model.isWorking)
                } else {
                    Button(model.hasResult(for: model.selectedPanel) ? "Run Again" : "Run") {
                        model.run(model.selectedPanel)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRunSelectedPanel || model.isWorking)
                }
            }
            .padding(14)

            Divider()

            if model.workingPanel == model.selectedPanel {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(model.statusMessage)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.activeText.isEmpty {
                emptyPanel
            } else {
                ScrollView {
                    Text(model.activeText)
                        .font(.system(.body, design: model.selectedPanel == .script ? .default : .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
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

    private var emptyPanel: some View {
        VStack(spacing: 10) {
            Image(systemName: model.selectedPanel.icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(emptyPanelTitle)
                .font(.headline)
            Text(emptyPanelMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPanelTitle: String {
        switch model.selectedPanel {
        case .script: return "No script found"
        case .transcript: return "No transcript yet"
        case .description: return "No video description yet"
        }
    }

    private var emptyPanelMessage: String {
        switch model.selectedPanel {
        case .script:
            return "Video HQ looks for script.md or another script-named Markdown or text file in the project root."
        case .transcript:
            return "The transcript will be saved as an SRT beside the rendered video."
        case .description:
            return "A transcript will be generated first if this video does not have one."
        }
    }

    private var notionImporter: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.hasProjectScript ? "Replace Script from Notion" : "Download Script from Notion")
                        .font(.title2.weight(.semibold))
                    Text("The page will be saved as script.md in \(model.selectedProject?.name ?? "the project").")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    model.isNotionImporterPresented = false
                }
            }

            if !model.hasNotionAPIKey {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Notion API key needed", systemImage: "key.fill")
                        .font(.headline)
                    Text("Add NOTION_API_KEY=your_token to \(model.notionSetupPath), then reopen Video HQ. Share the script page with that Notion integration too.")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Paste a Notion page link")
                    .font(.headline)
                HStack {
                    TextField("https://www.notion.so/Your-Video-Script-...", text: $model.notionPageReference)
                        .textFieldStyle(.roundedBorder)
                    Button("Download") {
                        requestReferenceDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasNotionAPIKey || model.notionPageReference.isEmpty || model.isNotionWorking)
                }
            }

            HStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 1)
                Text("OR SEARCH SHARED PAGES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 1)
            }

            HStack {
                TextField("Search Notion by title", text: $model.notionSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.searchNotion() }
                Button("Search", systemImage: "magnifyingglass") {
                    model.searchNotion()
                }
                .disabled(!model.hasNotionAPIKey || model.isNotionWorking)
            }

            if model.isNotionWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.notionStatusMessage)
                        .foregroundStyle(.secondary)
                }
            } else if let notionError = model.notionErrorMessage {
                Label(notionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if !model.notionStatusMessage.isEmpty {
                Text(model.notionStatusMessage)
                    .foregroundStyle(.secondary)
            }

            List(model.notionSearchResults) { page in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(page.title)
                            .font(.headline)
                        Text(page.lastEditedTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Download") {
                        requestNotionDownload(pageID: page.id)
                    }
                    .disabled(model.isNotionWorking)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
        .padding(22)
        .frame(width: 650, height: 540)
        .confirmationDialog(
            "Replace the existing script.md?",
            isPresented: $isReplaceConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Replace Script", role: .destructive) {
                if let pageID = pendingNotionPageID {
                    model.downloadNotionScript(pageID: pageID)
                }
                pendingNotionPageID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingNotionPageID = nil
            }
        } message: {
            Text("This downloads the Notion page over the project’s current script.md file.")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.selectedProject == nil && model.videoURL == nil ? "info.circle" : "checkmark.circle")
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

    private var projectSelection: Binding<URL> {
        Binding(
            get: { model.selectedProjectID ?? model.projects[0].id },
            set: { model.selectProject($0) }
        )
    }

    private var renderSelection: Binding<URL> {
        Binding(
            get: { model.videoURL ?? model.renderedVideos[0] },
            set: { model.selectRenderedVideo($0) }
        )
    }

    private func requestReferenceDownload() {
        guard let pageID = NotionPageReference.pageID(from: model.notionPageReference) else {
            model.downloadScriptFromReference()
            return
        }
        requestNotionDownload(pageID: pageID)
    }

    private func requestNotionDownload(pageID: String) {
        if model.hasProjectScript {
            pendingNotionPageID = pageID
            isReplaceConfirmationPresented = true
        } else {
            model.downloadNotionScript(pageID: pageID)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}
