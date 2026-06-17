#!/usr/bin/env bash
set -euo pipefail

RELEASE_BASENAME="AgentSignalBar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DMG="$DIST_DIR/$RELEASE_BASENAME.dmg"
APPCAST="$DIST_DIR/appcast.xml"
VERSION_FILE="$ROOT_DIR/VERSION"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.agentsignallight.AgentSignalLight}"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin}"
GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"

cd "$ROOT_DIR"

read_version_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print $2; exit }' "$VERSION_FILE"
}

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "missing version file: $VERSION_FILE" >&2
  exit 1
fi
if [[ ! -f "$DMG" ]]; then
  echo "missing update archive: $DMG" >&2
  exit 1
fi
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "missing Sparkle generate_appcast tool: $GENERATE_APPCAST" >&2
  echo "run: swift build --product AgentSignalLight" >&2
  exit 1
fi

APP_VERSION="$(read_version_value VERSION)"
TAG_NAME="${GITHUB_REF_NAME:-v$APP_VERSION}"
if [[ ! "$TAG_NAME" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  TAG_NAME="v$APP_VERSION"
fi

DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/guan-ops/Agent-Signal-Bar/releases/download/$TAG_NAME/}"
FULL_RELEASE_NOTES_URL="${SPARKLE_FULL_RELEASE_NOTES_URL:-https://github.com/guan-ops/Agent-Signal-Bar/releases/tag/$TAG_NAME}"
ARCHIVE_DIR="$(mktemp -d)"
trap 'rm -rf "$ARCHIVE_DIR"' EXIT

cp "$DMG" "$ARCHIVE_DIR/$RELEASE_BASENAME.dmg"
if [[ -f "$ROOT_DIR/docs/releases/$TAG_NAME.md" ]]; then
  cp "$ROOT_DIR/docs/releases/$TAG_NAME.md" "$ARCHIVE_DIR/$RELEASE_BASENAME.md"
elif [[ -f "$ROOT_DIR/docs/releases/v$APP_VERSION.md" ]]; then
  cp "$ROOT_DIR/docs/releases/v$APP_VERSION.md" "$ARCHIVE_DIR/$RELEASE_BASENAME.md"
fi

ARGS=(
  --account "$SPARKLE_ACCOUNT"
  --download-url-prefix "$DOWNLOAD_URL_PREFIX"
  --full-release-notes-url "$FULL_RELEASE_NOTES_URL"
  --embed-release-notes
  --maximum-deltas 0
  -o "$APPCAST"
  "$ARCHIVE_DIR"
)

rm -f "$APPCAST"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf "%s" "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - "${ARGS[@]}" >/dev/null
elif [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "SPARKLE_PRIVATE_KEY is required in CI to sign appcast updates." >&2
  echo "Export it from Sparkle generate_keys locally and store it as a GitHub Actions secret." >&2
  exit 1
else
  "$GENERATE_APPCAST" "${ARGS[@]}" >/dev/null
fi

if [[ ! -s "$APPCAST" ]]; then
  echo "appcast was not generated: $APPCAST" >&2
  exit 1
fi

echo "$APPCAST"
