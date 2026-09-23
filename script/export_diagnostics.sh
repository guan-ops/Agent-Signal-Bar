#!/usr/bin/env bash
set -u

MODE="quick"
OUTPUT_ROOT=""
APP_NAME="AgentSignalLight"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full|full)
      MODE="full"
      shift
      ;;
    --output)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "export_diagnostics: missing value for --output" >&2
        exit 2
      fi
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --help|-h)
      echo "usage: $0 [--full] [--output <directory>]"
      echo "AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME overrides user diagnostic paths."
      exit 0
      ;;
    *)
      echo "usage: $0 [--full] [--output <directory>]" >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "$OUTPUT_ROOT" ]]; then
  OUTPUT_ROOT="$ROOT_DIR/dist/diagnostics"
fi
mkdir -p "$OUTPUT_ROOT" || exit 1
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"

RUN_ID="agent-signal-diagnostics-$(date +%Y%m%d-%H%M%S)"
WORK_DIR="$OUTPUT_ROOT/$RUN_ID"
COMMANDS_DIR="$WORK_DIR/commands"
FILES_DIR="$WORK_DIR/files"
CONFIG_DIR="$WORK_DIR/config"
ARCHIVE="$OUTPUT_ROOT/$RUN_ID.zip"
DIAGNOSTIC_HOME="${AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME:-$HOME}"
DEFAULT_STATE_DIR="$DIAGNOSTIC_HOME/Library/Application Support/Agent Signal Bar/SignalState"
STATE_DIR="${AGENT_SIGNAL_LIGHT_STATE_DIR:-${SIGNAL_LIGHT_STATE_DIR:-$DEFAULT_STATE_DIR}}"
STATE_FILE="${AGENT_SIGNAL_LIGHT_STATE_FILE:-$STATE_DIR/status.json}"
LAUNCH_AGENT_PLIST="$DIAGNOSTIC_HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
if [[ -n "${AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME:-}" ]]; then
  export AGENT_SIGNAL_LIGHT_STATE_FILE="$STATE_FILE"
fi

mkdir -p "$COMMANDS_DIR" "$FILES_DIR" "$CONFIG_DIR"

run_capture() {
  local name="$1"
  shift
  local out="$COMMANDS_DIR/$name.txt"
  {
    printf "$"
    local arg
    for arg in "$@"; do
      printf " %q" "$arg"
    done
    printf "\n\n"
    "$@"
    local code=$?
    printf "\n[exit_code] %s\n" "$code"
  } >"$out" 2>&1
}

copy_if_exists() {
  local source="$1"
  local target="$2"
  if [[ -e "$source" ]]; then
    mkdir -p "$(dirname "$target")"
    cp -R "$source" "$target"
  fi
}

write_note() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf "%s\n" "$@" >"$path"
}

run_capture "sw_vers" /usr/bin/sw_vers
run_capture "uname" /usr/bin/uname -a
run_capture "xcode-select" /usr/bin/xcode-select -p
run_capture "swift-version" /usr/bin/env swift --version
run_capture "process" /usr/bin/pgrep -fl "$APP_NAME"

if [[ -x "$ROOT_DIR/scripts/agent-signal" ]]; then
  run_capture "agent-signal-status" "$ROOT_DIR/scripts/agent-signal" status
  run_capture "agent-signal-status-json" "$ROOT_DIR/scripts/agent-signal" status --json
else
  write_note "$COMMANDS_DIR/agent-signal-status.txt" "scripts/agent-signal is not available in $ROOT_DIR"
fi

if [[ -x "$ROOT_DIR/script/doctor.sh" ]]; then
  if [[ "$MODE" == "full" ]]; then
    run_capture "doctor" "$ROOT_DIR/script/doctor.sh" --full
  else
    run_capture "doctor" "$ROOT_DIR/script/doctor.sh"
  fi
else
  write_note "$COMMANDS_DIR/doctor.txt" "script/doctor.sh is not available in $ROOT_DIR"
fi

if [[ -x "$ROOT_DIR/script/install_hooks.py" ]]; then
  if [[ -n "${AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME:-}" ]]; then
    run_capture "install-hooks-dry-run" /usr/bin/python3 "$ROOT_DIR/script/install_hooks.py" --target all --home "$DIAGNOSTIC_HOME" --dry-run
  else
    run_capture "install-hooks-dry-run" /usr/bin/python3 "$ROOT_DIR/script/install_hooks.py" --target all --dry-run
  fi
else
  write_note "$COMMANDS_DIR/install-hooks-dry-run.txt" "script/install_hooks.py is not available in $ROOT_DIR"
fi

if [[ "$MODE" == "full" && -x "$ROOT_DIR/dist/bin/agent-signal-icon-preview" ]]; then
  run_capture "status-icon-preview" "$ROOT_DIR/dist/bin/agent-signal-icon-preview" "$WORK_DIR/status-icon-preview"
elif [[ -d "$ROOT_DIR/dist/status-icon-preview" ]]; then
  copy_if_exists "$ROOT_DIR/dist/status-icon-preview" "$WORK_DIR/status-icon-preview"
fi

copy_if_exists "$STATE_FILE" "$FILES_DIR/status.json"
copy_if_exists "$ROOT_DIR/dist/$APP_NAME.app/Contents/Info.plist" "$FILES_DIR/Info.plist"
copy_if_exists "$LAUNCH_AGENT_PLIST" "$CONFIG_DIR/launch-agent.plist"

/usr/bin/python3 - "$WORK_DIR" "$ARCHIVE" "$MODE" "$ROOT_DIR" "$STATE_FILE" <<'PY'
import json
import platform
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
archive = Path(sys.argv[2])
mode = sys.argv[3]
project_root = sys.argv[4]
state_file = sys.argv[5]

files = []
for path in sorted(root.rglob("*")):
    if path.is_file():
        files.append(str(path.relative_to(root)))

manifest = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "mode": mode,
    "project_root": project_root,
    "state_file": state_file,
    "archive": str(archive),
    "platform": platform.platform(),
    "files": files,
    "privacy_note": "This package includes status.json and local path metadata such as project_root, state_file, and archive. It avoids dumping the full environment and does not copy Codex or Claude hook config files; use install-hooks-dry-run.txt for hook diagnostics."
}
root.joinpath("manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
PY

rm -f "$ARCHIVE" || exit 1
if ! (
  cd "$OUTPUT_ROOT" || exit 1
  /usr/bin/ditto -c -k --norsrc --keepParent "$RUN_ID" "$ARCHIVE"
); then
  rm -f "$ARCHIVE"
  echo "export_diagnostics: failed to create diagnostics archive" >&2
  exit 1
fi

if [[ ! -f "$ARCHIVE" || ! -s "$ARCHIVE" ]] || ! /usr/bin/unzip -tq "$ARCHIVE" >/dev/null 2>&1; then
  rm -f "$ARCHIVE"
  echo "export_diagnostics: diagnostics archive is missing, empty, or invalid" >&2
  exit 1
fi

echo "Diagnostics folder: $WORK_DIR"
echo "Diagnostics archive: $ARCHIVE"
