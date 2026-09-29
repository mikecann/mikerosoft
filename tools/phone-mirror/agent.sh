#!/usr/bin/env bash
# Builds and starts WebDriverAgent, Apple's UI-testing runner that Phone Mirror uses to
# send taps, swipes, and typing to a phone over USB.
#
# Usage:
#   agent.sh build <udid>   fetch WebDriverAgent, sign it with your team, register the phone
#   agent.sh run <udid>     start the helper on the phone (runs until stopped)
#
# The team ID comes from PHONE_MIRROR_TEAM_ID, then "team-id" in the support folder, then the
# Apple Development certificate in your keychain (created by the first successful build).

set -euo pipefail

WDA_VERSION="v16.12.10"
BUNDLE_ID="com.mikecann.phonemirror.WebDriverAgentRunner"
SUPPORT_DIR="${PHONE_MIRROR_SUPPORT_DIR:-$HOME/Library/Application Support/Phone Mirror}"
WDA_DIR="$SUPPORT_DIR/WebDriverAgent"
DERIVED_DIR="$SUPPORT_DIR/DerivedData"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Phone Mirror's fast touch routes, compiled into WebDriverAgent (see the file's header).
FAST_INPUT="$SCRIPT_DIR/wda/PMFastInputCommands.m"
# Records which version of the fast routes the current build contains.
BUILT_STAMP="$DERIVED_DIR/phone-mirror-routes.sha"

usage() {
  echo "Usage: agent.sh build|run <udid>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
COMMAND="$1"
UDID="$2"

team_id() {
  if [[ -n "${PHONE_MIRROR_TEAM_ID:-}" ]]; then
    echo "$PHONE_MIRROR_TEAM_ID"
  elif [[ -f "$SUPPORT_DIR/team-id" ]]; then
    tr -d '[:space:]' < "$SUPPORT_DIR/team-id"
  else
    # An Apple Development certificate's organizational unit is the team ID.
    security find-certificate -c "Apple Development" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' \
      | head -n 1
  fi
}

fetch_source() {
  if [[ "$(git -C "$WDA_DIR" describe --tags 2>/dev/null || true)" != "$WDA_VERSION" ]]; then
    echo "Fetching WebDriverAgent $WDA_VERSION..."
    rm -rf "$WDA_DIR"
    mkdir -p "$SUPPORT_DIR"
    git clone --quiet --depth 1 --branch "$WDA_VERSION" https://github.com/appium/WebDriverAgent.git "$WDA_DIR"
  fi
  # The stock bundle ID belongs to another team, so the runner gets its own.
  sed -i '' "s/com\.facebook\.WebDriverAgentRunner/$BUNDLE_ID/g" "$WDA_DIR/WebDriverAgent.xcodeproj/project.pbxproj"
  # Compile the fast touch routes into WebDriverAgentLib by including them from a file it builds.
  local commands="$WDA_DIR/WebDriverAgentLib/Commands"
  cp "$FAST_INPUT" "$commands/PMFastInputCommands.m"
  if ! grep -q 'PMFastInputCommands.m' "$commands/FBCustomCommands.m"; then
    printf '\n#include "PMFastInputCommands.m"\n' >> "$commands/FBCustomCommands.m"
  fi
}

routes_version() {
  shasum "$FAST_INPUT" | cut -d ' ' -f 1
}

xctestrun_file() {
  ls "$DERIVED_DIR"/Build/Products/*.xctestrun 2>/dev/null | head -n 1
}

case "$COMMAND" in
  build)
    TEAM="$(team_id)"
    if [[ -z "$TEAM" ]]; then
      echo "ERROR: no Apple developer team found. Sign into Xcode (Settings > Accounts) and put your" >&2
      echo "10-character team ID in \"$SUPPORT_DIR/team-id\", or set PHONE_MIRROR_TEAM_ID." >&2
      exit 1
    fi
    # Two phones plugged in together would otherwise build into the same folder at once.
    # A lock older than 15 minutes was left by a killed build and is cleared.
    LOCK="$SUPPORT_DIR/build.lock"
    mkdir -p "$SUPPORT_DIR"
    find "$LOCK" -maxdepth 0 -mmin +15 -exec rmdir {} \; 2>/dev/null || true
    until mkdir "$LOCK" 2>/dev/null; do sleep 2; done
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    fetch_source
    echo "Building WebDriverAgent for $UDID with team $TEAM..."
    xcodebuild build-for-testing \
      -project "$WDA_DIR/WebDriverAgent.xcodeproj" \
      -scheme WebDriverAgentRunner \
      -destination "id=$UDID" \
      -derivedDataPath "$DERIVED_DIR" \
      -allowProvisioningUpdates \
      -allowProvisioningDeviceRegistration \
      CODE_SIGN_STYLE=Automatic \
      DEVELOPMENT_TEAM="$TEAM"
    echo "$TEAM" > "$SUPPORT_DIR/team-id"
    routes_version > "$BUILT_STAMP"
    ;;
  run)
    XCTESTRUN="$(xctestrun_file)"
    if [[ -z "$XCTESTRUN" ]]; then
      echo "ERROR: WebDriverAgent isn't built yet. Run: agent.sh build $UDID" >&2
      exit 3
    fi
    if [[ "$(cat "$BUILT_STAMP" 2>/dev/null || true)" != "$(routes_version)" ]]; then
      echo "ERROR: WebDriverAgent was built without the current fast touch routes. Run: agent.sh build $UDID" >&2
      exit 3
    fi
    exec xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID"
    ;;
  *)
    usage
    ;;
esac
