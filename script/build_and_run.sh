#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgentSignalLight"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
APP_BINARY_PID=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

usage() {
  cat <<EOF
usage: $0 [run|--debug|--logs|--telemetry|--verify|--status-item-verify|--ui-verify]

Builds Agent Signal Bar, launches the app bundle, and optionally verifies UI/runtime health.
EOF
}

if [[ "$MODE" == "--help" || "$MODE" == "-h" || "$MODE" == "help" ]]; then
  usage
  exit 0
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

APP_BUNDLE="$("$ROOT_DIR/script/package_app.sh")"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  /usr/bin/open "$APP_BUNDLE" --args "$@"
}

run_app_binary() {
  "$APP_BINARY" "$@" >/tmp/agent-signal-light-ui-verify.log 2>&1 &
  APP_BINARY_PID=$!
  disown "$APP_BINARY_PID" >/dev/null 2>&1 || true
}

verify_debug_window() {
  swift_tool() {
    if [[ -n "${DEVELOPER_DIR:-}" ]]; then
      swift "$@"
    elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
      DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift "$@"
    else
      swift "$@"
    fi
  }

  swift_tool - <<'SWIFT'
import CoreGraphics
import Darwin

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let hasDebugWindow = windows.contains { window in
    let owner = window[kCGWindowOwnerName as String] as? String
    let name = window[kCGWindowName as String] as? String
    let isAgentSignalBar = owner == "AgentSignalLight" || owner == "Agent Signal Bar"
    return isAgentSignalBar && name == "Agent Signal Bar"
}

exit(hasDebugWindow ? 0 : 1)
SWIFT
}

verify_status_item_health() {
  local health_file="$1"
  /usr/bin/python3 - "$health_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit("status item health file missing")

data = json.loads(path.read_text())
checks = {
    "status_bar_icon_enabled": True,
    "status_item_exists": True,
    "button_exists": True,
    "image_exists": True,
    "tooltip_exists": True,
}
for key, expected in checks.items():
    if data.get(key) is not expected:
        raise SystemExit(f"{key} was {data.get(key)!r}, expected {expected!r}")

status_menu_mode = data.get("status_menu_mode", "detailed")
if status_menu_mode == "simple":
    if data.get("menu_exists") is not True:
        raise SystemExit(f"menu_exists was {data.get('menu_exists')!r}, expected True for simple mode")
else:
    if data.get("action_exists") is not True:
        raise SystemExit(f"action_exists was {data.get('action_exists')!r}, expected True for detailed mode")

if data.get("length", 0) <= 0:
    raise SystemExit("status item length should be positive")
if data.get("aggregate") in (None, ""):
    raise SystemExit("aggregate missing")
PY
}

restore_normal_menu_bar_launch() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  open_app
  sleep 1
  pgrep -x "$APP_NAME" >/dev/null
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --status-item-verify|status-item-verify)
    HEALTH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-signal-status-item-health.XXXXXX")"
    HEALTH_FILE="$HEALTH_DIR/status-item-health.json"
    trap 'rm -rf "$HEALTH_DIR"' EXIT
    run_app_binary --force-status-bar-icon --status-item-health "$HEALTH_FILE"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if pgrep -x "$APP_NAME" >/dev/null && verify_status_item_health "$HEALTH_FILE" >/dev/null 2>&1; then
        restore_normal_menu_bar_launch
        exit 0
      fi
      sleep 0.5
    done
    pgrep -x "$APP_NAME" >/dev/null
    verify_status_item_health "$HEALTH_FILE"
    restore_normal_menu_bar_launch
    ;;
  --ui-verify|ui-verify)
    run_app_binary --debug-window
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if pgrep -x "$APP_NAME" >/dev/null && verify_debug_window; then
        exit 0
      fi
      sleep 0.5
    done
    pgrep -x "$APP_NAME" >/dev/null
    verify_debug_window
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
