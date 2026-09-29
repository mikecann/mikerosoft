import Foundation
import TandemAssets
import TandemCore

// Plain-text forms of the asset results, for `tandem assets` and the MCP
// tools. They keep asset IDs visible, since that's what the next call needs.

enum AssetText {
    static func state(_ state: AssetState) -> String {
        switch state {
        case .remote: return "not downloaded"
        case .preview: return "preview only"
        case .original: return "downloaded"
        case .normalised: return "ready"
        }
    }

    static func providerState(_ state: ProviderStatus.State) -> String {
        switch state {
        case .ready: return "ready"
        case .needsKey: return "needs a key"
        case .disabled: return "off"
        case .stub: return "not set up"
        case .limited: return "partly working"
        }
    }

    static func licence(_ licence: LicenceClass) -> String {
        licence.label.lowercased()
    }

    static func seconds(_ value: Double?) -> String? {
        value.map { String(format: "%.2fs", $0) }
    }

    /// One line per asset, in columns.
    static func table(_ assets: [Asset], indent: String = "  ") -> [String] {
        let rows = assets.map { asset -> [String] in
            [asset.id, asset.kind.rawValue, asset.name, seconds(asset.duration) ?? "", licence(asset.licenceClass), state(asset.state)]
        }
        let widths = (0..<5).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            let cells = row.enumerated().map { column, cell in
                column < 5 ? cell.padding(toLength: min(widths[column], column == 2 ? 44 : 60), withPad: " ", startingAt: 0) : cell
            }
            return indent + cells.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }
}

extension AssetProvidersResult: ReadableResult {
    public var readableText: String {
        var lines = ["Asset sources:"]
        let idWidth = providers.map(\.id.count).max() ?? 0
        let nameWidth = providers.map(\.displayName.count).max() ?? 0
        let stateWidth = providers.map { AssetText.providerState($0.status.state).count }.max() ?? 0
        for provider in providers {
            var line = "  " + provider.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            line += "  " + provider.displayName.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            line += "  " + AssetText.providerState(provider.status.state).padding(toLength: stateWidth, withPad: " ", startingAt: 0)
            var what = [provider.kinds.joined(separator: ", ")]
            if provider.capabilities.generate { what.append("generates") }
            if provider.capabilities.search { what.append("searches") }
            line += "  " + what.joined(separator: "; ")
            lines.append(line)
            if let message = provider.status.message, !message.isEmpty {
                lines.append("      " + message)
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension AssetSearchResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let about = text.isEmpty ? "" : " for \"\(text)\""
        if local.isEmpty {
            lines.append("Nothing in the library\(about).")
        } else {
            let shown = local.count < total ? "\(local.count) of \(total)" : "\(total)"
            lines.append("\(shown) in the library\(about):")
            lines += AssetText.table(local)
        }
        if let online {
            lines.append("Online:")
            for answer in online {
                if let error = answer.error {
                    lines.append("  \(answer.provider): couldn't search. \(error)")
                } else if answer.assets.isEmpty {
                    lines.append("  \(answer.provider): nothing found")
                } else {
                    lines.append("  \(answer.provider): \(answer.assets.count) found")
                    lines += AssetText.table(answer.assets, indent: "    ")
                }
            }
        } else if local.isEmpty {
            lines.append("Search the providers too with --online (MCP: online: true), or add the starter set with install-starter.")
        }
        if !local.isEmpty || !(online?.allSatisfy { $0.assets.isEmpty } ?? true) {
            lines.append("Add one to the project with assets use <id> (and at <time> to place it).")
        }
        return lines.joined(separator: "\n")
    }
}

extension AssetFetchResult: ReadableResult {
    public var readableText: String {
        var parts = [asset.kind.rawValue]
        if let duration = AssetText.seconds(asset.duration) { parts.append(duration) }
        var lines = ["\(asset.name) (\(parts.joined(separator: ", "))) is \(AssetText.state(asset.state)): \(file ?? "no file")"]
        if let licence {
            lines.append("Licence: \(licence.name) (\(AssetText.licence(licence.licenceClass)))" + (licence.creditLine.map { ". Credit: \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

extension AssetUseResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if mediaID == nil {
            if !fonts.isEmpty {
                lines.append("Installed the font \(asset.name) (\(fonts.joined(separator: ", "))). Use it in a title's style: {\"font\": \"\(fonts[0])\"}.")
            } else if referencedInPlace == true {
                lines.append("\(asset.name) is used where it is in the shared library: \(files.joined(separator: ", ")).")
            } else {
                lines.append("Copied \(asset.name) into the project: \(files.joined(separator: ", ")).")
            }
        } else if let at, let applied {
            var where_ = "on \(trackName ?? "its track")"
            if let gainDB { where_ += " at \(CommandText.number(gainDB)) dB" }
            lines.append("Placed \(asset.name) (\(asset.kind.rawValue)) at \(at) \(where_) as revision \(applied.revision).")
            lines.append("Media \(mediaID ?? ""): \(files.joined(separator: ", ")). Clips: \(applied.createdIDs.filter { $0.hasPrefix("clip_") }.joined(separator: ", ")).")
            for warning in applied.warnings { lines.append("Warning: \(warning)") }
        } else if let applied {
            lines.append("Added \(asset.name) to the project's media as \(mediaID ?? "") (revision \(applied.revision)): \(files.joined(separator: ", ")).")
            lines.append("Place it with placeMedia {\"mediaIDs\": [\"\(mediaID ?? "")\"], \"at\": <seconds>}, or use the asset again with at.")
        } else {
            lines.append("\(asset.name) is already in the project as \(mediaID ?? ""): \(files.joined(separator: ", ")).")
        }
        if referencedInPlace == true, mediaID != nil {
            lines.append("It's the shared library's file, not a copy: changing it there changes it here, and archiving the project copies it in.")
        }
        if let licence, licence.licenceClass == .creditNeeded || licence.licenceClass == .unknown {
            lines.append("It needs a credit in the description; assets credits has the line.")
        } else if asset.licenceClass == .creditNeeded {
            lines.append("It needs a credit in the description; assets credits has the line.")
        }
        return lines.joined(separator: "\n")
    }
}

extension AssetCreditsResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if text.isEmpty {
            lines.append("Nothing in this project needs a credit.")
        } else {
            lines.append("Paste into the description:")
            lines.append("")
            lines.append(text)
        }
        let optional = credits.entries.filter { !$0.required }
        if !includeOptional && !optional.isEmpty {
            lines.append("")
            lines.append("Courtesy credits nobody requires (include them with optional credits):")
            lines += optional.map { "  \($0.line)" }
        }
        if !credits.warnings.isEmpty {
            lines.append("")
            lines.append("Before publishing:")
            lines += credits.warnings.map { "  - \($0)" }
        }
        if !credits.assets.isEmpty {
            lines.append("")
            lines.append("Assets used (\(credits.assets.count)):")
            lines += credits.assets.map { "  \($0.id)  \($0.name)  \(AssetText.licence($0.licenceClass))" + ($0.licence.map { ", \($0)" } ?? "") }
        }
        return lines.joined(separator: "\n")
    }
}

extension AssetGenerateResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if assets.isEmpty {
            lines.append("Nothing was made.")
        } else {
            let noun = assets.first?.kind == .music ? "music cue" : "sound effect"
            lines.append("Made \(assets.count) \(noun)\(assets.count == 1 ? "" : "s"):")
            lines += AssetText.table(assets)
            lines.append("Add one to the project with assets use <id> (and at <time> to place it).")
        }
        for failure in failures { lines.append("Failed: \(failure)") }
        return lines.joined(separator: "\n")
    }
}

extension AssetInstallStarterResult: ReadableResult {
    public var readableText: String {
        let order = ["sticker", "icon", "logo"]
        let parts = counts.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }.map { kind -> String in
            let count = counts[kind] ?? 0
            return "\(count) \(kind)\(count == 1 ? "" : "s")"
        }
        return "The starter set is in the library: \(parts.joined(separator: ", ")) (\(total) assets). Each downloads the first time it's used."
    }
}
