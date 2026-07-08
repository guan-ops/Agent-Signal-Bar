#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$ROOT_DIR/dist/bin"
INSTALL_NAME="agent-signal-light"
LEGACY_INSTALL_NAME="agent-signal"
INSTALL_PATH="$INSTALL_DIR/$INSTALL_NAME"
LEGACY_INSTALL_PATH="$INSTALL_DIR/$LEGACY_INSTALL_NAME"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
source "$ROOT_DIR/script/universal_build.sh"

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

if [[ -z "${AGENT_SIGNAL_LIGHT_ARCHS+x}" ]]; then
  INSTALL_ARCHS="arm64 x86_64"
else
  INSTALL_ARCHS="${AGENT_SIGNAL_LIGHT_ARCHS:-}"
fi
INSTALL_ARCHS="$(agent_signal_normalize_archs "$INSTALL_ARCHS")"

mkdir -p "$INSTALL_DIR"
agent_signal_build_product "$INSTALL_NAME" "$INSTALL_NAME" release "$INSTALL_PATH" "$INSTALL_ARCHS"
agent_signal_verify_binary_archs "$INSTALL_PATH" "$INSTALL_ARCHS" "$INSTALL_NAME"
ln -sf "$INSTALL_NAME" "$LEGACY_INSTALL_PATH"

echo "Installed $INSTALL_NAME: $INSTALL_PATH"
echo "Installed legacy alias $LEGACY_INSTALL_NAME: $LEGACY_INSTALL_PATH"
