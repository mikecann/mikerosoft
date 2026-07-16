import Foundation

struct VideoHQConfiguration {
    let repoRoot: URL
    let projectsRoot: URL
    let openRouterAPIKey: String?
    let notionAPIKey: String?
    let credentialDotenvURL: URL

    var transcribeExecutableURL: URL {
        repoRoot.appendingPathComponent("tools/transcribe/transcribe")
    }

    static func load(
        repoRoot: URL = RepoLocator.repoRoot(),
        projectsRoot: URL = RepoLocator.projectsRoot(),
        fallbackDotenvURL: URL? = RepoLocator.fallbackDotenvURL(),
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
            credentialDotenvURL: fallbackDotenvURL ?? repoDotenvURL
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
            .appendingPathComponent("Movies/Projects", isDirectory: true)
    }
}
