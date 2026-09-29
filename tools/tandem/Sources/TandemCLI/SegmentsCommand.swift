import Foundation
import TandemAPI
import TandemAssets
import TandemCore

/// `tandem segments`: reusable bits of timeline in the shared library's
/// Segments folder. `list` works anywhere; `save` reads the project and
/// `insert` edits it, through the app when it has the project open.
struct SegmentsCommand {
    let directory: URL
    let environment: [String: String]

    static let subcommands = ["list", "save", "insert"]

    /// The options each subcommand takes.
    static let options: [String: Set<String>] = [
        "list": [],
        "save": ["clips", "from", "to", "field", "replace"],
        "insert": ["at", "value", "mode", "label"]
    ]

    func run(_ args: Arguments, author: String, project: () throws -> URL) async throws -> Int32 {
        let name = args.positionals.first ?? "list"
        guard let allowed = Self.options[name] else {
            let hint = Arguments.closest(name, in: Self.subcommands).map { " Did you mean `tandem segments \($0)`?" } ?? ""
            throw UsageError(message: "`tandem segments` can do \(Self.subcommands.joined(separator: ", ")), not \(name).\(hint)")
        }
        try args.check(allowed: allowed, command: "segments \(name)")
        let json = args.has("json")
        let assets = try AssetService.standard(environment: environment)
        switch name {
        case "list":
            try args.expectPositionals(atMost: 1, command: "segments list")
            return show(assets.segments(), json: json)
        case "save":
            try args.expectPositionals(atMost: 2, command: "segments save")
            let segment = try args.positional(1, "a name and the clips, like tandem segments save \"Intro\" --clips clip_a,clip_b", command: "segments save")
            let clips = AssetNames.split(args.options["clips"])
            let from = try time(args, "from")
            let to = try time(args, "to")
            guard !clips.isEmpty || from != nil || to != nil else {
                throw UsageError(message: "`tandem segments save` needs the clips: --clips clip_a,clip_b, or --from and --to for every clip between them.")
            }
            guard clips.isEmpty || (from == nil && to == nil) else {
                throw UsageError(message: "Give --clips or --from and --to, not both.")
            }
            let fields = args.values("field").map(SegmentMaker.Field.parse)
            let request = SegmentSaveRequest(name: segment, clipIDs: clips.isEmpty ? nil : clips, from: from, to: to, fields: fields.isEmpty ? nil : fields, replace: args.has("replace") ? true : nil)
            let client = ProjectClient(projectURL: try project(), author: author)
            return show(try await assets.saveSegment(request, project: client), json: json)
        default:
            try args.expectPositionals(atMost: 2, command: "segments insert")
            let segment = try args.positional(1, "a segment's name and --at, like tandem segments insert \"Intro\" --at 0", command: "segments insert")
            guard let at = try time(args, "at") else {
                throw UsageError(message: "`tandem segments insert` needs --at, the time it starts, like --at 1:23.")
            }
            var values: [String: String] = [:]
            for pair in args.values("value") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw UsageError(message: "--value takes key=text, like --value title=\"CURSOR DOCS\".")
                }
                values[parts[0]] = parts[1]
            }
            var mode: InsertMode?
            if let text = args.options["mode"] {
                guard let parsed = InsertMode(rawValue: text) else {
                    throw UsageError(message: "--mode is place, overwrite or insert, not \(text).")
                }
                mode = parsed
            }
            let request = SegmentInsertRequest(name: segment, at: at, values: values.isEmpty ? nil : values, mode: mode, label: args.options["label"], author: author)
            let client = ProjectClient(projectURL: try project(), author: author)
            return show(try await assets.insertSegment(request, project: client), json: json)
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
