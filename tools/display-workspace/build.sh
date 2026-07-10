#!/usr/bin/env bash
# Build the release binary and assemble a stable app bundle for Accessibility permission.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${DISPLAY_WORKSPACE_APP:-$HOME/Applications/Display Workspace.app}"
CONTENTS="$APP/Contents"

cd "$SCRIPT_DIR"
swift build -c release

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 ".build/release/display-workspace" "$CONTENTS/MacOS/display-workspace"
install -m 644 "Info.plist" "$CONTENTS/Info.plist"

codesign --force --deep --sign - --identifier com.mikerosoft.display-workspace "$APP" >/dev/null

echo "Built $APP"
