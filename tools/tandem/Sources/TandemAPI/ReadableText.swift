import Foundation
import TandemCore
import TandemMedia

// Plain-text forms of every result, shared by the CLI's default output and
// MCP tool results. They lead with the answer, keep IDs visible (agents need
// them for the next command) and say what to do next when something is
// missing.

extension StatusResult: ReadableResult {
    public var readableText: String {
        var lines = ["\(name) (\((path as NSString).lastPathComponent))"]
        let saved = dirty ? "unsaved changes" : "saved"
        lines.append("  revision \(revision), \(saved), \(duration) long, \(width)x\(height) at \(EditCommand.number(frameRate)) fps")
        lines.append("  \(tracks) tracks, \(clips) clips, \(media) media files, \(markers) markers")
        if headless {
            lines.append("  open in: nothing else, read from the file for this command")
        } else if let openIn {
            let serving = openIn.port.map { ", serving the API on port \($0)" } ?? ""
            lines.append("  open in: \(openIn.owner == "app" ? "the Tandem app" : "tandem \(openIn.owner)") (pid \(openIn.pid))\(serving)")
        }
        if let undo { lines.append("  undo: \(undo)") }
        if let redo { lines.append("  redo: \(redo)") }
        if recoveredEdits { lines.append("  recovered unsaved edits from the journal after a crash") }
        let active = jobs.filter { $0.state == .queued || $0.state == .running }
        if active.isEmpty {
            lines.append("  background jobs: none")
        } else {
            lines.append("  background jobs:")
            for job in active {
                let progress = job.state == .running ? " \(Int(job.progress * 100))%" : ""
                lines.append("    \(job.kind.rawValue) \(job.mediaID) \(job.state.rawValue)\(progress)")
            }
        }
        for export in exports {
            lines.append("  exporting \((export.output as NSString).lastPathComponent) \(Int(export.progress * 100))%")
        }
        return lines.joined(separator: "\n")
    }
}

extension MediaResult: ReadableResult {
    public var readableText: String {
        guard !items.isEmpty else {
            return "No media in the project yet. Put files in the project folder and run `tandem media --refresh`."
        }
        var lines: [String] = []
        if !added.isEmpty { lines.append("Added \(added.count) new file\(added.count == 1 ? "" : "s").") }
        let idWidth = items.map(\.id.count).max() ?? 0
        for item in items {
            var parts = [item.id.padding(toLength: idWidth, withPad: " ", startingAt: 0), item.path, item.role.rawValue]
            if let duration = item.duration { parts.append(duration.description) }
            if let w = item.width, let h = item.height { parts.append("\(w)x\(h)") }
            if let take = item.takeID { parts.append("take \(take) +\(TimeText.duration(item.takeOffset ?? .zero))") }
            parts.append(item.clips == 1 ? "1 clip" : "\(item.clips) clips")
            if !item.exists { parts.append("MISSING FILE") }
            let analysis = item.analysis.keys.sorted().map { key -> String in
                let state = item.analysis[key]!
                if let progress = state.progress { return "\(key) \(Int(progress * 100))%" }
                return "\(key) \(state.state)"
            }
            if !analysis.isEmpty { parts.append("(" + analysis.joined(separator: ", ") + ")") }
            lines.append(parts.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }
}

extension TimelineResult: ReadableResult {
    public var readableText: String {
        if let text { return text.hasSuffix("\n") ? String(text.dropLast()) : text }
        if let project, let data = try? ProjectFile.encoder().encode(project), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "Revision \(revision)"
    }
}

extension TranscriptResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        switch scope {
        case "media": lines.append("Transcript of \(id ?? "") (times are in the file)")
        case "clip": lines.append("Transcript of clip \(id ?? "") (timeline times)")
        default: lines.append("What's said on the timeline")
        }
        if words.isEmpty {
            lines.append(missing.isEmpty ? "(no words)" : "(no words yet)")
        } else {
            lines += Self.lines(words)
        }
        if !missing.isEmpty {
            lines.append("No transcript yet for: \(missing.joined(separator: ", ")). `tandem media` shows progress.")
        }
        return lines.joined(separator: "\n")
    }

    /// Words grouped into lines that break at pauses and run to about 12
    /// words, each starting with its time, with long gaps marked.
    static func lines(_ words: [WordTiming]) -> [String] {
        var lines: [String] = []
        var current: [String] = []
        var lineStart: Time?
        var previousEnd: Time?
        for word in words {
            let gap = previousEnd.map { word.start - $0 } ?? .zero
            if !current.isEmpty && (current.count >= 12 || gap >= Time(seconds: 0.5)) {
                lines.append("\(lineStart!)  \(current.joined(separator: " "))")
                current = []
            }
            if current.isEmpty {
                lineStart = word.start
                if gap >= Time(seconds: 0.5), previousEnd != nil {
                    lines.append("           [pause \(TimeText.duration(gap))]")
                }
            }
            current.append(word.text)
            previousEnd = word.end
        }
        if !current.isEmpty, let lineStart { lines.append("\(lineStart)  \(current.joined(separator: " "))") }
        return lines
    }
}

extension SearchResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if hits.isEmpty {
            lines.append("\"\(phrase)\" isn't said on the timeline.")
        } else {
            lines.append("\"\(phrase)\" on the timeline, \(hits.count) time\(hits.count == 1 ? "" : "s"):")
            for hit in hits {
                let partial = hit.partial ? "  (cut runs through it)" : ""
                lines.append("  \(hit.start)-\(hit.end)  ...\(hit.before) [\(hit.text)] \(hit.after)...  clips \(hit.clipIDs.joined(separator: ","))\(partial)")
            }
        }
        if !unused.isEmpty {
            lines.append("In the source but not on the timeline:")
            for hit in unused {
                lines.append("  \(hit.mediaID) at \(hit.mediaStart)-\(hit.mediaEnd) (file time)  ...\(hit.before) [\(hit.text)] \(hit.after)...")
            }
        }
        if !missing.isEmpty {
            lines.append("Not searched, no transcript yet: \(missing.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }
}

extension PausesResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if pauses.isEmpty {
            lines.append("No pauses of \(TimeText.duration(minimum)) or more.")
        } else {
            lines.append("\(pauses.count) pause\(pauses.count == 1 ? "" : "s") of \(TimeText.duration(minimum)) or more, \(TimeText.duration(total)) in all:")
            for pause in pauses {
                lines.append("  \(pause.start)-\(pause.end)  \(TimeText.duration(pause.duration))  ...\(pause.before) | \(pause.after)...")
            }
        }
        if !missing.isEmpty {
            lines.append("No transcript yet for \(missing.joined(separator: ", ")), so pauses there aren't listed.")
        }
        return lines.joined(separator: "\n")
    }
}

extension TightenResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let mode = applied == nil ? "dry run" : "applied"
        if cuts.isEmpty {
            lines.append("Nothing to tighten: no pauses of \(TimeText.duration(minimum)) or more that would lose a frame.")
        } else {
            lines.append("Shorten \(cuts.count) pause\(cuts.count == 1 ? "" : "s") of \(TimeText.duration(minimum)) or more to \(TimeText.duration(keep)) (\(mode), revision \(revision)):")
            for cut in cuts {
                lines.append("  \(cut.pause.start)-\(cut.pause.end)  \(TimeText.duration(cut.pause.duration)) -> cut \(cut.cut.start)-\(cut.cut.end)  ...\(cut.pause.before) | \(cut.pause.after)...")
            }
            lines.append("Removes \(TimeText.duration(removed)): \(durationBefore) -> \(durationAfter).")
        }
        for warning in warnings { lines.append("Warning: \(warning)") }
        if let applied {
            lines.append("Applied as revision \(applied.revision) (\"\(applied.label)\"). Undo with `tandem undo`.")
        } else if !cuts.isEmpty {
            lines.append("Nothing changed yet. Run again with --apply (or apply: true) to make the cut.")
        }
        return lines.joined(separator: "\n")
    }
}

extension ApplyResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if dryRun {
            lines.append("Dry run of \"\(label)\" at revision \(revision): it would work.")
        } else if repeated {
            lines.append("Already applied \"\(label)\" (same idempotency key) as revision \(revision). Nothing changed.")
        } else {
            lines.append("Applied \"\(label)\" by \(author) as revision \(revision).")
        }
        if !createdIDs.isEmpty { lines.append("Created: \(createdIDs.joined(separator: ", "))") }
        var changes: [String] = []
        if !added.isEmpty { changes.append("\(added.count) clip\(added.count == 1 ? "" : "s") added") }
        if !removed.isEmpty { changes.append("\(removed.count) removed (\(removed.joined(separator: ", ")))") }
        if !changed.isEmpty { changes.append("\(changed.count) changed") }
        if !changes.isEmpty { lines.append(changes.joined(separator: ", ") + ". Timeline is \(duration) long.") }
        for warning in warnings { lines.append("Warning: \(warning)") }
        return lines.joined(separator: "\n")
    }
}

extension UndoResult: ReadableResult {
    public var readableText: String {
        "\(action == "undo" ? "Undid" : "Redid") \"\(label)\" (by \(author)). Now at revision \(revision)."
    }
}

extension HistoryResult: ReadableResult {
    public var readableText: String {
        var lines = ["Revision \(revision)."]
        if undo.isEmpty {
            lines.append("Nothing to undo.")
        } else {
            lines.append("Undo, newest first:")
            for entry in undo { lines.append("  \(entry.label)  (\(entry.author))") }
        }
        if let redo { lines.append("Redo: \(redo)") }
        if !events.isEmpty {
            lines.append("Recent changes:")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for event in events {
                lines.append("  \(formatter.string(from: event.date))  r\(event.revision ?? 0)  \(event.kind.rawValue)  \(event.label ?? "")  (\(event.author ?? "?"))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension ValidateResult: ReadableResult {
    public var readableText: String {
        if issues.isEmpty { return "Revision \(revision) is valid. No problems found." }
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.count - errors
        var lines = ["Revision \(revision): \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")."]
        for issue in issues {
            lines.append("  \(issue.severity.rawValue): \(issue.message)")
        }
        return lines.joined(separator: "\n")
    }
}

extension ImageResult: ReadableResult {
    public var readableText: String {
        let at = time.map { " at \($0)" } ?? ""
        if let path { return "Wrote \(path) (\(bytes) bytes)\(at)." }
        return "PNG\(at), \(bytes) bytes (base64 in the JSON result)."
    }
}

extension ExportOutcome: ReadableResult {
    public var readableText: String {
        var text = "Wrote \(path) (\(preset), \(duration) long) in \(String(format: "%.1f", elapsed))s."
        if let lufs = integratedLUFS, let peak = truePeakDBTP {
            text += String(format: " Loudness %.1f LUFS, true peak %.1f dBTP.", lufs, peak)
        }
        return text
    }
}

extension LoudnessResult: ReadableResult {
    public var readableText: String {
        var lines = [String(format: "Target %.1f LUFS, true peak ceiling %.1f dBTP.", target, truePeakCeiling)]
        if media.isEmpty {
            lines.append("No media with sound.")
        }
        for item in media {
            if let lufs = item.integratedLUFS, let peak = item.truePeakDBTP {
                lines.append(String(format: "  %@  %@  %.1f LUFS, peak %.1f dBTP, range %.1f LU", item.mediaID, item.path, lufs, peak, item.loudnessRange ?? 0))
            } else {
                lines.append("  \(item.mediaID)  \(item.path)  not measured yet (\(item.state))")
            }
        }
        let levelled = clips.filter { $0.normalizeTo != nil || $0.gainDB != 0 }
        if !levelled.isEmpty {
            lines.append("Clip levels:")
            for clip in levelled {
                var parts = ["  \(clip.clipID)  \(clip.track)"]
                if let target = clip.normalizeTo {
                    if let gain = clip.normalizeGainDB {
                        parts.append(String(format: "levelled to %.1f LUFS (%+.1f dB)", target, gain))
                    } else {
                        parts.append(String(format: "levelled to %.1f LUFS once measured", target))
                    }
                }
                if clip.gainDB != 0 { parts.append(String(format: "gain %+.1f dB", clip.gainDB)) }
                lines.append(parts.joined(separator: "  "))
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension WatchResult: ReadableResult {
    public var readableText: String {
        guard changed else { return "No change. Still at revision \(revision)." }
        var lines = ["Changed. Now at revision \(revision)."]
        for event in events {
            lines.append("  r\(event.revision ?? 0)  \(event.kind.rawValue)  \(event.label ?? "")  (\(event.author ?? "?"))")
        }
        if events.isEmpty { lines.append("  (made by another process; read the timeline to see what changed)") }
        return lines.joined(separator: "\n")
    }
}

extension EffectsResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = ["Effects (addEffect {\"type\": ..., \"params\": {...}}):"]
        for effect in effects {
            lines.append("  \(effect.type)  \(effect.domain.rawValue)  \(effect.summary)")
            for param in effect.params {
                var range = ""
                if let min = param.min, let max = param.max { range = " \(EditCommand.number(min))...\(EditCommand.number(max))" }
                let unit = param.unit.map { " \($0)" } ?? ""
                lines.append("    \(param.key): \(param.kind.rawValue)\(range)\(unit), default \(Self.text(param.defaultValue))")
            }
        }
        lines.append("Transitions: " + transitions.map { "\($0.type.rawValue) (\(TimeText.duration($0.defaultDuration)))" }.joined(separator: ", "))
        lines.append("Layouts (applyLayout): " + layouts.map { "\($0.preset.rawValue) (\($0.name))" }.joined(separator: ", "))
        lines.append("Animatable parameters (setKeyframes): " + animatable.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    static func text(_ value: ParamValue) -> String {
        switch value {
        case .number(let n): return EditCommand.number(n)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return "\"\(s)\""
        case .point(let p): return "(\(p.x), \(p.y))"
        case .color(let c): return TimelineDump.hex(c)
        }
    }
}
