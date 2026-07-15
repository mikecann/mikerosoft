#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${CODEX_WORKTREE_PATH:-}" ]]; then
  REPO_ROOT="$CODEX_WORKTREE_PATH"
else
  REPO_ROOT="$(git rev-parse --show-toplevel)"
fi

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Codex setup: missing required command: $command_name" >&2
    exit 1
  fi
}

require_command git
require_command bun
require_command npm
require_command python3

if [[ ! -d "$REPO_ROOT/tools" || ! -f "$REPO_ROOT/website/package.json" ]]; then
  echo "Codex setup: $REPO_ROOT does not look like the mikerosoft repo root." >&2
  exit 1
fi

echo "Codex setup: installing Bun dependencies..."
while IFS= read -r package_json; do
  package_dir="$(dirname "$package_json")"
  relative_dir="${package_dir#"$REPO_ROOT"/}"
  echo "  $relative_dir"
  (cd "$package_dir" && bun install --no-save)
done < <(
  find "$REPO_ROOT/tools" \
    -type d -name node_modules -prune -o \
    -type f -name package.json -print \
    | sort
)

echo "Codex setup: installing website dependencies..."
(cd "$REPO_ROOT/website" && npm ci --no-audit --no-fund)

echo "Codex setup: ready."
echo "Heavy Python, ML, daemon, and OS integration dependencies remain opt-in per tool."
