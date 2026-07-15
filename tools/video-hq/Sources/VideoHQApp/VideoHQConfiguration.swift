import Foundation

struct VideoHQConfiguration {
    let repoRoot: URL
    let openRouterAPIKey: String?

    var transcribeExecutableURL: URL {
        repoRoot.appendingPathComponent("tools/transcribe/transcribe")
    }

    static func load(
        repoRoot: URL = RepoLocator.repoRoot(),
        fallbackDotenvURL: URL? = RepoLocator.fallbackDotenvURL(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> VideoHQConfiguration {
        let environmentKey = environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dotenvKey = try dotenvValue(
            named: "OPENROUTER_API_KEY",
            at: repoRoot.appendingPathComponent(".env")
        )
        let fallbackKey = try fallbackDotenvURL.flatMap {
            try dotenvValue(named: "OPENROUTER_API_KEY", at: $0)
        }
        let key = [environmentKey, dotenvKey, fallbackKey]
            .compactMap { $0 }
            .first { !$0.isEmpty }

        return VideoHQConfiguration(repoRoot: repoRoot, openRouterAPIKey: key)
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
}
