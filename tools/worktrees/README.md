![header](docs/header.png)

# ![](icons/worktrees.png) worktrees

Interactive helper for cleaning up **git worktrees**. I use it when Cursor leaves a pile of linked checkouts under `.cursor/worktrees` and I want to list them, delete a few, or nuke all linked ones without touching the primary checkout.


## What it does

| Step | Detail |
|---|---|
| Detect repo | Uses `git rev-parse --show-toplevel` from your **current directory**, so you must be inside some checkout of that repo (any subfolder is fine). |
| List | Prints every worktree from `git worktree list --porcelain`, labelled **primary** vs **linked** (linked means the git dir lives under `.git/worktrees/`). |
| Remove | Only **linked** worktrees are selectable. I never try to remove the primary checkout through this UI. |
| Confirm | You get a final yes or no before anything is deleted. If a target worktree is dirty, it shows the modified and untracked files first and asks you to confirm deleting those changes. |

Removals run `git worktree remove`. If a selected worktree has local changes, the tool now shows what would be deleted and, if you confirm, force-removes it. You can still pass **`--force`** (same as `git worktree remove --force`) if you want force mode from the start.


## Dependencies

- [Bun](https://bun.sh) on your `PATH`
- `git`
- In this repo: run **`bun install`** inside `tools/worktrees` once per clone (or let Windows `install.ps1` run `deps.ps1`, which does that for you).


## macOS

1. `cd tools/worktrees && bun install`
2. Put the launcher on your `PATH` (I use **`~/.local/bin`**, same idea as dropping stubs into a folder that is already on `PATH` on Windows):

   ```bash
   bash tools/worktrees/install-to-path.sh
   ```

   That writes a small `worktrees` launcher into `~/.local/bin` pointing back to this checkout's `tools/worktrees/index.ts`. If `worktrees` is not found, add this to `~/.zshrc` and open a new terminal:

   ```bash
   export PATH="$HOME/.local/bin:$PATH"
   ```

3. From **any directory inside a checkout** of this repo:

   ```bash
   worktrees
   ```

The launcher always runs this checkout's **`tools/worktrees/index.ts`** against whichever git repo you call it from. Code changes in this checkout take effect immediately; rerun `install-to-path.sh` only if you move this repo.

You can still run **`bash tools/worktrees/run.sh`** from the repo root if you prefer not to use `~/.local/bin`.


## Windows

1. Run **`install.ps1`** at the repo root (re-run when you add or change tools). That writes **`worktrees.bat`** into `C:\dev\tools` (or whatever your tools dir is) and runs **`tools/worktrees/deps.ps1`** when Bun is installed.
2. Open a new terminal and run **`worktrees`** from any folder inside a checkout.


## Usage

```bash
worktrees          # normal remove (git may refuse if dirty)
worktrees --force  # same as -f, passes --force to git worktree remove
```

There is no non-interactive batch mode. If you need that later, we can add flags.


## Tests

From `tools/worktrees`:

```bash
bun test
```


## Icon

`icons/worktrees.png` is **`application_view_list.png`** from the [FamFamFam Silk](https://www.famfamfam.com/lab/icons/silk/) set (Mark James, [CC BY 2.5](https://creativecommons.org/licenses/by/2.5/)).
