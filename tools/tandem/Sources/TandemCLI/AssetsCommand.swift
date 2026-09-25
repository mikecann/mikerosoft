import Foundation
import TandemAPI
import TandemAssets
import TandemCore

/// `tandem assets`: the asset library. Searching, fetching and generating
/// work anywhere; `use` and `credits` work on the project, through the app
/// when it has the project open.
struct AssetsCommand {
    let directory: URL
    let environment: [String: String]

    static let subcommands = ["providers", "search", "fetch", "use", "credits", "generate", "install-starter"]

    /// The options each subcommand takes.
    static let options: [String: Set<String>] = [
        "providers": [],
        "search": ["kind", "provider", "online", "limit"],
        "fetch": [],
        "use": ["at", "duration", "label"],
        "credits": ["optional"],
        "generate": ["duration", "variations"],
        "install-starter": []
    ]

    func run(_ args: Arguments, author: String, project: () throws -> URL) async throws -> Int32 {
        guard let name = args.positionals.first else {
            throw UsageError(message: "`tandem assets` needs one of \(Self.subcommands.joined(separator: ", ")), like tandem assets search \"whoosh\" --kind sfx.")
        }
        guard let allowed = Self.options[name] else {
            let hint = Arguments.closest(name, in: Self.subcommands).map { " Did you mean `tandem assets \($0)`?" } ?? ""
            throw UsageError(message: "`tandem assets` can do \(Self.subcommands.joined(separator: ", ")), not \(name).\(hint)")
        }
        try args.check(allowed: allowed, command: "assets \(name)")
        let json = args.has("json")
        let assets = try AssetService.standard(environment: environment)
        switch name {
        case "providers":
            try args.expectPositionals(atMost: 1, command: "assets providers")
            return show(await assets.providers(), json: json)
        case "search":
            let request = AssetSearchRequest(
                text: args.positionals.dropFirst().joined(separator: " "),
                kinds: try AssetNames.parse(kinds: args.options["kind"]),
                providers: AssetNames.split(args.options["provider"]),
                online: args.has("online"),
                limit: try args.integer("limit")
            )
            return show(try await assets.search(request), json: json)
        case "fetch":
            try args.expectPositionals(atMost: 2, command: "assets fetch")
            let id = try args.positional(1, "an asset ID from a search, like tandem assets fetch noto:1f680", command: "assets fetch")
            return show(try await assets.fetch(AssetFetchRequest(id: id)), json: json)
        case "use":
            try args.expectPositionals(atMost: 2, command: "assets use")
            let id = try args.positional(1, "an asset ID from a search, like tandem assets use noto:1f680 --at 1:23", command: "assets use")
            let request = AssetUseRequest(id: id, at: try time(args, "at"), duration: try time(args, "duration"), label: args.options["label"])
            let client = ProjectClient(projectURL: try project(), author: author)
            return show(try await assets.use(request, project: client), json: json)
        case "credits":
            try args.expectPositionals(atMost: 1, command: "assets credits")
            let client = ProjectClient(projectURL: try project(), author: author)
            return show(try await assets.credits(AssetCreditsRequest(includeOptional: args.has("optional")), project: client), json: json)
        case "generate":
            try args.expectPositionals(atMost: 3, command: "assets generate")
            let kindName = try args.positional(1, "sfx or music and a prompt, like tandem assets generate sfx \"soft whoosh\"", command: "assets generate")
            guard let kind = try AssetNames.parse(kinds: kindName).first, kind == .sfx || kind == .music else {
                throw UsageError(message: "`tandem assets generate` makes sfx or music, not \(kindName).")
            }
            let prompt = try args.positional(2, "a prompt in quotes, like tandem assets generate sfx \"soft whoosh\"", command: "assets generate")
            let request = AssetGenerateRequest(kind: kind, prompt: prompt, duration: try time(args, "duration")?.seconds, variations: try args.integer("variations"))
            return show(try await assets.generate(request), json: json)
        default:
            try args.expectPositionals(atMost: 1, command: "assets install-starter")
            return show(try assets.installStarter(), json: json)
        }
    }

    private func time(_ args: Arguments, _ name: String) throws -> Time? {
        guard let text = args.options[name] else { return nil }
        guard let time = TimeText.parse(text), time >= .zero else {
            throw UsageError(message: "\"\(text)\" isn't a time. Use seconds (83.5) or mm:ss.mmm (01:23.500).")
        }
        return time
    }

    private func show<R: Encodable & ReadableResult>(_ result: R, json: Bool) -> Int32 {
        if json {
            guard let data = try? ServiceJSON.encoder(pretty: true).encode(result) else { return 1 }
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(result.readableText)
        }
        return 0
    }
}
