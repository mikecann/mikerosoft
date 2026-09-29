import Foundation
import TandemAPI
import TandemCore
import TandemImport

/// `tandem import`: Filmora projects, agent EDLs, and comparing two cuts.
struct ImportCommand {
    let directory: URL

    func run(_ args: Arguments) async throws -> Int32 {
        guard let kind = args.positionals.first else {
            throw UsageError(message: "`tandem import` needs filmora, edl or compare, like tandem import filmora \"Decision Models v14.wfp\".")
        }
        let json = args.has("json")
        switch kind {
        case "filmora":
            try args.expectPositionals(atMost: 2, command: "import")
            let source = try url(args.positional(1, "a .wfp file, like tandem import filmora \"Video v3.wfp\"", command: "import"))
            return try await perform(.filmora(source), args, json: json)
        case "edl":
            try args.expectPositionals(atMost: 2, command: "import")
            guard let recipeName = args.options["recipe"] else {
                throw UsageError(message: "`tandem import edl` needs --recipe (built in: \(EDLRecipe.builtInNames.joined(separator: ", ")), or a recipe JSON file).")
            }
            let recipe: EDLRecipe
            if let builtIn = try EDLRecipe.builtIn(recipeName) {
                recipe = builtIn
            } else {
                recipe = try EDLRecipe.load(from: url(recipeName))
            }
            let edl = args.positionals.count > 1 ? url(args.positionals[1]) : nil
            return try await perform(.edl(edl, recipe: recipe), args, json: json)
        case "compare":
            try args.expectPositionals(atMost: 3, command: "import")
            let a = url(try args.positional(1, "two .tandem files", command: "import"))
            let b = url(try args.positional(2, "a second .tandem file", command: "import"))
            let comparison = CutComparison.compare(
                try ProjectFile.load(from: a).project, named: a.deletingPathExtension().lastPathComponent,
                try ProjectFile.load(from: b).project, named: b.deletingPathExtension().lastPathComponent
            )
            if json {
                print(String(decoding: try ServiceJSON.encoder(pretty: true).encode(comparison), as: UTF8.self))
            } else {
                print(comparison.text)
            }
            return 0
        default:
            let hint = Arguments.closest(kind, in: ["filmora", "edl", "compare"]).map { " Did you mean `tandem import \($0)`?" } ?? ""
            throw UsageError(message: "`tandem import` can do filmora, edl or compare, not \(kind).\(hint)")
        }
    }

    private func perform(_ source: ImportRequest.Source, _ args: Arguments, json: Bool) async throws -> Int32 {
        let rewrites = try args.values("rewrite").map { pair -> MediaLocating.PathRewrite in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else {
                throw UsageError(message: "--rewrite takes from=to, like --rewrite /Users/old/=/Users/new/.")
            }
            return MediaLocating.PathRewrite(from: parts[0], to: parts[1])
        }
        let request = ImportRequest(
            source: source,
            output: url(args.options["out"] ?? "."),
            name: args.options["name"],
            searchFolders: args.values("search").map(url),
            pathRewrites: [MediaLocating.tinkerDeskHome] + rewrites,
            speechLevels: args.has("keep-levels") ? .keepFilmora : .normalize
        )
        let (projectURL, result) = try await request.perform()
        if json {
            struct Output: Encodable {
                var project: String
                var report: ImportReport
            }
            print(String(decoding: try ServiceJSON.encoder(pretty: true).encode(Output(project: projectURL.path, report: result.report)), as: UTF8.self))
        } else {
            print(result.report.text)
            print("")
            print("Wrote \(projectURL.path)")
        }
        return result.report.count(.failed) > 0 ? 1 : 0
    }

    private func url(_ path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return directory.appendingPathComponent(expanded).standardizedFileURL
    }
}
