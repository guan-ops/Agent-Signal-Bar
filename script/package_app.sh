#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="debug"
APP_NAME="AgentSignalLight"
APP_DISPLAY_NAME="Agent Signal Bar"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
MIN_SYSTEM_VERSION="14.0"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
SIGN_IDENTITY="${AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release|release)
      CONFIGURATION="release"
      shift
      ;;
    --debug|debug)
      CONFIGURATION="debug"
      shift
      ;;
    *)
      echo "usage: $0 [--debug|--release]" >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGING_DIR="$(mktemp -d)"
STAGED_APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
APP_CONTENTS="$STAGED_APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$APP_RESOURCES/AppIcon.icns"
RELEASE_INFO="$APP_RESOURCES/$APP_NAME-release-info.json"
trap 'rm -rf "$STAGING_DIR"' EXIT

cd "$ROOT_DIR"

swift_tool() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    swift "$@"
  elif [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" swift "$@"
  else
    swift "$@"
  fi
}

BUILD_ARGS=(--product "$APP_NAME")
CLI_BUILD_ARGS=(--product agent-signal)
if [[ "$CONFIGURATION" == "release" ]]; then
  BUILD_ARGS=(-c release "${BUILD_ARGS[@]}")
  CLI_BUILD_ARGS=(-c release "${CLI_BUILD_ARGS[@]}")
fi

swift_tool build "${BUILD_ARGS[@]}" >&2
swift_tool build "${CLI_BUILD_ARGS[@]}" >&2
BUILD_BINARY="$(swift_tool build "${BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"
CLI_BINARY="$(swift_tool build "${CLI_BUILD_ARGS[@]}" --show-bin-path)/agent-signal"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_RESOURCES/script" "$APP_RESOURCES/scripts" "$APP_RESOURCES/dist/bin"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$CLI_BINARY" "$APP_RESOURCES/dist/bin/agent-signal"
cp "$ROOT_DIR/script/export_diagnostics.sh" "$APP_RESOURCES/script/export_diagnostics.sh"
cp "$ROOT_DIR/script/install_hooks.py" "$APP_RESOURCES/script/install_hooks.py"
cp "$ROOT_DIR/scripts/agent-signal" "$APP_RESOURCES/scripts/agent-signal"
cp "$ROOT_DIR/scripts/agent-signal-run" "$APP_RESOURCES/scripts/agent-signal-run"
cp "$ROOT_DIR/scripts/codex-signal-hook" "$APP_RESOURCES/scripts/codex-signal-hook"
cp "$ROOT_DIR/scripts/claude-code-signal-hook" "$APP_RESOURCES/scripts/claude-code-signal-hook"
cp "$ROOT_DIR/scripts/generic-agent-signal-hook" "$APP_RESOURCES/scripts/generic-agent-signal-hook"
chmod +x "$APP_BINARY"
chmod +x "$APP_RESOURCES/dist/bin/agent-signal" \
  "$APP_RESOURCES/script/export_diagnostics.sh" \
  "$APP_RESOURCES/script/install_hooks.py" \
  "$APP_RESOURCES/scripts/agent-signal" \
  "$APP_RESOURCES/scripts/agent-signal-run" \
  "$APP_RESOURCES/scripts/codex-signal-hook" \
  "$APP_RESOURCES/scripts/claude-code-signal-hook" \
  "$APP_RESOURCES/scripts/generic-agent-signal-hook"

"$ROOT_DIR/script/generate_app_icon.py" "$APP_ICON"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/python3 - "$INFO_PLIST" "$RELEASE_INFO" "$APP_NAME" <<'PY'
import json
import os
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

info = plistlib.loads(Path(sys.argv[1]).read_bytes())
release_info = Path(sys.argv[2])
app_name = sys.argv[3]
signing_identity = os.environ.get("AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY") or os.environ.get("CODE_SIGN_IDENTITY")
notary_profile = os.environ.get("AGENT_SIGNAL_LIGHT_NOTARY_PROFILE") or os.environ.get("NOTARYTOOL_PROFILE")

try:
    identity_output = subprocess.check_output(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        stderr=subprocess.DEVNULL,
        text=True,
    )
    developer_id_count = sum(1 for line in identity_output.splitlines() if "Developer ID Application" in line)
except Exception:
    developer_id_count = 0

data = {
    "schema_version": 1,
    "app_name": app_name,
    "bundle_identifier": info.get("CFBundleIdentifier"),
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "minimum_system_version": info.get("LSMinimumSystemVersion"),
    "signing": {
        "mode": "developer_id" if signing_identity else "ad_hoc",
        "identity": signing_identity,
        "developer_id_identities_available": developer_id_count,
        "hardened_runtime_requested": bool(signing_identity),
        "timestamp_requested": bool(signing_identity),
    },
    "notarization": {
        "profile": notary_profile,
        "ready_to_submit": bool(signing_identity and notary_profile),
        "status": "not_submitted",
    },
}
release_info.write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
PY

find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
find "$STAGED_APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_RESOURCES/dist/bin/agent-signal" >/dev/null
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGED_APP_BUNDLE" >/dev/null
else
  codesign --force --sign - "$STAGED_APP_BUNDLE" >/dev/null
fi
find "$STAGED_APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true

mkdir -p "$DIST_DIR"
ditto --norsrc "$STAGED_APP_BUNDLE" "$APP_BUNDLE"

echo "$APP_BUNDLE"
