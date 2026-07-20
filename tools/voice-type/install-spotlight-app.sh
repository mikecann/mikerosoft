#!/usr/bin/env bash
# Stage a small application bundle so Spotlight can open Voice Type settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${VOICE_TYPE_APP_DIR:-$HOME/Applications/Voice Type.app}"
APP_BIN="$APP_DIR/Contents/MacOS/voice-type-settings"
ICON_SOURCE="$SCRIPT_DIR/icons/sound.png"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_BIN" <<EOF
#!/usr/bin/env bash
exec bash "$SCRIPT_DIR/open-settings-mac.sh"
EOF
chmod +x "$APP_BIN"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Voice Type</string>
  <key>CFBundleExecutable</key>
  <string>voice-type-settings</string>
  <key>CFBundleIdentifier</key>
  <string>com.mikerosoft.voice-type</string>
  <key>CFBundleName</key>
  <string>Voice Type</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -f "$ICON_SOURCE" ]] && command -v iconutil >/dev/null 2>&1; then
  ICON_WORK="$(mktemp -d)"
  trap 'mv "$ICON_WORK" "$HOME/.Trash/voice-type-icon-work-$(date +%s)" 2>/dev/null || true' EXIT
  ICONSET="$ICON_WORK/VoiceType.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/VoiceType.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string VoiceType' "$APP_DIR/Contents/Info.plist"
fi

codesign --force --deep --timestamp=none --sign - "$APP_DIR" >/dev/null
touch "$APP_DIR"

# Ask Launch Services and Spotlight to notice the newly staged bundle now.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DIR"
fi
mdimport "$APP_DIR" >/dev/null 2>&1 || true

echo "Installed: $APP_DIR"
