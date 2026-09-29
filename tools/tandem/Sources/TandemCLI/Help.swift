import Foundation
import TandemAPI

/// One CLI command: its usage line, what it does and the options it takes.
struct CommandHelp {
    var name: String
    var usage: String
    var summary: String
    var options: Set<String>
    var details: String = ""
}

enum Help {
    static let commands: [CommandHelp] = [
        CommandHelp(name: "new", usage: "tandem new <path.tandem> [--name <name>] [--portrait | --size <width>x<height>]", summary: "Create a project with Mike's usual tracks and add the media in its folder.", options: ["name", "portrait", "size"],
                    details: "The canvas is 3840x2160 unless you say otherwise: --portrait makes a 1080x1920 short, --size any other size."),
        CommandHelp(name: "status", usage: "tandem status", summary: "Revision, length, unsaved changes, who has it open, undo and background jobs.", options: []),
        CommandHelp(name: "media", usage: "tandem media [--refresh]", summary: "Media files, how many clips use each, and analysis status.", options: ["refresh"],
                    details: "--refresh scans the project folder for new files first."),
        CommandHelp(name: "timeline", usage: "tandem timeline [--from <time>] [--to <time>] [--words] [--summary] [--json]", summary: "The edit as readable text (or the project JSON).", options: ["from", "to", "words", "summary"],
                    details: "Tracks top to bottom as the app shows them, one line per clip. --summary gives one line per track, for finding your way round a long edit; --words adds what's said in each voice clip; --json prints the project JSON."),
        CommandHelp(name: "apply", usage: "tandem apply <file.json | -> [--dry-run] [--expect <revision>] [--label <text>] [--key <id>]", summary: "Apply a batch of edit commands as one undo step.", options: ["dry-run", "expect", "label", "key"],
                    details: """
                    The JSON can be a batch {"label": ..., "commands": [...]}, a list of commands, or one command like {"blade": {"at": 12.5}}.
                    --expect refuses the edit unless the project is at that revision. --key makes a retry safe (idempotency key).
                    `tandem schema` prints the JSON schema; docs/AGENTS.md has an example of every command.
                    """),
        CommandHelp(name: "undo", usage: "tandem undo [--expect <revision>]", summary: "Undo the last edit.", options: ["expect"]),
        CommandHelp(name: "redo", usage: "tandem redo [--expect <revision>]", summary: "Redo the last undone edit.", options: ["expect"]),
        CommandHelp(name: "history", usage: "tandem history [--limit <n>]", summary: "What undo would undo, newest first, and recent changes.", options: ["limit"]),
        CommandHelp(name: "validate", usage: "tandem validate", summary: "Check the project for problems (exit code 1 if it has errors).", options: []),
        CommandHelp(name: "transcript", usage: "tandem transcript [<clip or media id>] [--from <time>] [--to <time>]", summary: "Word timings for a clip (timeline times), a file (file times) or the whole timeline.", options: ["from", "to"]),
        CommandHelp(name: "search", usage: "tandem search \"<phrase>\" [--limit <n>]", summary: "Find where a phrase is said, as timeline times and clip IDs.", options: ["limit"]),
        CommandHelp(name: "pauses", usage: "tandem pauses [--min 0.6] [--from <time>] [--to <time>]", summary: "Silences between words, in timeline time.", options: ["min", "from", "to"]),
        CommandHelp(name: "tighten", usage: "tandem tighten [--min 0.6] [--keep 0.15] [--from <time>] [--to <time>] [--apply]", summary: "Shorten pauses over --min down to --keep (a dry run without --apply).", options: ["min", "keep", "from", "to", "apply", "label", "expect"]),
        CommandHelp(name: "short", usage: "tandem short [--apply]", summary: "Lay the edit out as a 9:16 short too: screen on top, camera below (a dry run without --apply).", options: ["apply", "label", "expect"],
                    details: "Adds the portrait format (1080x1920) and places each video clip in it; the landscape edit is untouched. Then `tandem export --preset short`. Usually you'd Save As a short version of the project first and cut it down."),
        CommandHelp(name: "captions", usage: "tandem captions [--from <time>] [--to <time>] [--max-words 3] [--y 0.42] [--track Captions] [--apply]", summary: "Add word-by-word captions from the transcripts (a dry run without --apply).", options: ["from", "to", "max-words", "y", "track", "apply", "label", "expect"],
                    details: "Captions go on a video track (made if missing, rippling with the speech), a few words at a time with the spoken word highlighted. --y places them: 0.42 (the default) sits between the screen and the camera in a short; about 0.85 suits landscape."),
        CommandHelp(name: "frame", usage: "tandem frame <time> [-o out.png] [--width <px>]", summary: "Render one frame of the timeline to a PNG.", options: ["output", "width", "height", "format"]),
        CommandHelp(name: "screenshot", usage: "tandem screenshot [-o out.png]", summary: "Save a picture of the app window (needs the app to have the project open).", options: ["output"]),
        CommandHelp(name: "clip", usage: "tandem clip <start> <end> [-o out.mp4] [--preset review]", summary: "Render part of the timeline to a review MP4.", options: ["output", "preset"]),
        CommandHelp(name: "export", usage: "tandem export [--preset youtube4k] [-o out.mp4] [--from <time>] [--to <time>]", summary: "Export the video (presets: youtube4k, youtube1080, review, short).", options: ["output", "preset", "from", "to", "format"]),
        CommandHelp(name: "archive", usage: "tandem archive [<project>] [--to <folder>] [--with-cache] [--dry-run]", summary: "Make the project standalone: copy what it uses from outside its folder into it, or with --to write a standalone copy of the whole folder somewhere else.", options: ["to", "with-cache", "dry-run", "label"],
                    details: """
                    Without --to, media, LUTs and fonts the project uses from outside its folder are copied into media/<folder they were in>/, assets/lut/ and assets/font/, and the project points at the copies (one undo step). Other .tandem files in the folder are pointed at them too.
                    With --to <folder>, the whole project folder is copied to <folder>/<project folder name>, with those files brought in and every path relative; the original is left as it was. Proxies, mattes, thumbnails and isolated voice are left out (Tandem makes them again) unless --with-cache; transcripts, waveforms and loudness always go. npm packages are left out.
                    Copies are APFS clones where they can be, checked by SHA-256 otherwise, and never replace a different file (they go beside it as "name 2"). archive.json records where each file came from. Missing files are listed and left as they are. A run that stops part way can be run again.
                    --dry-run lists what would be copied and the sizes.
                    """),
        CommandHelp(name: "relink", usage: "tandem relink [--search <folder>]... [--dry-run]", summary: "Find missing media files by name (and content) in the project folder, any --search folders and then the shared library, and point the project at them.", options: ["search", "dry-run", "label"]),
        CommandHelp(name: "loudness", usage: "tandem loudness [<media id>]", summary: "Measured loudness per file and the levelling each clip gets.", options: []),
        CommandHelp(name: "watch", usage: "tandem watch [--once] [--timeout <seconds>]", summary: "Print changes as they happen (or wait for the next one with --once).", options: ["once", "timeout"]),
        CommandHelp(name: "effects", usage: "tandem effects [<type>]", summary: "Effects with their parameters, transitions, layouts and animatable parameters.", options: []),
        CommandHelp(name: "schema", usage: "tandem schema", summary: "Print the JSON schema for edit batches.", options: []),
        CommandHelp(name: "import", usage: "tandem import filmora <file.wfp> [--keep-levels] | edl [edl.json] --recipe <name|recipe.json> | compare <a.tandem> <b.tandem> [--out <folder>] [--name <name>] [--search <folder>]... [--rewrite <from>=<to>]...", summary: "Import a Filmora project or an agent EDL, or compare two cuts of the same footage.", options: ["out", "name", "search", "rewrite", "recipe", "keep-levels"],
                    details: """
                    Writes <out>/<name>/<name>.tandem with a report beside it (<name>.import.txt and .json). --out defaults to this folder.
                    Filmora media that moved is looked for in the project's folder and every --search folder; --rewrite from=to fixes paths saved on another Mac.
                    Speech (the camera's sound, the Voice tracks) is normalised to the project's speech level, -20 LUFS, with no gain. --keep-levels keeps Filmora's own levels instead: Auto Normalization becomes normalise to -24 LUFS plus the clip's gain.
                    Built-in EDL recipes: decision-models. Exit code 1 if anything failed to import.
                    """),
        CommandHelp(name: "assets", usage: "tandem assets providers | search \"<text>\" [--kind sfx|music|sticker|...] [--provider <id>] [--online] [--limit <n>] | fetch <id> | use <id> [--at <time>] [--duration <time>] | credits [--optional] | generate sfx|music \"<prompt>\" [--duration <s>] [--variations <n>] | install-starter",
                    summary: "The asset library: find, fetch, generate and use music, sound effects, stickers, icons and logos, and build the description credits.",
                    options: ["kind", "provider", "online", "limit", "at", "duration", "label", "optional", "variations"],
                    details: """
                    providers        which sources work now, and what to fix (a key, a permission)
                    search           the library's catalogue; --online asks the providers too
                    fetch <id>       download and normalise an asset
                    use <id>         copy it into the project and add it to the media; --at places it on its track. Shared library assets (shared:...) are used where they are, not copied
                    credits          the credits block for the video description, and anything to sort out first
                    generate         make a sound effect or music cue with ElevenLabs (paid, one request per take)
                    install-starter  add the starter emoji, icons and logos to the catalogue
                    The library is per user, at ~/Library/Application Support/Tandem/Assets. The shared library folder, ~/Movies/Tandem Library, is the "shared" source.
                    """),
        CommandHelp(name: "segments", usage: "tandem segments list | save \"<name>\" (--clips <id,id> | --from <time> --to <time>) [--field <clip id>[=<label>]]... [--replace] | insert \"<name>\" --at <time> [--value <key>=<text>]... [--mode place|overwrite|insert]",
                    summary: "Reusable bits of timeline (intro, outro, like and subscribe) saved in the shared library: list them, save clips as one, put one on the timeline.",
                    options: ["clips", "from", "to", "field", "replace", "at", "value", "mode", "label"],
                    details: """
                    list     the segments in ~/Movies/Tandem Library/Segments, with their fields
                    save     save clips as a segment, with copies of the files they play beside it. --clips takes exactly those clips (linked ones aren't added); --from and --to take every clip wholly between them. --field clip_x=Title makes a title's words a field asked for on insert. --replace saves over one of the same name (files only the old one had stay, for the projects that play them; the rest goes to the Trash)
                    insert   put a segment on the timeline at --at, one undo step. Its files are used where they are in the library; archiving the project copies them in. --value key=text fills a field; --mode overwrite replaces what's in the way
                    The shared library's place is in Tandem's settings; $TANDEM_LIBRARY moves it for one command.
                    """),
        CommandHelp(name: "serve", usage: "tandem serve [--port <n>]", summary: "Open the project and serve the API until stopped (for agents, with the app closed).", options: ["port"]),
        CommandHelp(name: "mcp", usage: "tandem mcp", summary: "Run the MCP server on stdin and stdout.", options: [],
                    details: "Add it to Claude Code with: claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp"),
        CommandHelp(name: "help", usage: "tandem help [<command>]", summary: "Show help.", options: [])
    ]

    static func command(_ name: String) -> CommandHelp? {
        commands.first { $0.name == name }
    }

    static var overview: String {
        var lines = [
            "tandem \(TandemAPI.version): edit Tandem video projects from the command line.",
            "",
            "Usage: tandem <command> [arguments] [options]",
            "",
            "Commands:"
        ]
        let width = commands.map(\.name.count).max() ?? 0
        for command in commands {
            lines.append("  \(command.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(command.summary)")
        }
        lines += [
            "",
            "Options for every command:",
            "  --project <path>  The .tandem file, or its folder. Default: the one in this folder or a parent.",
            "  --author <name>   Who edits are credited to. Default: $TANDEM_AUTHOR, or \"cli\".",
            "  --json            Print the result as JSON.",
            "",
            "Times are seconds (83.5) or mm:ss.mmm (01:23.500).",
            "When the Tandem app has the project open, commands go through the app; otherwise they open the file.",
            "Run `tandem help <command>` for more."
        ]
        return lines.joined(separator: "\n")
    }

    static func detail(_ command: CommandHelp) -> String {
        var lines = ["Usage: \(command.usage)", "", command.summary]
        if !command.details.isEmpty { lines += ["", command.details] }
        lines += ["", "Also: --project <path>, --author <name>, --json."]
        return lines.joined(separator: "\n")
    }
}
