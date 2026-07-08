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
DIST_DIR="${AGENT_SIGNAL_LIGHT_DIST_DIR:-${DIST_DIR:-$ROOT_DIR/dist}}"
source "$ROOT_DIR/script/universal_build.sh"
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
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/guan-ops/Agent-Signal-Bar/releases/latest/download/AgentSignalBar-macos-universal-appcast.xml}"
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

if [[ -z "${AGENT_SIGNAL_LIGHT_ARCHS+x}" && "$CONFIGURATION" == "release" ]]; then
  PACKAGE_ARCHS="arm64 x86_64"
else
  PACKAGE_ARCHS="${AGENT_SIGNAL_LIGHT_ARCHS:-}"
fi
PACKAGE_ARCHS="$(agent_signal_normalize_archs "$PACKAGE_ARCHS")"

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
  chmod -R u+w "$path" 2>/dev/null || true
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

  /usr/bin/python3 - "$path" <<'PY'
import os
import stat
import subprocess
import sys

root = sys.argv[1]
dangerous_attrs = (
    "com.apple.FinderInfo",
    "com.apple.ResourceFork",
    "com.apple.fileprovider.fpfs#P",
)

def clear_path(path):
    targets = [False]
    if os.path.islink(path):
        targets.append(True)

    for symlink in targets:
        for attr in dangerous_attrs:
            command = ["xattr"]
            if symlink:
                command.append("-s")
            command.extend(["-d", attr, path])
            result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                continue

            try:
                mode = os.lstat(path).st_mode if symlink else os.stat(path).st_mode
                os.chmod(path, mode | stat.S_IWUSR, follow_symlinks=not symlink)
            except Exception:
                pass
            subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

clear_path(root)
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    for name in dirs + files:
        clear_path(os.path.join(current, name))
PY

  for pass in 1 2 3 4 5 6 7 8 9 10; do
    local dirty_paths
    dirty_paths="$(mktemp)"
    xattr -lr "$path" 2>/dev/null \
      | awk -F': ' '/com[.]apple[.](FinderInfo|ResourceFork|fileprovider[.]fpfs#P)/ { print $1 }' \
      | sort -u >"$dirty_paths"

    if [[ ! -s "$dirty_paths" ]]; then
      rm -f "$dirty_paths"
      break
    fi

    while IFS= read -r item; do
      chmod u+w "$item" 2>/dev/null || true
      xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
      xattr -d com.apple.ResourceFork "$item" 2>/dev/null || true
      xattr -d "com.apple.fileprovider.fpfs#P" "$item" 2>/dev/null || true
      xattr -s -d com.apple.FinderInfo "$item" 2>/dev/null || true
      xattr -s -d com.apple.ResourceFork "$item" 2>/dev/null || true
      xattr -s -d "com.apple.fileprovider.fpfs#P" "$item" 2>/dev/null || true
    done <"$dirty_paths"
    rm -f "$dirty_paths"
  done
}

clear_signature_detritus() {
  local path="$1"
  local pass
  [[ -e "$path" ]] || return 0

  for pass in 1 2 3 4 5; do
    local dirty_paths
    dirty_paths="$(mktemp)"
    xattr -lr "$path" 2>/dev/null \
      | awk -F': ' '/com[.]apple[.](FinderInfo|ResourceFork|fileprovider[.]fpfs#P)/ { print $1 }' \
      | sort -u >"$dirty_paths"

    if [[ ! -s "$dirty_paths" ]]; then
      rm -f "$dirty_paths"
      break
    fi

    while IFS= read -r item; do
      chmod u+w "$item" 2>/dev/null || true
      xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
      xattr -d com.apple.ResourceFork "$item" 2>/dev/null || true
      xattr -d "com.apple.fileprovider.fpfs#P" "$item" 2>/dev/null || true
    done <"$dirty_paths"
    rm -f "$dirty_paths"
  done

  /usr/bin/python3 - "$path" <<'PY'
import os
import subprocess
import sys

root = sys.argv[1]
dangerous_attrs = (
    "com.apple.FinderInfo",
    "com.apple.ResourceFork",
    "com.apple.fileprovider.fpfs#P",
)

def remove_attr(path, attr):
    subprocess.run(["xattr", "-d", attr, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.islink(path):
        subprocess.run(["xattr", "-s", "-d", attr, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def clear_path(path):
    for attr in dangerous_attrs:
        remove_attr(path, attr)

clear_path(root)
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    clear_path(current)
    for name in dirs + files:
        clear_path(os.path.join(current, name))
PY

  local attr
  for attr in \
    com.apple.FinderInfo \
    com.apple.ResourceFork \
    "com.apple.fileprovider.fpfs#P"
  do
    find "$path" -xdev \( -type f -o -type d -o -type l \) -print0 \
      | xargs -0 -n 50 xattr -d "$attr" 2>/dev/null || true
  done
}

BUILD_OUTPUT_DIR="$STAGING_DIR/build"
BUILD_BINARY="$BUILD_OUTPUT_DIR/$APP_NAME"
CLI_BINARY="$BUILD_OUTPUT_DIR/agent-signal-light"
agent_signal_build_product "$APP_NAME" "$APP_NAME" "$CONFIGURATION" "$BUILD_BINARY" "$PACKAGE_ARCHS"
agent_signal_build_product "agent-signal-light" "agent-signal-light" "$CONFIGURATION" "$CLI_BINARY" "$PACKAGE_ARCHS"
BUILD_BIN_DIR="$(agent_signal_product_bin_path "$APP_NAME" "$CONFIGURATION" "$(agent_signal_first_arch "$PACKAGE_ARCHS")")"
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
cp "$CLI_BINARY" "$APP_RESOURCES/dist/bin/agent-signal-light"
ln -sf agent-signal-light "$APP_RESOURCES/dist/bin/agent-signal"
agent_signal_verify_binary_archs "$APP_BINARY" "$PACKAGE_ARCHS" "$APP_NAME app executable"
agent_signal_verify_binary_archs "$APP_RESOURCES/dist/bin/agent-signal-light" "$PACKAGE_ARCHS" "bundled agent-signal-light CLI"
ditto --norsrc --noextattr "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
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
THIRD_PARTY_LICENSES_DIR="$APP_RESOURCES/ThirdPartyLicenses"
mkdir -p "$THIRD_PARTY_LICENSES_DIR"
cat >"$APP_RESOURCES/THIRD_PARTY_NOTICES.md" <<'EOF'
# Third-Party Notices

Agent Signal Bar bundles or links the following third-party components:

- Sparkle, licensed under the MIT License. See `ThirdPartyLicenses/Sparkle-LICENSE`.
- SweetCookieKit, licensed under the MIT License. See `ThirdPartyLicenses/SweetCookieKit-LICENSE`.

These notices are provided for attribution and license compliance.
EOF
SPARKLE_LICENSE="$(find "$ROOT_DIR/.build/checkouts/Sparkle" -maxdepth 2 -name LICENSE -type f -print 2>/dev/null | head -n 1 || true)"
SWEETCOOKIEKIT_LICENSE="$(find "$ROOT_DIR/.build/checkouts/SweetCookieKit" -maxdepth 2 -name LICENSE -type f -print 2>/dev/null | head -n 1 || true)"
if [[ -n "$SPARKLE_LICENSE" ]]; then
  cp "$SPARKLE_LICENSE" "$THIRD_PARTY_LICENSES_DIR/Sparkle-LICENSE"
else
  echo "warning: Sparkle LICENSE not found in .build/checkouts" >&2
fi
if [[ -n "$SWEETCOOKIEKIT_LICENSE" ]]; then
  cp "$SWEETCOOKIEKIT_LICENSE" "$THIRD_PARTY_LICENSES_DIR/SweetCookieKit-LICENSE"
else
  echo "warning: SweetCookieKit LICENSE not found in .build/checkouts" >&2
fi
cp "$VERSION_FILE" "$VERSION_RESOURCE"
chmod +x "$APP_BINARY"
chmod +x "$APP_RESOURCES/dist/bin/agent-signal-light" \
  "$APP_RESOURCES/dist/bin/agent-signal" \
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
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_RESOURCES/dist/bin/agent-signal-light" >/dev/null
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGED_APP_BUNDLE" >/dev/null
else
  codesign --force --deep --sign - "$APP_FRAMEWORKS/Sparkle.framework" >/dev/null
  codesign --force --sign - "$STAGED_APP_BUNDLE" >/dev/null
fi
clear_extended_attributes "$STAGED_APP_BUNDLE"

mkdir -p "$DIST_DIR"
ditto --norsrc --noextattr "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
rm -rf "$STAGING_DIR"
trap - EXIT
clear_extended_attributes "$APP_BUNDLE"
sleep 2
clear_extended_attributes "$APP_BUNDLE"
chmod -R u+w "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/xattr -cr "$APP_BUNDLE" 2>/dev/null || true
clear_signature_detritus "$APP_BUNDLE"
if [[ "${AGENT_SIGNAL_LIGHT_STRICT_PACKAGE_VERIFY:-0}" == "1" ]]; then
  for pass in 1 2 3 4 5; do
    if codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
      break
    fi

    if [[ "$pass" -eq 5 ]]; then
      codesign --verify --deep --strict "$APP_BUNDLE"
    fi

    sleep 1
    clear_signature_detritus "$APP_BUNDLE"
  done
fi

echo "$APP_BUNDLE"
