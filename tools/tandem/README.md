# Tandem

A native macOS video editor for Convex videos, built so Mike and his agents
can edit the same project. It replaces Filmora.

- `docs/ARCHITECTURE.md` is the contract between the modules.
- `docs/PLAN.md` is the V1 task list.

## Build and run

```bash
swift test --package-path tools/tandem
bash tools/tandem/restart.sh
```

`restart.sh` builds a debug app into `~/Applications/Tandem.app` and opens it.
`build-app.sh` builds the release app. The bundle also holds the `tandem` CLI
at `Tandem.app/Contents/MacOS/tandem`.

## Layout

| Folder | What's there |
| --- | --- |
| `Sources/TandemCore` | Model, time, commands, editing, undo, journal |
| `Sources/TandemMedia` | Folder scanning, probing, analysis jobs |
| `Sources/TandemRender` | Composition, compositor, audio mix, export |
| `Sources/TandemAPI` | Project session, service, local server |
| `Sources/TandemAssets` | Asset library: catalogue, sources, normalising, credits (`docs/ASSETS.md`) |
| `Sources/TandemApp` | The app |
| `Sources/TandemCLI` | The `tandem` command |
| `tests/` | XCTest targets, one per library |
