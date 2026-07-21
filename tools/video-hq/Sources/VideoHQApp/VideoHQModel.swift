import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class VideoHQModel: ObservableObject {
    enum Panel: String, CaseIterable, Identifiable {
        case script = "Script"
        case transcript = "Transcribe"
        case description = "Video Description"

        var id: Self { self }

        var icon: String {
            switch self {
            case .script: return "doc.text"
            case .transcript: return "captions.bubble"
            case .description: return "text.quote"
            }
        }
    }

    @Published private(set) var projects: [VideoProject] = []
    @Published private(set) var selectedProjectID: URL?
    @Published private(set) var projectScript = ""
    @Published private(set) var videoURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var transcript = ""
    @Published private(set) var description = ""
    @Published var selectedPanel: Panel = .script
    @Published private(set) var workingPanel: Panel?
    @Published private(set) var statusMessage = "Loading video projects..."
    @Published var errorMessage: String?

    @Published var isNotionImporterPresented = false
    @Published var notionPageReference = ""
    @Published var notionSearchQuery = ""
    @Published private(set) var notionSearchResults: [NotionPageSearchResult] = []
    @Published private(set) var isNotionWorking = false
    @Published private(set) var notionStatusMessage = ""
    @Published private(set) var notionErrorMessage: String?

    @Published var isNewProjectWizardPresented = false
    @Published var newProjectSource: NewProjectSource = .notion
    @Published var newProjectName = ""
    @Published var newProjectFolderName = ""
    @Published var selectedNotionProjectID: String?
    @Published private(set) var notionProjectOptions: [NotionVideoProject] = []
    @Published private(set) var isLoadingNewProjectOptions = false
    @Published private(set) var isCreatingNewProject = false
    @Published private(set) var newProjectStatusMessage = ""
    @Published private(set) var newProjectErrorMessage: String?

    private let configuration: VideoHQConfiguration?
    private let configurationError: Error?
    private let teleprompterWindowController = TeleprompterWindowController()

    convenience init() {
        do {
            self.init(configuration: try VideoHQConfiguration.load())
        } catch {
            self.init(configurationError: error)
        }
    }

    init(configuration: VideoHQConfiguration) {
        self.configuration = configuration
        configurationError = nil
        do {
            try loadProjects()
        } catch {
            statusMessage = "Could not load video projects."
            errorMessage = error.localizedDescription
        }
    }

    private init(configurationError: Error) {
        configuration = nil
        self.configurationError = configurationError
        statusMessage = "Video HQ could not load its configuration."
        errorMessage = configurationError.localizedDescription
    }

    var selectedProject: VideoProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    var renderedVideos: [URL] {
        selectedProject?.renderedVideoURLs ?? []
    }

    var hasProjectScript: Bool {
        !projectScript.isEmpty
    }

    var activeText: String {
        switch selectedPanel {
        case .script: return projectScript
        case .transcript: return transcript
        case .description: return description
        }
    }

    var isWorking: Bool {
        workingPanel != nil
    }

    var canRunSelectedPanel: Bool {
        selectedPanel == .script ? selectedProject != nil : videoURL != nil
    }

    var hasNotionAPIKey: Bool {
        configuration?.notionAPIKey != nil
    }

    var notionSetupPath: String {
        configuration?.credentialDotenvURL.path ?? "your .env file"
    }

    var canCreateNewProject: Bool {
        let hasName = !newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFolder = !newProjectFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSource = newProjectSource == .folder || selectedNotionProjectID != nil
        return hasName && hasFolder && hasSource && !isCreatingNewProject
    }

    func hasResult(for panel: Panel) -> Bool {
        switch panel {
        case .script: return !projectScript.isEmpty
        case .transcript: return !transcript.isEmpty
        case .description: return !description.isEmpty
        }
    }

    func refreshProjects() {
        do {
            try loadProjects(preferredProjectID: selectedProjectID)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not refresh video projects."
        }
    }

    func openNewProjectWizard() {
        newProjectSource = .notion
        newProjectName = ""
        newProjectFolderName = ""
        selectedNotionProjectID = nil
        notionProjectOptions = []
        newProjectStatusMessage = ""
        newProjectErrorMessage = nil
        isNewProjectWizardPresented = true
    }

    func setNewProjectName(_ name: String) {
        let oldSuggestion = NewVideoProject.folderSuggestion(for: newProjectName)
        let shouldUpdateFolder = newProjectFolderName.isEmpty || newProjectFolderName == oldSuggestion
        newProjectName = name
        if shouldUpdateFolder {
            newProjectFolderName = NewVideoProject.folderSuggestion(for: name)
        }
    }

    func setNewProjectSource(_ source: NewProjectSource) {
        guard source != newProjectSource else { return }
        newProjectSource = source
        newProjectName = ""
        newProjectFolderName = ""
        selectedNotionProjectID = nil
        newProjectStatusMessage = ""
        newProjectErrorMessage = nil
    }

    func selectNotionProject(_ id: String) {
        guard let project = notionProjectOptions.first(where: { $0.id == id }) else { return }
        selectedNotionProjectID = project.id
        newProjectName = project.name
        newProjectFolderName = NewVideoProject.folderSuggestion(for: project.name)
    }

    func loadNotionProjectOptions() {
        guard !isLoadingNewProjectOptions else { return }
        guard let client = newProjectNotionClient() else { return }
        isLoadingNewProjectOptions = true
        newProjectErrorMessage = nil
        newProjectStatusMessage = "Loading scripts from Convex Projects..."

        Task {
            do {
                notionProjectOptions = try await client.listVideoProjects()
                newProjectStatusMessage = notionProjectOptions.isEmpty
                    ? "No projects are currently in Writing or Ready to Shoot."
                    : "Choose a script in Writing or Ready to Shoot."
            } catch {
                notionProjectOptions = []
                newProjectErrorMessage = error.localizedDescription
                newProjectStatusMessage = ""
            }
            isLoadingNewProjectOptions = false
        }
    }

    func createNewProject() {
        guard canCreateNewProject, let configuration else { return }
        let notionPageID = newProjectSource == .notion ? selectedNotionProjectID : nil
        let client = notionPageID == nil ? nil : newProjectNotionClient()
        guard notionPageID == nil || client != nil else { return }

        isCreatingNewProject = true
        newProjectErrorMessage = nil
        newProjectStatusMessage = notionPageID == nil
            ? "Creating project folder..."
            : "Creating project and downloading its Notion script..."

        Task {
            do {
                let projectURL = try await NewVideoProject.create(
                    rootURL: configuration.projectsRoot,
                    folderName: newProjectFolderName,
                    notionPageID: notionPageID,
                    markdownProvider: client
                )
                try loadProjects(preferredProjectID: projectURL)
                statusMessage = "Created \(newProjectName) at \(projectURL.path)."
                isNewProjectWizardPresented = false
            } catch {
                newProjectErrorMessage = error.localizedDescription
                newProjectStatusMessage = ""
            }
            isCreatingNewProject = false
        }
    }

    func selectProject(_ id: URL?) {
        guard let id, let project = projects.first(where: { $0.id == id }) else { return }
        selectedProjectID = project.id
        selectedPanel = .script

        do {
            projectScript = try project.scriptURL.map {
                try String(contentsOf: $0, encoding: .utf8)
            } ?? ""
        } catch {
            projectScript = ""
            errorMessage = error.localizedDescription
        }

        if let firstRender = project.renderedVideoURLs.first {
            _ = loadVideo(firstRender, preferredPanel: .script)
        } else {
            clearVideo()
        }

        let scriptStatus = projectScript.isEmpty ? "No script found." : "Script loaded."
        let renderCount = project.renderedVideoURLs.count
        let renderStatus = renderCount == 0
            ? "No root MP4 render found."
            : "\(renderCount) rendered video\(renderCount == 1 ? "" : "s") found."
        statusMessage = "\(project.name) loaded. \(scriptStatus) \(renderStatus)"
    }

    func selectRenderedVideo(_ url: URL?) {
        guard let url else { return }
        _ = loadVideo(url, preferredPanel: selectedPanel)
    }

    @discardableResult
    func loadVideo(_ url: URL) -> Bool {
        loadVideo(url, preferredPanel: nil)
    }

    func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video"
        panel.prompt = "Choose Video"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let selectedProject {
            panel.directoryURL = selectedProject.directoryURL
        }
        if panel.runModal() == .OK, let url = panel.url {
            loadVideo(url)
        }
    }

    func selectOrRun(_ panel: Panel) {
        selectedPanel = panel
        guard panel != .script, !hasResult(for: panel) else { return }
        run(panel)
    }

    func run(_ panel: Panel) {
        guard !isWorking else { return }
        selectedPanel = panel
        switch panel {
        case .script:
            openNotionImporter()
        case .transcript:
            guard videoURL != nil else { return }
            runTranscription()
        case .description:
            guard videoURL != nil else { return }
            runDescription()
        }
    }

    func copyActiveText() {
        guard !activeText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(activeText, forType: .string)
        statusMessage = "Copied \(selectedPanel.rawValue.lowercased()) to the clipboard."
    }

    func openTeleprompter() {
        guard !projectScript.isEmpty else { return }
        teleprompterWindowController.show(
            script: projectScript,
            projectName: selectedProject?.name ?? "Script"
        )
        statusMessage = "Opened the script on the Elgato Prompter."
    }

    func revealActiveFile() {
        let fileURL: URL?
        switch selectedPanel {
        case .script:
            fileURL = selectedProject?.scriptURL
        case .transcript:
            fileURL = videoURL.map(VideoSidecars.transcriptURL(for:))
        case .description:
            fileURL = videoURL.map(VideoSidecars.descriptionURL(for:))
        }
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func openNotionImporter() {
        guard selectedProject != nil else {
            errorMessage = "Choose a video project before downloading a script."
            return
        }
        notionErrorMessage = nil
        notionStatusMessage = ""
        isNotionImporterPresented = true
    }

    func searchNotion() {
        guard !isNotionWorking else { return }
        guard let client = notionClient() else { return }
        isNotionWorking = true
        notionErrorMessage = nil
        notionStatusMessage = "Searching Notion..."

        Task {
            do {
                notionSearchResults = try await client.searchPages(query: notionSearchQuery)
                notionStatusMessage = notionSearchResults.isEmpty
                    ? "No shared Notion pages matched that search."
                    : "Found \(notionSearchResults.count) page\(notionSearchResults.count == 1 ? "" : "s")."
            } catch {
                notionSearchResults = []
                notionErrorMessage = error.localizedDescription
                notionStatusMessage = ""
            }
            isNotionWorking = false
        }
    }

    func downloadScriptFromReference() {
        guard let pageID = NotionPageReference.pageID(from: notionPageReference) else {
            notionErrorMessage = NotionClientError.invalidPageReference.localizedDescription
            return
        }
        downloadNotionScript(pageID: pageID)
    }

    func downloadNotionScript(pageID: String) {
        guard !isNotionWorking else { return }
        guard let project = selectedProject, let client = notionClient() else { return }
        isNotionWorking = true
        workingPanel = .script
        notionErrorMessage = nil
        notionStatusMessage = "Downloading script..."

        Task {
            do {
                let result = try await NotionScriptImporter(provider: client).importScript(
                    pageID: pageID,
                    into: project.directoryURL
                )
                projectScript = try String(contentsOf: result.scriptURL, encoding: .utf8)
                try reloadProjectMetadata()
                statusMessage = result.wasTruncated
                    ? "Downloaded script.md, but Notion reported truncated content."
                    : "Downloaded script.md to \(project.name)."
                isNotionImporterPresented = false
                notionPageReference = ""
                notionSearchResults = []
                notionStatusMessage = ""
            } catch {
                notionErrorMessage = error.localizedDescription
                notionStatusMessage = ""
            }
            isNotionWorking = false
            workingPanel = nil
        }
    }

    private func loadProjects(preferredProjectID: URL? = nil) throws {
        guard let configuration else {
            throw configurationError ?? NotionClientError.invalidResponse
        }
        projects = try VideoProjectCatalog(rootURL: configuration.projectsRoot).discover()
        guard !projects.isEmpty else {
            selectedProjectID = nil
            projectScript = ""
            clearVideo()
            statusMessage = "No project folders found in \(configuration.projectsRoot.path)."
            return
        }
        let selection = preferredProjectID.flatMap { id in projects.first { $0.id == id } } ?? projects[0]
        selectProject(selection.id)
    }

    private func reloadProjectMetadata() throws {
        guard let configuration, let selectedProjectID else { return }
        projects = try VideoProjectCatalog(rootURL: configuration.projectsRoot).discover()
        self.selectedProjectID = projects.first { $0.id == selectedProjectID }?.id
    }

    @discardableResult
    private func loadVideo(_ url: URL, preferredPanel: Panel?) -> Bool {
        guard VideoFile.isSupported(url) else {
            errorMessage = "That file is not a supported video. Choose an MP4, MOV, MKV, or another common video format."
            return false
        }

        do {
            player?.pause()
            if let matchingProject = projects.first(where: {
                $0.directoryURL.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL
            }) {
                selectedProjectID = matchingProject.id
                projectScript = try matchingProject.scriptURL.map {
                    try String(contentsOf: $0, encoding: .utf8)
                } ?? ""
            }

            let sidecars = try VideoSidecars.load(for: url)
            videoURL = url
            player = AVPlayer(url: url)
            transcript = sidecars.transcript
            description = sidecars.description
            selectedPanel = preferredPanel ?? (description.isEmpty ? .transcript : .description)

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

    private func clearVideo() {
        player?.pause()
        player = nil
        videoURL = nil
        transcript = ""
        description = ""
    }

    private func notionClient() -> NotionClient? {
        guard let configuration else {
            notionErrorMessage = configurationError?.localizedDescription ?? "Video HQ could not load its configuration."
            return nil
        }
        guard let apiKey = configuration.notionAPIKey else {
            notionErrorMessage = NotionClientError.missingAPIKey(configuration.credentialDotenvURL).localizedDescription
            return nil
        }
        return NotionClient(apiKey: apiKey)
    }

    private func newProjectNotionClient() -> NotionClient? {
        guard let configuration else {
            newProjectErrorMessage = configurationError?.localizedDescription ?? "Video HQ could not load its configuration."
            return nil
        }
        guard let apiKey = configuration.notionAPIKey else {
            newProjectErrorMessage = NotionClientError.missingAPIKey(configuration.credentialDotenvURL).localizedDescription
            return nil
        }
        return NotionClient(apiKey: apiKey)
    }

    private func runTranscription() {
        guard let videoURL else { return }
        guard let configuration else {
            errorMessage = configurationError?.localizedDescription ?? "Video HQ could not locate the repository."
            return
        }

        workingPanel = .transcript
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
            workingPanel = nil
        }
    }

    private func runDescription() {
        guard let videoURL else { return }
        guard let configuration else {
            errorMessage = configurationError?.localizedDescription ?? "Video HQ could not locate the repository."
            return
        }

        workingPanel = .description
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
                    throw VideoHQError.missingOpenRouterAPIKey(configuration.credentialDotenvURL)
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
            workingPanel = nil
        }
    }
}
