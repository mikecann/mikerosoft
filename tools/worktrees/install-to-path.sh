#!/usr/bin/env bash
# Copy the worktrees launcher into a directory on your PATH (default: ~/.local/bin).
# Uses cp (not a symlink) so deleting one worktree checkout does not break the command.
set -euo pipefail

target_dir="${1:-$HOME/.local/bin}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/worktrees"
dest="$target_dir/worktrees"

if [[ ! -f "$src" ]]; then
  echo "install-to-path: missing launcher at $src" >&2
  exit 1
fi

mkdir -p "$target_dir"
rm -f "$dest"
cp "$src" "$dest"
chmod +x "$src" "$dest"

echo "Installed: $dest (copy of $src)"
echo ""
echo "Open a new terminal and run: worktrees"
echo "If command not found, add this to ~/.zshrc (or ~/.bashrc):"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
