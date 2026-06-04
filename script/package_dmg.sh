#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
RELEASE_BASENAME="AgentSignalBar"
VOLUME_NAME="Agent Signal Bar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$RELEASE_BASENAME.dmg"
USE_EXISTING_APP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --use-existing-app)
      USE_EXISTING_APP=1
      shift
      ;;
    --output)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "package_dmg: missing value for --output" >&2
        exit 2
      fi
      DMG_PATH="$2"
      shift 2
      ;;
    --help|-h)
      echo "usage: $0 [--use-existing-app] [--output <path>]"
      exit 0
      ;;
    *)
      echo "usage: $0 [--use-existing-app] [--output <path>]" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ "$USE_EXISTING_APP" -ne 1 || ! -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
  APP_BUNDLE="$("$ROOT_DIR/script/package_app.sh" --release)"
fi

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

STAGING_DIR="$(mktemp -d)"
STAGING_ROOT="$STAGING_DIR/$VOLUME_NAME"
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$STAGING_ROOT"
ditto --norsrc "$APP_BUNDLE" "$STAGING_ROOT/$APP_NAME.app"
ln -s /Applications "$STAGING_ROOT/Applications"
cp "$ROOT_DIR/docs/DMG_README.txt" "$STAGING_ROOT/Read Me.txt"

find "$STAGING_ROOT" -exec xattr -c {} + 2>/dev/null || true
plutil -lint "$STAGING_ROOT/$APP_NAME.app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$STAGING_ROOT/$APP_NAME.app" >/dev/null 2>&1
mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

hdiutil verify "$DMG_PATH" >/dev/null 2>&1

echo "$DMG_PATH"
