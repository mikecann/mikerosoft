# Tandem

![Tandem editing the decision-models video](docs/header.jpg)

A native macOS video editor for the Convex videos, built so Mike and his
agents can edit the same project. It replaces Filmora.

A project is a `.tandem` file (readable JSON) in the video's folder. Tandem
finds the media in that folder, pairs record-it camera and screen takes, and
works through them in the background: transcripts, scrub proxies, the
portrait cutout matte, isolated voice, loudness, waveforms and thumbnails.

## Install and run

```bash
bash tools/tandem/setup_mac.sh
bash install_mac.sh
tandem app
```

`setup_mac.sh` builds the release app into `~/Applications/Tandem.app`.
`install_mac.sh` links the `tandem` launcher onto your PATH: `tandem app
[project.tandem]` opens the editor, and every other `tandem` command is the
agent CLI (`tandem help`).

For agents, add the MCP server once:

```bash
claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp
```

Old Filmora projects and agent EDLs import with `tandem import filmora
"Video v3.wfp"` and `tandem import edl --recipe decision-models`.

Stickers, graphics, sounds, music, looks, fonts and saved segments that
every video reuses live in `~/Movies/Tandem Library`, which Tandem makes
the first time it opens. Projects use those files where they are; `tandem
archive` (File > Archive project…) copies the ones a project uses into it
before it moves to another Mac.

## Working on Tandem

```bash
swift test --package-path tools/tandem
bash tools/tandem/restart.sh
```

`restart.sh` builds a debug app and opens it. Set `TANDEM_APP_DIR` to build
somewhere other than `~/Applications/Tandem.app`.

| Doc | What's in it |
| --- | --- |
| `docs/ARCHITECTURE.md` | The contract between the modules: model, ripple modes, transforms, folders |
| `docs/PLAN.md` | The V1 task list and what's done |
| `docs/AGENTS.md` | The CLI, MCP and HTTP API for agents, with an example of every edit command |
| `docs/MEDIA.md` | Scanning, take pairing and the background analysis jobs |
| `docs/RENDER.md` | The compositor, transitions, titles, audio mix and export |
| `docs/ASSETS.md` | The asset library: sources, licences, normalising and credits |

## Layout

| Folder | What's there |
| --- | --- |
| `Sources/TandemCore` | Model, time, commands, editing, undo, journal |
| `Sources/TandemMedia` | Folder scanning, probing, analysis jobs |
| `Sources/TandemRender` | Composition, compositor, audio mix, export |
| `Sources/TandemAPI` | Project session, service, local server, MCP |
| `Sources/TandemAssets` | Asset library: catalogue, sources, normalising, credits |
| `Sources/TandemImport` | Filmora and EDL importers |
| `Sources/TandemApp` | The app |
| `Sources/TandemCLI` | The `tandem` command |
| `tests/` | XCTest targets, one per library |
