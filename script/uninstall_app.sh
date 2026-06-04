#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${AGENT_SIGNAL_APP_INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
STATE_DIR="${AGENT_SIGNAL_LIGHT_STATE_DIR:-/tmp/agent-signal}"
HOOK_PROJECT_ROOT="${AGENT_SIGNAL_CODEX_PROJECT_ROOT:-$ROOT_DIR}"
PURGE_STATE=0
REMOVE_HOOKS=0
KILL_RUNNING_APP=1
RUN_LAUNCHCTL=1

usage() {
  cat <<EOF
usage: $0 [--remove-hooks] [--purge-state] [--no-kill] [--no-launchctl]

Uninstall Agent Signal Bar from the current user's Applications directory.

Options:
  --remove-hooks  Remove Agent Signal Bar hooks from Codex and Claude config.
  --purge-state   Remove the state directory. Defaults to $STATE_DIR.
  --no-kill       Do not terminate running AgentSignalLight processes.
  --no-launchctl  Remove the launch-agent plist without calling launchctl.
EOF
}

canonical_path() {
  /usr/bin/python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

validate_state_dir_for_purge() {
  local target
  local home
  target="$(canonical_path "$STATE_DIR")"
  home="$(canonical_path "$HOME")"

  case "$target" in
    ""|"/"|"/tmp"|"/var"|"/var/tmp"|"/Users"|"$home")
      echo "Refusing to purge unsafe state directory: $target" >&2
      exit 1
      ;;
  esac

  case "$target" in
    *agent-signal*|*AgentSignal*|*agent_signal*)
      ;;
    *)
      echo "Refusing to purge non-Agent-Signal-looking directory: $target" >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-hooks)
      REMOVE_HOOKS=1
      shift
      ;;
    --purge-state)
      PURGE_STATE=1
      shift
      ;;
    --no-kill)
      KILL_RUNNING_APP=0
      shift
      ;;
    --no-launchctl)
      RUN_LAUNCHCTL=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$REMOVE_HOOKS" -eq 1 ]]; then
  HOOK_INSTALLER=""
  if [[ -x "$INSTALLED_APP/Contents/Resources/script/install_hooks.py" ]]; then
    HOOK_INSTALLER="$INSTALLED_APP/Contents/Resources/script/install_hooks.py"
  elif [[ -x "$ROOT_DIR/script/install_hooks.py" ]]; then
    HOOK_INSTALLER="$ROOT_DIR/script/install_hooks.py"
  fi

  if [[ -n "$HOOK_INSTALLER" ]]; then
    /usr/bin/python3 "$HOOK_INSTALLER" \
      --target all \
      --codex-scope both \
      --project-root "$HOOK_PROJECT_ROOT" \
      --remove \
      --install

    if [[ "$PWD" != "$HOOK_PROJECT_ROOT" && -f "$PWD/.codex/hooks.json" ]]; then
      /usr/bin/python3 "$HOOK_INSTALLER" \
        --target codex \
        --codex-scope project \
        --project-root "$PWD" \
        --remove \
        --install
    fi
  else
    echo "No hook installer found; skipping hook removal." >&2
  fi
fi

if [[ "$RUN_LAUNCHCTL" -eq 1 ]]; then
  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1 || true
fi
rm -f "$LAUNCH_AGENT_PLIST"
if [[ "$KILL_RUNNING_APP" -eq 1 ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
rm -rf "$INSTALLED_APP"

if [[ "$PURGE_STATE" -eq 1 ]]; then
  validate_state_dir_for_purge
  rm -rf "$STATE_DIR"
fi

echo "Uninstalled app: $INSTALLED_APP"
if [[ "$REMOVE_HOOKS" -eq 1 ]]; then
  echo "Agent Signal Bar hooks: removal requested"
fi
if [[ "$PURGE_STATE" -eq 1 ]]; then
  echo "State directory removed: $STATE_DIR"
fi
