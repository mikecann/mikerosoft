import Foundation

struct VideoHQConfiguration {
    let repoRoot: URL
    let projectsRoot: URL
    let openRouterAPIKey: String?
    let notionAPIKey: String?
    let credentialDotenvURL: URL
    let filmoraAutomationRoot: URL
    let roughCutPythonURL: URL

    init(
        repoRoot: URL,
        projectsRoot: URL,
        openRouterAPIKey: String?,
        notionAPIKey: String?,
        credentialDotenvURL: URL,
        filmoraAutomationRoot: URL = RepoLocator.filmoraAutomationRoot(),
        roughCutPythonURL: URL = RepoLocator.roughCutPythonURL()
    ) {
        self.repoRoot = repoRoot
        self.projectsRoot = projectsRoot
        self.openRouterAPIKey = openRouterAPIKey
        self.notionAPIKey = notionAPIKey
        self.credentialDotenvURL = credentialDotenvURL
        self.filmoraAutomationRoot = filmoraAutomationRoot
        self.roughCutPythonURL = roughCutPythonURL
    }

    var transcribeExecutableURL: URL {
        repoRoot.appendingPathComponent("tools/transcribe/transcribe")
    }

    static func load(
        repoRoot: URL = RepoLocator.repoRoot(),
        projectsRoot: URL = RepoLocator.projectsRoot(),
        fallbackDotenvURL: URL? = RepoLocator.fallbackDotenvURL(),
        filmoraAutomationRoot: URL? = nil,
        roughCutPythonURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> VideoHQConfiguration {
        let repoDotenvURL = repoRoot.appendingPathComponent(".env")
        let dotenvURLs = [repoDotenvURL, fallbackDotenvURL].compactMap { $0 }
        let openRouterAPIKey = try credential(
            names: ["OPENROUTER_API_KEY"],
            environment: environment,
            dotenvURLs: dotenvURLs
        )
        let notionAPIKey = try credential(
            names: ["NOTION_API_KEY", "NOTION_TOKEN"],
            environment: environment,
            dotenvURLs: dotenvURLs
        )

        return VideoHQConfiguration(
            repoRoot: repoRoot,
            projectsRoot: projectsRoot,
            openRouterAPIKey: openRouterAPIKey,
            notionAPIKey: notionAPIKey,
            credentialDotenvURL: fallbackDotenvURL ?? repoDotenvURL,
            filmoraAutomationRoot: filmoraAutomationRoot
                ?? RepoLocator.filmoraAutomationRoot(environment: environment),
            roughCutPythonURL: roughCutPythonURL
                ?? RepoLocator.roughCutPythonURL(environment: environment)
        )
    }

    private static func credential(
        names: [String],
        environment: [String: String],
        dotenvURLs: [URL]
    ) throws -> String? {
        for name in names {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            for url in dotenvURLs {
                if let value = try dotenvValue(named: name, at: url), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func dotenvValue(named key: String, at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let contents = try String(contentsOf: url, encoding: .utf8)

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { continue }

            let candidateKey = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard candidateKey == key else { continue }

            var value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }
}

enum RepoLocator {
    static func repoRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL {
        if let configured = environment["VIDEO_HQ_REPO_ROOT"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if let configured = bundle.object(forInfoDictionaryKey: "VideoHQRepoRoot") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func fallbackDotenvURL(bundle: Bundle = .main) -> URL? {
        guard let configured = bundle.object(forInfoDictionaryKey: "VideoHQDotenvPath") as? String,
              !configured.isEmpty else { return nil }
        return URL(fileURLWithPath: configured)
    }

    static func projectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL {
        if let configured = environment["VIDEO_HQ_PROJECTS_ROOT"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if let configured = bundle.object(forInfoDictionaryKey: "VideoHQProjectsRoot") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/convex/convex-videos", isDirectory: true)
    }

    static func filmoraAutomationRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL {
        if let configured = environment["VIDEO_HQ_FILMORA_AUTOMATION_ROOT"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        if let configured = bundle.object(forInfoDictionaryKey: "VideoHQFilmoraAutomationRoot") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/me/automate-filmora", isDirectory: true)
    }

    static func roughCutPythonURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL {
        if let configured = environment["VIDEO_HQ_ROUGH_CUT_PYTHON"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        if let configured = bundle.object(forInfoDictionaryKey: "VideoHQRoughCutPython") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }

        let mediaPython = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/mikerosoft-media-venv/bin/python")
        return fileManager.isExecutableFile(atPath: mediaPython.path)
            ? mediaPython
            : URL(fileURLWithPath: "/usr/bin/python3")
    }
}
