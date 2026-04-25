#!/usr/bin/env bash
# Install a worktrees launcher into a directory on your PATH (default: ~/.local/bin).
# The generated launcher points back to this checkout, so code changes here take effect immediately.
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
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  printf 'exec bun run %q/index.ts "$@"\n' "$here"
} > "$dest"
chmod +x "$src" "$dest"

echo "Installed: $dest (points to $here/index.ts)"
echo ""
echo "Open a new terminal and run: worktrees"
echo "If command not found, add this to ~/.zshrc (or ~/.bashrc):"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
