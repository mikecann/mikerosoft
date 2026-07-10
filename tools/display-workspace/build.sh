#!/usr/bin/env bash
# Build the release binary and assemble a stable app bundle for Accessibility permission.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${DISPLAY_WORKSPACE_APP:-$HOME/Applications/Display Workspace.app}"
CONTENTS="$APP/Contents"

if [ -n "${DISPLAY_WORKSPACE_SIGNING_IDENTITY:-}" ]; then
  SIGNING_IDENTITY="$DISPLAY_WORKSPACE_SIGNING_IDENTITY"
else
  SIGNING_IDENTITY="$({
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\([^"]*\)".*/\1/p'
  } | sed -n '1p')"
fi

if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
  echo "ERROR: Display Workspace needs a stable code-signing identity." >&2
  echo "Create an Apple Development certificate in Xcode, or set DISPLAY_WORKSPACE_SIGNING_IDENTITY." >&2
  exit 1
fi

cd "$SCRIPT_DIR"
swift build -c release

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 ".build/release/display-workspace" "$CONTENTS/MacOS/display-workspace"
install -m 644 "Info.plist" "$CONTENTS/Info.plist"

codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --identifier com.mikerosoft.display-workspace \
  "$APP" >/dev/null

echo "Built $APP"
echo "Signed with $SIGNING_IDENTITY"
