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
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$APP_RESOURCES/AppIcon.icns"
RELEASE_INFO="$APP_RESOURCES/$APP_NAME-release-info.json"
VERSION_FILE="$ROOT_DIR/VERSION"
VERSION_RESOURCE="$APP_RESOURCES/$APP_NAME-version.env"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/guan-ops/Agent-Signal-Bar/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-lEr2AUplk4vAvH+IwB4DygGqobWmBkbyy1YYr1nRy70=}"
trap 'rm -rf "$STAGING_DIR"' EXIT

cd "$ROOT_DIR"

read_version_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print $2; exit }' "$VERSION_FILE"
}

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "missing version file: $VERSION_FILE" >&2
  exit 1
fi

APP_VERSION="$(read_version_value VERSION)"
APP_BUILD="$(read_version_value BUILD)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid VERSION in $VERSION_FILE: $APP_VERSION" >&2
  exit 1
fi
if [[ ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "invalid BUILD in $VERSION_FILE: $APP_BUILD" >&2
  exit 1
fi

swift_tool() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    swift "$@"
  elif [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" swift "$@"
  else
    swift "$@"
  fi
}

clear_extended_attributes() {
  local path="$1"
  local pass
  [[ -e "$path" ]] || return 0
  xattr -cr "$path" 2>/dev/null || true
  while IFS= read -r item; do
    xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
    xattr -d com.apple.ResourceFork "$item" 2>/dev/null || true
    xattr -d "com.apple.fileprovider.fpfs#P" "$item" 2>/dev/null || true
  done < <(find "$path" -print)
  while IFS= read -r item; do
    xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
    xattr -d com.apple.ResourceFork "$item" 2>/dev/null || true
    xattr -d "com.apple.fileprovider.fpfs#P" "$item" 2>/dev/null || true
  done < <(find -L "$path" -print 2>/dev/null)

  for pass in 1 2 3 4 5; do
    local found=0
    while IFS= read -r item; do
      found=1
      xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
      xattr -d com.apple.ResourceFork "$item" 2>/dev/null || true
      xattr -d "com.apple.fileprovider.fpfs#P" "$item" 2>/dev/null || true
    done < <(
      xattr -lr "$path" 2>/dev/null \
        | awk -F': ' '/com[.]apple[.](FinderInfo|ResourceFork|fileprovider[.]fpfs#P)/ { print $1 }' \
        | sort -u
    )
    [[ "$found" -eq 0 ]] && break
  done
}

BUILD_ARGS=(--product "$APP_NAME")
CLI_BUILD_ARGS=(--product agent-signal)
if [[ "$CONFIGURATION" == "release" ]]; then
  BUILD_ARGS=(-c release "${BUILD_ARGS[@]}")
  CLI_BUILD_ARGS=(-c release "${CLI_BUILD_ARGS[@]}")
fi

swift_tool build "${BUILD_ARGS[@]}" >&2
swift_tool build "${CLI_BUILD_ARGS[@]}" >&2
BUILD_BIN_DIR="$(swift_tool build "${BUILD_ARGS[@]}" --show-bin-path)"
CLI_BIN_DIR="$(swift_tool build "${CLI_BUILD_ARGS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
CLI_BINARY="$CLI_BIN_DIR/agent-signal"
SPARKLE_FRAMEWORK="$BUILD_BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build" -path '*/Sparkle.framework' -type d -print | head -n 1 || true)"
fi
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "missing Sparkle.framework; run swift build --product $APP_NAME" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES" "$APP_RESOURCES/script" "$APP_RESOURCES/scripts" "$APP_RESOURCES/dist/bin"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$CLI_BINARY" "$APP_RESOURCES/dist/bin/agent-signal"
ditto --norsrc "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
cp "$ROOT_DIR/script/export_diagnostics.sh" "$APP_RESOURCES/script/export_diagnostics.sh"
cp "$ROOT_DIR/script/install_hooks.py" "$APP_RESOURCES/script/install_hooks.py"
cp "$ROOT_DIR/scripts/agent-signal" "$APP_RESOURCES/scripts/agent-signal"
cp "$ROOT_DIR/scripts/agent-signal-run" "$APP_RESOURCES/scripts/agent-signal-run"
cp "$ROOT_DIR/scripts/codex-signal-hook" "$APP_RESOURCES/scripts/codex-signal-hook"
cp "$ROOT_DIR/scripts/claude-code-signal-hook" "$APP_RESOURCES/scripts/claude-code-signal-hook"
cp "$ROOT_DIR/scripts/generic-agent-signal-hook" "$APP_RESOURCES/scripts/generic-agent-signal-hook"
for audio_resource in "$ROOT_DIR"/Sources/AgentSignalLight/Resources/*.{m4a,wav}; do
  [[ -e "$audio_resource" ]] || continue
  cp "$audio_resource" "$APP_RESOURCES/$(basename "$audio_resource")"
done
for license_resource in LICENSE NOTICE ASSET_LICENSES.md TRADEMARKS.md; do
  [[ -f "$ROOT_DIR/$license_resource" ]] || continue
  cp "$ROOT_DIR/$license_resource" "$APP_RESOURCES/$license_resource"
done
cp "$VERSION_FILE" "$VERSION_RESOURCE"
chmod +x "$APP_BINARY"
chmod +x "$APP_RESOURCES/dist/bin/agent-signal" \
  "$APP_RESOURCES/script/export_diagnostics.sh" \
  "$APP_RESOURCES/script/install_hooks.py" \
  "$APP_RESOURCES/scripts/agent-signal" \
  "$APP_RESOURCES/scripts/agent-signal-run" \
  "$APP_RESOURCES/scripts/codex-signal-hook" \
  "$APP_RESOURCES/scripts/claude-code-signal-hook" \
  "$APP_RESOURCES/scripts/generic-agent-signal-hook"

if ! otool -l "$APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
fi

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
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 XiongYang Guan · Apache License 2.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
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
        "identity_configured": bool(signing_identity),
        "developer_id_identities_available": developer_id_count,
        "hardened_runtime_requested": bool(signing_identity),
        "timestamp_requested": bool(signing_identity),
    },
    "notarization": {
        "profile_configured": bool(notary_profile),
        "ready_to_submit": bool(signing_identity and notary_profile),
        "status": "not_submitted",
    },
}
release_info.write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
PY

clear_extended_attributes "$APP_BUNDLE"
clear_extended_attributes "$STAGED_APP_BUNDLE"
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_FRAMEWORKS/Sparkle.framework" >/dev/null
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_RESOURCES/dist/bin/agent-signal" >/dev/null
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGED_APP_BUNDLE" >/dev/null
else
  codesign --force --deep --sign - "$APP_FRAMEWORKS/Sparkle.framework" >/dev/null
  codesign --force --sign - "$STAGED_APP_BUNDLE" >/dev/null
fi
clear_extended_attributes "$STAGED_APP_BUNDLE"

mkdir -p "$DIST_DIR"
ditto --norsrc "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
clear_extended_attributes "$APP_BUNDLE"

echo "$APP_BUNDLE"
