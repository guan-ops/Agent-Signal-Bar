#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
KEEP_TEMP=0
TMP_ROOT=""

usage() {
  cat <<EOF
usage: $0 [--keep-temp]

Install Agent Signal Bar into a temporary HOME and Applications directory,
then verify uninstall_app.sh removes the app, launch-agent plist, Agent Signal
Light hooks, and a configured state directory while preserving unrelated hooks.
EOF
}

cleanup() {
  if [[ "$KEEP_TEMP" -eq 0 && -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  elif [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    echo "Kept temporary uninstall verification root: $TMP_ROOT"
  fi
}
trap cleanup EXIT

pass() {
  printf "[ok] %s\n" "$1"
}

die() {
  printf "[fail] %s\n" "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-temp)
      KEEP_TEMP=1
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

[[ -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]] || die "packaged app missing at $APP_BUNDLE"

TMP_ROOT="$(mktemp -d)"
TMP_HOME="$TMP_ROOT/home"
INSTALL_DIR="$TMP_ROOT/Applications"
STATE_DIR="$TMP_ROOT/agent-signal-state"
LAUNCH_AGENT_DIR="$TMP_HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$BUNDLE_ID.plist"
mkdir -p "$TMP_HOME/.codex" "$TMP_HOME/.claude" "$LAUNCH_AGENT_DIR" "$STATE_DIR"

HOME="$TMP_HOME" \
AGENT_SIGNAL_APP_INSTALL_DIR="$INSTALL_DIR" \
"$ROOT_DIR/script/install_app.sh" --source-app "$APP_BUNDLE" --no-open >"$TMP_ROOT/install.out"

INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
[[ -x "$INSTALLED_APP/Contents/MacOS/$APP_NAME" ]] || die "temporary install did not create app"
[[ -x "$INSTALLED_APP/Contents/Resources/script/install_hooks.py" ]] || die "installed hook remover missing"
pass "temporary app install exists for uninstall verification"

cat >"$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$INSTALLED_APP</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

CODEX_WRAPPER="$INSTALLED_APP/Contents/Resources/scripts/codex-signal-hook"
CLAUDE_WRAPPER="$INSTALLED_APP/Contents/Resources/scripts/claude-code-signal-hook"
cat >"$TMP_HOME/.codex/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "'$CODEX_WRAPPER' PreToolUse",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "echo keep-codex",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
JSON
cat >"$TMP_HOME/.claude/settings.json" <<JSON
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "'$CLAUDE_WRAPPER'",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "echo keep-claude",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
JSON
printf '{"aggregate":"working"}\n' >"$STATE_DIR/status.json"

HOME="$TMP_HOME" \
AGENT_SIGNAL_APP_INSTALL_DIR="$INSTALL_DIR" \
AGENT_SIGNAL_LIGHT_STATE_DIR="$STATE_DIR" \
"$ROOT_DIR/script/uninstall_app.sh" --remove-hooks --purge-state --no-kill --no-launchctl >"$TMP_ROOT/uninstall.out"

[[ ! -e "$INSTALLED_APP" ]] || die "uninstall did not remove app"
[[ ! -e "$LAUNCH_AGENT_PLIST" ]] || die "uninstall did not remove launch-agent plist"
[[ ! -e "$STATE_DIR" ]] || die "uninstall did not remove configured state directory"
pass "uninstall removes app, launch-agent plist, and configured state directory"

/usr/bin/python3 - "$TMP_HOME" <<'PY'
import sys
from pathlib import Path

home = Path(sys.argv[1])
checks = [
    (home / ".codex/hooks.json", "codex-signal-hook", "echo keep-codex"),
    (home / ".claude/settings.json", "claude-code-signal-hook", "echo keep-claude"),
]
for path, removed, keep in checks:
    text = path.read_text()
    if removed in text:
        raise SystemExit(f"Agent Signal Bar hook was not removed from {path}")
    if keep not in text:
        raise SystemExit(f"unrelated hook was not preserved in {path}")
    if not list(path.parent.glob(path.name + ".bak-*")):
        raise SystemExit(f"backup was not created for {path}")
PY
pass "uninstall removes Agent Signal Bar hooks and preserves unrelated hooks"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pass "uninstall verification did not terminate running app"
else
  pass "uninstall verification ran with no existing app process"
fi

echo "uninstall verifier: ok"
