![header](docs/header.png)

# ![](icons/world_go.png) ghopen

Opens the current git repo on GitHub in the browser. If the current branch has a pull request, it opens the PR page instead of the repo root.


## Screenshots

![ghopen screenshot](docs/ss1.png)


## Usage

**From the terminal:**
```
ghopen
```
Run from any directory inside a git repo. No arguments needed.

### macOS setup

```bash
bash tools/ghopen/setup_mac.sh
```

That installs a `ghopen` symlink into `~/.local/bin`.

**From File Explorer:**
Right-click any folder (or right-click inside an open folder), then choose **Mike's Tools > Open on GitHub**.
(On Windows 11, click "Show more options" first to get the classic menu.)
`install.ps1` registers this on both folder icons and folder backgrounds.

## Behaviour

| Situation | What opens |
|---|---|
| On a branch with an open PR | The PR page on GitHub |
| On any other branch | The repo at the current path and branch |
| `gh` not installed | The repo root (parsed from `origin` remote URL) |

## Dependencies

The [GitHub CLI](https://cli.github.com/) (`gh`) is required for PR detection and subdirectory-aware links. Without it, `ghopen` falls back to parsing the `origin` remote URL and opening the repo root.

Install `gh` via winget:

```powershell
winget install GitHub.cli
```

Or on macOS:

```bash
brew install gh
```

Or check `ghopen\deps.ps1` - it will warn if `gh` is missing.

## Notes

- Works in any git repo, not just repos in this workspace.
- If there is no `origin` remote and `gh` is not installed, the command exits with an error.
- On macOS, `ghopen` uses the native `open` command for the fallback browser flow.