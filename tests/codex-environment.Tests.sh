#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT_FILE="$REPO_ROOT/.codex/environments/environment.toml"
SETUP_SCRIPT="$REPO_ROOT/.codex/setup.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$ENVIRONMENT_FILE" ]] || fail "missing $ENVIRONMENT_FILE"
[[ -f "$SETUP_SCRIPT" ]] || fail "missing $SETUP_SCRIPT"

grep -Fq 'version = 1' "$ENVIRONMENT_FILE" || fail "environment version is missing"
grep -Fq 'name = "mikerosoft"' "$ENVIRONMENT_FILE" || fail "environment name is missing"
grep -Fq 'bash .codex/setup.sh' "$ENVIRONMENT_FILE" || fail "environment does not run the setup script"

bash -n "$SETUP_SCRIPT"

python3 - "$REPO_ROOT" <<'PY'
import json
from pathlib import Path
import sys

repo_root = Path(sys.argv[1])
missing_typescript = []

for package_path in sorted((repo_root / "tools").glob("*/package.json")):
    package = json.loads(package_path.read_text())
    typecheck = package.get("scripts", {}).get("typecheck", "")
    dependencies = {
        **package.get("dependencies", {}),
        **package.get("devDependencies", {}),
    }
    if "tsc" in typecheck.split() and "typescript" not in dependencies:
        missing_typescript.append(str(package_path.relative_to(repo_root)))

if missing_typescript:
    raise SystemExit(
        "typecheck scripts missing a local TypeScript dependency: "
        + ", ".join(missing_typescript)
    )
PY

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

FIXTURE_ROOT="$TEMP_DIR/repo"
FAKE_BIN="$TEMP_DIR/bin"
CALL_LOG="$TEMP_DIR/calls.log"

mkdir -p \
  "$FAKE_BIN" \
  "$FIXTURE_ROOT/tools/alpha" \
  "$FIXTURE_ROOT/tools/bravo/tests/e2e" \
  "$FIXTURE_ROOT/website"

printf '{}\n' > "$FIXTURE_ROOT/tools/alpha/package.json"
printf '{}\n' > "$FIXTURE_ROOT/tools/bravo/tests/e2e/package.json"
printf '{}\n' > "$FIXTURE_ROOT/website/package.json"
printf '{}\n' > "$FIXTURE_ROOT/website/package-lock.json"

for command in bun npm; do
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s|%s|%s\n" "$(basename "$0")" "$PWD" "$*" >> "$CODEX_BOOTSTRAP_CALL_LOG"' \
    > "$FAKE_BIN/$command"
  chmod +x "$FAKE_BIN/$command"
done

CODEX_WORKTREE_PATH="$FIXTURE_ROOT" \
CODEX_BOOTSTRAP_CALL_LOG="$CALL_LOG" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
  bash "$SETUP_SCRIPT"

EXPECTED_CALLS="$TEMP_DIR/expected-calls.log"
printf '%s\n' \
  "bun|$FIXTURE_ROOT/tools/alpha|install --no-save" \
  "bun|$FIXTURE_ROOT/tools/bravo/tests/e2e|install --no-save" \
  "npm|$FIXTURE_ROOT/website|ci --no-audit --no-fund" \
  > "$EXPECTED_CALLS"

diff -u "$EXPECTED_CALLS" "$CALL_LOG"

echo "PASS: Codex environment bootstrap"
