#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOPEN_SCRIPT="$SCRIPT_DIR/ghopen"

TEST_ROOT=""
RUN_OUTPUT=""
RUN_STATUS=0

cleanup() {
  if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
    rm -rf "$TEST_ROOT"
  fi
}

trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" = "$expected" ]; then
    return 0
  fi

  fail "$message. Expected '$expected' but got '$actual'."
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    return 0
  fi

  fail "$message. Missing '$needle' in: $haystack"
}

create_fake_git() {
  cat >"$TEST_ROOT/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "rev-parse --git-dir")
    if [ "${TEST_GIT_REPO:-1}" = "1" ]; then
      exit 0
    fi

    exit 1
    ;;
  "remote get-url origin")
    if [ -n "${TEST_REMOTE_URL:-}" ]; then
      printf '%s\n' "$TEST_REMOTE_URL"
      exit 0
    fi

    exit 1
    ;;
  *)
    echo "unexpected git args: $*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/git"
}

create_fake_gh() {
  cat >"$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'gh:%s\n' "$*" >>"$TEST_LOG"

case "$*" in
  "pr view --web")
    exit "${TEST_GH_PR_EXIT:-0}"
    ;;
  "browse")
    exit "${TEST_GH_BROWSE_EXIT:-0}"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 98
    ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/gh"
}

create_fake_open() {
  cat >"$TEST_ROOT/bin/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'open:%s\n' "$*" >>"$TEST_LOG"
EOF
  chmod +x "$TEST_ROOT/bin/open"
}

setup_test_root() {
  TEST_ROOT="$(mktemp -d)"
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo"
  create_fake_git
  create_fake_open
}

run_ghopen() {
  local repo_dir="$1"
  shift

  set +e
  RUN_OUTPUT="$(
    cd "$repo_dir" &&
      env PATH="$TEST_ROOT/bin:$PATH" "$@" "$GHOPEN_SCRIPT" 2>&1
  )"
  RUN_STATUS=$?
  set -e
}

test_errors_outside_git_repo() {
  setup_test_root
  run_ghopen "$TEST_ROOT/repo" TEST_GIT_REPO=0 TEST_LOG="$TEST_ROOT/log.txt"

  assert_eq "$RUN_STATUS" "1" "outside repo should fail"
  assert_contains "$RUN_OUTPUT" "Not a git repository." "outside repo message"
}

test_opens_pr_with_gh() {
  setup_test_root
  create_fake_gh
  run_ghopen \
    "$TEST_ROOT/repo" \
    TEST_LOG="$TEST_ROOT/log.txt" \
    TEST_GH_PR_EXIT=0

  assert_eq "$RUN_STATUS" "0" "gh PR path should succeed"
  assert_contains "$(cat "$TEST_ROOT/log.txt")" "gh:pr view --web" "should try gh pr view"
}

test_falls_back_to_gh_browse() {
  setup_test_root
  create_fake_gh
  run_ghopen \
    "$TEST_ROOT/repo" \
    TEST_LOG="$TEST_ROOT/log.txt" \
    TEST_GH_PR_EXIT=1 \
    TEST_GH_BROWSE_EXIT=0

  assert_eq "$RUN_STATUS" "0" "gh browse fallback should succeed"
  assert_contains "$(cat "$TEST_ROOT/log.txt")" "gh:browse" "should call gh browse"
}

test_falls_back_to_open_without_gh() {
  setup_test_root
  run_ghopen \
    "$TEST_ROOT/repo" \
    TEST_LOG="$TEST_ROOT/log.txt" \
    TEST_REMOTE_URL="git@github.com:mike/repo.git"

  assert_eq "$RUN_STATUS" "0" "manual remote fallback should succeed"
  assert_contains "$(cat "$TEST_ROOT/log.txt")" "open:https://github.com/mike/repo" "should open parsed GitHub URL"
}

test_rejects_non_github_remote() {
  setup_test_root
  run_ghopen \
    "$TEST_ROOT/repo" \
    TEST_LOG="$TEST_ROOT/log.txt" \
    TEST_REMOTE_URL="git@gitlab.com:mike/repo.git"

  assert_eq "$RUN_STATUS" "1" "non GitHub remote should fail"
  assert_contains "$RUN_OUTPUT" "Not a GitHub remote" "non GitHub remote message"
}

test_errors_outside_git_repo
test_opens_pr_with_gh
test_falls_back_to_gh_browse
test_falls_back_to_open_without_gh
test_rejects_non_github_remote

echo "ghopen tests passed"
