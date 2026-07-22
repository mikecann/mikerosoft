#!/usr/bin/env bash
# Build, stage, sign, and launch Video HQ as a normal macOS application.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRIMARY_REPO_ROOT="$(git -C "$REPO_ROOT" worktree list --porcelain | sed -n 's/^worktree //p' | head -n 1)"
DOTENV_PATH="${VIDEO_HQ_DOTENV_PATH:-$PRIMARY_REPO_ROOT/.env}"
PROJECTS_ROOT="${VIDEO_HQ_PROJECTS_ROOT:-$HOME/dev/convex/convex-videos}"
FILMORA_AUTOMATION_ROOT="${VIDEO_HQ_FILMORA_AUTOMATION_ROOT:-$HOME/dev/me/automate-filmora}"
ROUGH_CUT_PYTHON="${VIDEO_HQ_ROUGH_CUT_PYTHON:-$HOME/.local/share/mikerosoft-media-venv/bin/python}"
BUILD_CONFIGURATION="${VIDEO_HQ_BUILD_CONFIGURATION:-release}"
APP_NAME="Video HQ"
APP_DIR="${VIDEO_HQ_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
APP_BIN="$APP_DIR/Contents/MacOS/video-hq"
ICON_SOURCE="$SCRIPT_DIR/icons/video-hq.png"
SIGNING_IDENTITY="${VIDEO_HQ_CODESIGN_IDENTITY:-}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LEGACY_APP_DIR="$HOME/Applications/Video Misc.app"
LEGACY_APP_BIN="$LEGACY_APP_DIR/Contents/MacOS/video-misc"
OPEN_APP=1

if [[ "${1:-}" == "--no-open" ]]; then
  OPEN_APP=0
elif [[ -n "${1:-}" ]]; then
  echo "Usage: setup_mac.sh [--no-open]" >&2
  exit 2
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH. Install Xcode or Command Line Tools first." >&2
  exit 1
fi

mkdir -p "$PROJECTS_ROOT"

if [[ ! -x "$REPO_ROOT/tools/transcribe/transcribe" ]]; then
  echo "ERROR: missing executable transcribe launcher at $REPO_ROOT/tools/transcribe/transcribe" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "WARNING: ffmpeg is missing. Transcribe will not work until you run:" >&2
  echo "  bash $REPO_ROOT/tools/transcribe/deps.sh" >&2
fi

if [[ ! -d "$FILMORA_AUTOMATION_ROOT/filmora_wfp" ]]; then
  echo "WARNING: Filmora rough-cut tools are missing at $FILMORA_AUTOMATION_ROOT." >&2
  echo "         Set VIDEO_HQ_FILMORA_AUTOMATION_ROOT before setup to use Rough Cut Review." >&2
fi

if [[ ! -x "$ROUGH_CUT_PYTHON" ]]; then
  echo "WARNING: Rough-cut Python is missing at $ROUGH_CUT_PYTHON." >&2
  echo "         Set VIDEO_HQ_ROUGH_CUT_PYTHON to Python with faster-whisper installed." >&2
elif ! "$ROUGH_CUT_PYTHON" -c "import faster_whisper" >/dev/null 2>&1; then
  echo "WARNING: $ROUGH_CUT_PYTHON cannot import faster_whisper." >&2
  echo "         Rough Cut Review can reuse an SRT, but fresh word-level transcription will fail." >&2
fi

echo "Building Video HQ ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/video-hq"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: built binary not found at $BINARY" >&2
  exit 1
fi

for existing_binary in "$APP_BIN" "$LEGACY_APP_BIN"; do
  if pgrep -f "$existing_binary" >/dev/null 2>&1; then
    echo "Stopping $(basename "$(dirname "$(dirname "$(dirname "$existing_binary")")")")..."
    pkill -f "$existing_binary" || true
    for _ in 1 2 3 4 5; do
      pgrep -f "$existing_binary" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi
done

rm -rf "$LEGACY_APP_DIR"

echo "Staging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_BIN"
chmod +x "$APP_BIN"

if [[ -f "$ICON_SOURCE" ]] && command -v iconutil >/dev/null 2>&1; then
  ICON_WORK="$(mktemp -d)"
  trap 'rm -rf "$ICON_WORK"' EXIT
  ICONSET="$ICON_WORK/VideoHQ.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/VideoHQ.icns"
fi

cat >"$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>video-hq</string>
    <key>CFBundleIdentifier</key>
    <string>com.mikerosoft.video-hq</string>
    <key>CFBundleName</key>
    <string>Video HQ</string>
    <key>CFBundleDisplayName</key>
    <string>Video HQ</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>VideoHQ</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>VideoHQRepoRoot</key>
    <string>$REPO_ROOT</string>
    <key>VideoHQDotenvPath</key>
    <string>$DOTENV_PATH</string>
    <key>VideoHQProjectsRoot</key>
    <string>$PROJECTS_ROOT</string>
    <key>VideoHQFilmoraAutomationRoot</key>
    <string>$FILMORA_AUTOMATION_ROOT</string>
    <key>VideoHQRoughCutPython</key>
    <string>$ROUGH_CUT_PYTHON</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
touch "$APP_DIR"

# Replacing an app bundle in place does not reliably refresh Launch Services or
# Spotlight. Register and import it explicitly so a fresh install behaves like a
# normal app in ~/Applications and appears in Spotlight immediately.
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DIR"
fi
/usr/bin/mdimport "$APP_DIR"

SPOTLIGHT_READY=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ARCHITECTURES="$(mdls -raw -name kMDItemExecutableArchitectures "$APP_DIR")"
  SPOTLIGHT_MATCHES="$(mdfind 'kMDItemCFBundleIdentifier == "com.mikerosoft.video-hq"')"
  if [[ "$ARCHITECTURES" == *arm64* && "$SPOTLIGHT_MATCHES" == *"$APP_DIR"* ]]; then
    SPOTLIGHT_READY=1
    break
  fi
  sleep 0.2
done

if [[ "$SPOTLIGHT_READY" -ne 1 ]]; then
  echo "ERROR: macOS did not index Video HQ as a Spotlight application." >&2
  exit 1
fi

echo "Installed: $APP_DIR"
if [[ "$OPEN_APP" -eq 1 ]]; then
  open "$APP_DIR"
  echo "Opened Video HQ."
fi
