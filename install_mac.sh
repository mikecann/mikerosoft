#!/usr/bin/env bash
# Symlink low-effort CLI launchers into a directory on PATH (default ~/.local/bin).
# Run from anywhere: bash /path/to/mikerosoft.app/install_mac.sh
# Re-run after moving the repo (symlinks are absolute).
#
# Usage:
#   install_mac.sh [target_bin_dir] [--with-bun-install|-B]
#   install_mac.sh --with-bun-install
#
#   --with-bun-install  Run "bun install" in every tools/*/ package that has package.json
#                       (Electrobun + CLI Bun apps). Requires bun on PATH.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"
WITH_BUN_INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --with-bun-install|-B)
      WITH_BUN_INSTALL=1
      ;;
    -h|--help)
      echo "Usage: install_mac.sh [target_bin_dir] [--with-bun-install|-B]"
      echo ""
      echo "  target_bin_dir     Where to place symlinks (default: ~/.local/bin)"
      echo "  --with-bun-install Also run bun install in each tools/*/ folder with package.json"
      exit 0
      ;;
    -*)
      echo "install_mac: unknown option: $arg (try --help)" >&2
      exit 1
      ;;
    *)
      TARGET_DIR="$arg"
      ;;
  esac
done

mkdir -p "$TARGET_DIR"

link_tool() {
  local name="$1"
  local rel_path="$2"
  local src="$ROOT/$rel_path"
  local dest="$TARGET_DIR/$name"

  if [[ ! -f "$src" ]]; then
    echo "install_mac: missing launcher: $src" >&2
    exit 1
  fi
  chmod +x "$src"
  ln -sf "$src" "$dest"
  echo "  $dest -> $src"
}

if [[ "$WITH_BUN_INSTALL" -eq 1 ]]; then
  if ! command -v bun >/dev/null 2>&1; then
    echo "install_mac: --with-bun-install requires bun on PATH (https://bun.sh)" >&2
    exit 1
  fi
  echo "Running bun install in tools with package.json..."
  find "$ROOT/tools" -maxdepth 2 -name package.json -print | sort | while IFS= read -r pkg; do
    dir="$(dirname "$pkg")"
    rel="${dir#"$ROOT"/}"
    echo ""
    echo "  [bun install] $rel"
    (cd "$dir" && bun install)
  done
  echo ""
fi

echo "Installing macOS CLI launchers into $TARGET_DIR"
echo ""

link_tool ghopen tools/ghopen/ghopen
link_tool worktrees tools/worktrees/worktrees
link_tool video-to-markdown tools/video-to-markdown/video-to-markdown
link_tool video-titles tools/video-titles/video-titles
link_tool video-description tools/video-description/video-description
link_tool svg-to-png tools/svg-to-png/svg-to-png
link_tool generate-from-image tools/generate-from-image/generate-from-image
link_tool removebg tools/removebg/removebg
link_tool img-to-svg tools/img-to-svg/img-to-svg
link_tool img-upscale tools/img-upscale/img-upscale
link_tool copypath tools/copypath/copypath
link_tool transcribe tools/transcribe/transcribe
link_tool 3d-viewer tools/3d-viewer/3d-viewer
link_tool face-swap tools/face-swap/face-swap
link_tool img-gen tools/img-gen/img-gen

echo ""
echo "Done."

case ":$PATH:" in
  *":$TARGET_DIR:"*)
    echo "$TARGET_DIR is already on PATH."
    ;;
  *)
    echo "Add to ~/.zshrc or ~/.bashrc if needed:"
    echo "  export PATH=\"$TARGET_DIR:\$PATH\""
    ;;
esac

echo ""
echo "Still need: bun (Bun tools), python3, repo-root .env with OPENROUTER_API_KEY for AI CLIs."
echo "Transcribe (Mac): run bash tools/transcribe/deps.sh once (ffmpeg + faster-whisper)."
echo "Electrobun apps: use 3d-viewer, face-swap, img-gen from PATH after bun install (see --with-bun-install)."
echo "Per-tool Python deps: run each tools/<name>/deps.ps1 under PowerShell on Windows,"
echo "or install the same packages with pip on this Mac (see each tool README)."
