#!/usr/bin/env bash
set -u

MODE="quick"
STRICT_WARNINGS=0
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentSignalLight"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
STATE_DIR="${AGENT_SIGNAL_LIGHT_STATE_DIR:-/tmp/agent-signal}"
STATE_FILE="${AGENT_SIGNAL_LIGHT_STATE_FILE:-$STATE_DIR/status.json}"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CLI_BIN="$ROOT_DIR/dist/bin/agent-signal"
DMG="$ROOT_DIR/dist/$APP_NAME-local.dmg"
RELEASE_MANIFEST="$ROOT_DIR/dist/$APP_NAME-release-manifest.json"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
CODEX_HOOKS_FILE="$HOME/.codex/hooks.json"
CODEX_PROJECT_HOOKS_FILE="$ROOT_DIR/.codex/hooks.json"
CLAUDE_SETTINGS_FILE="$HOME/.claude/settings.json"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

FAILED=0
WARNED=0
DOCTOR_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-signal-doctor.XXXXXX")"
DOCTOR_OUT="$DOCTOR_TMP_DIR/out"
DOCTOR_ERR="$DOCTOR_TMP_DIR/err"
trap 'rm -rf "$DOCTOR_TMP_DIR"' EXIT

pass() {
  printf "[ok] %s\n" "$1"
}

warn() {
  WARNED=1
  printf "[warn] %s\n" "$1"
}

fail() {
  FAILED=1
  printf "[fail] %s\n" "$1"
}

run_check() {
  local label="$1"
  shift
  if "$@" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    pass "$label"
  else
    fail "$label"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi
}

swift_tool() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    swift "$@"
  elif [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" swift "$@"
  else
    swift "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    quick)
      MODE="quick"
      shift
      ;;
    --full|full)
      MODE="full"
      shift
      ;;
    --strict)
      STRICT_WARNINGS=1
      shift
      ;;
    --help|-h)
      echo "usage: $0 [quick|--full] [--strict]"
      exit 0
      ;;
    *)
      echo "usage: $0 [quick|--full] [--strict]" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR" || exit 1

echo "Agent Signal Bar doctor"
echo "root: $ROOT_DIR"

[[ -f "$ROOT_DIR/Package.swift" ]] && pass "Package.swift found" || fail "Package.swift missing"

if [[ "$MODE" == "full" ]]; then
  run_check "core checks pass" swift_tool run agent-signal-checks
  run_check "app builds" swift_tool build --product "$APP_NAME"
  run_check "test suite passes" swift_tool test
  run_check "status bar lamp language renders consistently" swift_tool test --filter statusBarRendererMatchesLampLanguageAcrossStylesAndLayouts
  run_check "macOS status bar breathing is visibly rendered" swift_tool test --filter macOSStatusBarBreathingChangesRenderedActiveArea
  run_check "macOS horizontal status bar can use traffic-light sizing" swift_tool test --filter macOSHorizontalStatusBarCanUseTrafficLightSizingWithoutTrafficLightHousing
  run_check "traffic-light vertical status bar uses compact large sizing" swift_tool test --filter trafficLightVerticalStatusBarCanUseCompactLargeSizingWithTrafficLightHousing
  if swift_tool run agent-signal-icon-preview "$ROOT_DIR/dist/status-icon-preview" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    if /usr/bin/python3 - "$ROOT_DIR/dist/status-icon-preview" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
sheet = root / "status-icon-preview.png"
manifest = root / "manifest.json"
icons = root / "icons"
assert sheet.exists() and sheet.stat().st_size > 10_000
assert manifest.exists()
data = json.loads(manifest.read_text())
records = data["records"]
assert len(records) == 48
assert any(item["style"] == "macOS" and item["layout"] == "vertical" and item["state"] == "working-high" for item in records)
assert any(item["style"] == "trafficLight" and item["layout"] == "horizontal" and item["state"] == "all-lights-on" for item in records)
for item in records:
    path = icons / Path(item["path"]).name
    assert path.exists() and path.stat().st_size > 0
PY
    then
      pass "status bar preview artifacts generate"
    else
      fail "status bar preview artifact schema check failed"
    fi
  else
    fail "status bar preview artifact generation failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  TMP_DIAGNOSTICS_DIR="$(mktemp -d)"
  if "$ROOT_DIR/script/export_diagnostics.sh" --output "$TMP_DIAGNOSTICS_DIR" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    if /usr/bin/python3 - "$DOCTOR_OUT" <<'PY'
import sys
import zipfile
from pathlib import Path

output = Path(sys.argv[1]).read_text()
archive = None
for line in output.splitlines():
    prefix = "Diagnostics archive: "
    if line.startswith(prefix):
        archive = Path(line[len(prefix):].strip())
        break
if archive is None:
    raise SystemExit("missing Diagnostics archive line")
if not archive.exists() or archive.stat().st_size <= 1000:
    raise SystemExit("diagnostics archive missing or too small")
with zipfile.ZipFile(archive) as package:
    names = package.namelist()
    required_suffixes = [
        "manifest.json",
        "commands/agent-signal-status.txt",
        "commands/agent-signal-status-json.txt",
        "commands/install-hooks-dry-run.txt",
    ]
    for suffix in required_suffixes:
        if not any(name.endswith(suffix) for name in names):
            raise SystemExit(f"missing {suffix}")
PY
    then
      pass "diagnostics archive exports"
    else
      fail "diagnostics archive schema check failed"
    fi
  else
    fail "diagnostics archive export failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  if "$ROOT_DIR/script/notarize_release.sh" --readiness >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    if grep -q "Agent Signal Bar notarization readiness" "$DOCTOR_OUT"; then
      pass "notarization readiness report generates"
    else
      fail "notarization readiness report missing header"
    fi
  else
    fail "notarization readiness report failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi
fi

if [[ -x "$CLI_BIN" ]]; then
  pass "release CLI installed at $CLI_BIN"
else
  fail "release CLI missing; run ./script/install_cli.sh"
fi

if [[ -x "$ROOT_DIR/scripts/agent-signal" ]]; then
  pass "agent-signal wrapper executable"
else
  fail "scripts/agent-signal is not executable"
fi

if [[ -x "$ROOT_DIR/scripts/agent-signal-run" ]]; then
  pass "agent-signal-run wrapper executable"
else
  fail "scripts/agent-signal-run is not executable"
fi

if [[ -x "$ROOT_DIR/scripts/codex-signal-hook" \
  && -x "$ROOT_DIR/scripts/claude-code-signal-hook" \
  && -x "$ROOT_DIR/scripts/generic-agent-signal-hook" ]]; then
  pass "Codex, Claude, and generic hook wrappers executable"
else
  fail "hook wrappers are not executable"
fi

if [[ -x "$ROOT_DIR/script/export_diagnostics.sh" ]]; then
  pass "diagnostics export script executable"
else
  fail "script/export_diagnostics.sh is not executable"
fi

if [[ -x "$ROOT_DIR/script/install_app.sh" ]]; then
  pass "app install script executable"
else
  fail "script/install_app.sh is not executable"
fi

if [[ -x "$ROOT_DIR/script/package_dmg.sh" ]]; then
  pass "DMG packaging script executable"
else
  fail "script/package_dmg.sh is not executable"
fi

if [[ -x "$ROOT_DIR/script/notarize_release.sh" ]]; then
  pass "notarization script executable"
else
  fail "script/notarize_release.sh is not executable"
fi

if [[ -x "$ROOT_DIR/script/verify_release_install.sh" ]]; then
  pass "release install verifier executable"
else
  fail "script/verify_release_install.sh is not executable"
fi

if [[ -x "$ROOT_DIR/script/verify_release_zip.sh" ]]; then
  pass "release zip verifier executable"
else
  fail "script/verify_release_zip.sh is not executable"
fi

if [[ -x "$ROOT_DIR/script/verify_release_all.sh" ]]; then
  pass "release all verifier executable"
else
  fail "script/verify_release_all.sh is not executable"
fi

if [[ -x "$ROOT_DIR/script/verify_local_integrations.sh" ]]; then
  pass "local integration verifier executable"
else
  fail "script/verify_local_integrations.sh is not executable"
fi

if [[ -x "$ROOT_DIR/script/verify_uninstall.sh" ]]; then
  pass "uninstall verifier executable"
else
  fail "script/verify_uninstall.sh is not executable"
fi

TMP_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STATE" "$ROOT_DIR/scripts/agent-signal" permission --session doctor --agent doctor --event PermissionRequest >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$TMP_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["schema_version"] == 1
assert data["aggregate"] == "permission"
assert data["sessions"]["doctor"]["signal"] == "permission"
assert data["events"][-1]["event"] == "PermissionRequest"
PY
  then
    pass "CLI writes valid status JSON"
  else
    fail "status JSON schema check failed"
  fi
else
  fail "agent-signal CLI failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_JSON_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_JSON_STATE" "$ROOT_DIR/scripts/agent-signal" working --session doctor-json --agent doctor --event JSONStatus --json >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$DOCTOR_OUT" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["schema_version"] == 1
assert data["aggregate"] == "working"
assert data["display_state"] == "active"
assert data["lamp_state"] == "active"
assert data["priority"] == 50
assert data["summary"]
assert data["action"]
assert data["state_file"].endswith("status.json")
assert data["sessions"][0]["session_id"] == "doctor-json"
assert data["sessions"][0]["signal"] == "working"
assert data["recent_events"][0]["event"] == "JSONStatus"
PY
  then
    pass "CLI status JSON output is valid"
  else
    fail "CLI status JSON output schema check failed"
  fi
else
  fail "agent-signal --json output failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_PRIORITY_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_PRIORITY_STATE" "$ROOT_DIR/scripts/agent-signal" permission --session doctor-permission --agent doctor --event PermissionRequest >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
  && AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_PRIORITY_STATE" "$ROOT_DIR/scripts/agent-signal" working --json >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$DOCTOR_OUT" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
sessions = {item["session_id"]: item for item in data["sessions"]}
assert data["aggregate"] == "permission"
assert data["display_state"] == "permission"
assert sessions["doctor-permission"]["signal"] == "permission"
assert sessions["manual"]["signal"] == "working"
assert sessions["manual"]["agent"] == "manual"
assert sessions["manual"]["last_event"] == "ManualSet"
assert data["recent_events"][0]["session_id"] == "manual"
PY
  then
    pass "wrapper bare commands preserve red priority"
  else
    fail "wrapper bare command priority check failed"
  fi
else
  fail "wrapper bare command priority scenario failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_RESUME_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_RESUME_STATE" "$ROOT_DIR/scripts/agent-signal" off --session doctor-off --agent doctor --event Pause >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
  && AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_RESUME_STATE" "$ROOT_DIR/scripts/agent-signal" working --session doctor-resume --agent doctor --event Resume --json >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$DOCTOR_OUT" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
sessions = {item["session_id"]: item for item in data["sessions"]}
assert data["aggregate"] == "working"
assert data["display_state"] == "active"
assert list(sessions) == ["doctor-resume"]
assert sessions["doctor-resume"]["signal"] == "working"
PY
  then
    pass "non-paused events resume from off"
  else
    fail "resume from off check failed"
  fi
else
  fail "resume from off scenario failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_SIGNAL_STATE="$(mktemp -d)/status.json"
SIGNAL_SMOKE_FAILED=0
for signal in idle thinking working tool_done subagent_start subagent_stop attention notification done permission permission_request blocked failure error exception max_tokens stale session_start session_end turn_end off pause paused; do
  if ! AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_SIGNAL_STATE" "$ROOT_DIR/scripts/agent-signal" "$signal" --session "doctor-$signal" --agent doctor --event "$signal" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    SIGNAL_SMOKE_FAILED=1
    break
  fi
  if ! /usr/bin/python3 - "$TMP_SIGNAL_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["schema_version"] == 1
assert isinstance(data.get("sessions"), dict)
assert isinstance(data.get("events"), list)
PY
  then
    SIGNAL_SMOKE_FAILED=1
    break
  fi
done

if [[ "$SIGNAL_SMOKE_FAILED" -eq 0 ]]; then
  pass "all signal commands write schema-compatible JSON"
else
  fail "signal command schema smoke test failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_COMPLETED_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_COMPLETED_STATE" AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS=0.01 "$ROOT_DIR/scripts/agent-signal" done --session doctor-done --agent doctor --event Done >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
  && sleep 0.03 \
  && AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_COMPLETED_STATE" AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS=0.01 "$ROOT_DIR/scripts/agent-signal" status --json >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$DOCTOR_OUT" "$TMP_COMPLETED_STATE" <<'PY'
import json
import sys
from pathlib import Path

output = json.loads(Path(sys.argv[1]).read_text())
state = json.loads(Path(sys.argv[2]).read_text())
assert output["aggregate"] == "idle"
assert output["display_state"] == "ready"
assert output["sessions"] == []
assert state["aggregate"] == "idle"
assert state["sessions"] == {}
PY
  then
    pass "completed sessions return to idle"
  else
    fail "completed TTL check failed"
  fi
else
  fail "completed TTL scenario failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

if AGENT_SIGNAL_LIGHT_STATE_FILE="$(mktemp -d)/status.json" "$ROOT_DIR/scripts/agent-signal" definitely_unknown_signal >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  fail "unknown signal command should be rejected"
else
  pass "unknown signal command is rejected"
fi

TMP_BAD_ARGS_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_BAD_ARGS_STATE" "$ROOT_DIR/scripts/agent-signal" working --session >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  fail "missing option values should be rejected"
else
  pass "missing option values are rejected"
fi

TMP_UNKNOWN_OPTION_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_UNKNOWN_OPTION_STATE" "$ROOT_DIR/scripts/agent-signal" working --sesion typo >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  fail "unknown CLI options should be rejected"
else
  pass "unknown CLI options are rejected"
fi

TMP_CODEX_STATE="$(mktemp -d)/status.json"
if printf '{"event":"PermissionRequest","session_id":"doctor-codex"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_CODEX_STATE" "$ROOT_DIR/scripts/codex-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  pass "Codex hook wrapper writes state"
else
  fail "Codex hook wrapper failed"
fi

TMP_CLAUDE_STATE="$(mktemp -d)/status.json"
if printf '{"event":"Notification","session_id":"doctor-claude"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_CLAUDE_STATE" "$ROOT_DIR/scripts/claude-code-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  pass "Claude hook wrapper writes state"
else
  fail "Claude hook wrapper failed"
fi

TMP_NORMALIZED_EVENT_STATE="$(mktemp -d)/status.json"
if printf '{"event":"post_tool_use_failure","sessionId":"doctor-normalized-claude"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_NORMALIZED_EVENT_STATE" "$ROOT_DIR/scripts/claude-code-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
  && printf '{"sessionId":"doctor-normalized-codex"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_NORMALIZED_EVENT_STATE" "$ROOT_DIR/scripts/codex-signal-hook" " pre_tool_use " >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$TMP_NORMALIZED_EVENT_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["aggregate"] == "blocked"
assert data["sessions"]["doctor-normalized-claude"]["signal"] == "blocked"
assert data["sessions"]["doctor-normalized-codex"]["signal"] == "working"
PY
  then
    pass "normalized hook event names map correctly"
  else
    fail "normalized hook event schema check failed"
  fi
else
  fail "normalized hook event scenario failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_STOP_STATE="$(mktemp -d)/status.json"
if printf '{"event":"Stop","session_id":"doctor-codex-stop"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STOP_STATE" "$ROOT_DIR/scripts/codex-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
  && printf '{"event":"Stop","session_id":"doctor-claude-stop"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STOP_STATE" "$ROOT_DIR/scripts/claude-code-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$TMP_STOP_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["aggregate"] == "done"
assert data["sessions"]["doctor-codex-stop"]["signal"] == "done"
assert data["sessions"]["doctor-claude-stop"]["signal"] == "done"
PY
  then
    pass "Stop hooks map to completed"
  else
    fail "Stop hook completed schema check failed"
  fi
else
  fail "Stop hook completed scenario failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_STOP_SESSION_END_STATE="$(mktemp -d)/status.json"
if printf '{"event":"Stop","session_id":"doctor-stop-end"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STOP_SESSION_END_STATE" "$ROOT_DIR/scripts/codex-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
  && printf '{"event":"SessionEnd","session_id":"doctor-stop-end"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STOP_SESSION_END_STATE" "$ROOT_DIR/scripts/codex-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$TMP_STOP_SESSION_END_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["aggregate"] == "done"
assert data["sessions"]["doctor-stop-end"]["signal"] == "done"
assert data["events"][-1]["signal"] == "session_end"
PY
  then
    pass "SessionEnd preserves completed hint"
  else
    fail "SessionEnd completed preservation schema check failed"
  fi
else
  fail "SessionEnd completed preservation scenario failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_STOP_PRESERVE_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STOP_PRESERVE_STATE" "$ROOT_DIR/scripts/agent-signal" permission --session doctor-stop-preserve --agent doctor --event PermissionRequest >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
  && printf '{"event":"Stop","session_id":"doctor-stop-preserve"}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STOP_PRESERVE_STATE" "$ROOT_DIR/scripts/codex-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$TMP_STOP_PRESERVE_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["aggregate"] == "permission"
assert data["sessions"]["doctor-stop-preserve"]["signal"] == "permission"
assert data["events"][-1]["signal"] == "done"
PY
  then
    pass "Stop completed event preserves red priority"
  else
    fail "Stop preserve priority schema check failed"
  fi
else
  fail "Stop preserve priority scenario failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_CLAUDE_FAILURE_STATE="$(mktemp -d)/status.json"
if printf '{"event":"PostToolUse","sessionId":"doctor-claude-fail","exitStatus":1}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_CLAUDE_FAILURE_STATE" "$ROOT_DIR/scripts/claude-code-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$TMP_CLAUDE_FAILURE_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["aggregate"] == "blocked"
assert data["sessions"]["doctor-claude-fail"]["signal"] == "blocked"
PY
  then
    pass "Claude failure payload maps to blocked"
  else
    fail "Claude failure payload schema check failed"
  fi
else
  fail "Claude failure payload hook failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_CLAUDE_STOP_REASON_STATE="$(mktemp -d)/status.json"
if printf '{"event":" stop ","sessionId":"doctor-claude-max-tokens","stopReason":" max-tokens "}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_CLAUDE_STOP_REASON_STATE" "$ROOT_DIR/scripts/claude-code-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
  && printf '{"event":"Stop","sessionId":"doctor-claude-stop-error","stopReason":" tool error "}' \
  | AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_CLAUDE_STOP_REASON_STATE" "$ROOT_DIR/scripts/claude-code-signal-hook" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$TMP_CLAUDE_STOP_REASON_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["aggregate"] == "blocked"
assert data["sessions"]["doctor-claude-max-tokens"]["signal"] == "max_tokens"
assert data["sessions"]["doctor-claude-stop-error"]["signal"] == "error"
PY
  then
    pass "Claude Stop reasons map to blocked"
  else
    fail "Claude Stop reason schema check failed"
  fi
else
  fail "Claude Stop reason scenario failed"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_RUNNER_STATE="$(mktemp -d)/status.json"
if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_RUNNER_STATE" "$ROOT_DIR/scripts/agent-signal-run" --session runner-ok --agent script -- /bin/sh -c "exit 0" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  if /usr/bin/python3 - "$TMP_RUNNER_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
sessions = data["sessions"]
assert data["aggregate"] == "done"
assert sessions["runner-ok"]["signal"] == "done"
assert sessions["runner-ok"]["last_event"] == "CommandFinished"
PY
  then
    pass "agent-signal-run marks successful commands done"
  else
    fail "agent-signal-run success state check failed"
  fi
else
  fail "agent-signal-run failed for successful command"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

TMP_RUNNER_FAIL_STATE="$(mktemp -d)/status.json"
AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_RUNNER_FAIL_STATE" "$ROOT_DIR/scripts/agent-signal-run" --session runner-fail --agent script -- /bin/sh -c "exit 7" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"
RUNNER_FAIL_STATUS=$?
if [[ "$RUNNER_FAIL_STATUS" -eq 7 ]]; then
  if /usr/bin/python3 - "$TMP_RUNNER_FAIL_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
sessions = data["sessions"]
assert data["aggregate"] == "blocked"
assert sessions["runner-fail"]["signal"] == "blocked"
assert sessions["runner-fail"]["last_event"] == "CommandFailed:7"
PY
  then
    pass "agent-signal-run preserves failure exit code and marks blocked"
  else
    fail "agent-signal-run failure state check failed"
  fi
else
  fail "agent-signal-run did not preserve failure exit code"
  sed -n '1,5p' "$DOCTOR_ERR"
fi

if "$ROOT_DIR/script/verify_local_integrations.sh" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
  pass "local script integrations verify"
else
  fail "local script integration verification failed"
  sed -n '1,8p' "$DOCTOR_ERR"
fi

check_codex_hooks_file() {
  local hooks_file="$1"
  /usr/bin/python3 - "$hooks_file" "$ROOT_DIR/scripts/codex-signal-hook" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
needle = sys.argv[2]
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"]
hooks = data.get("hooks", {})
missing = []
for event in events:
    blocks = hooks.get(event, [])
    text = json.dumps(blocks, ensure_ascii=False)
    if needle not in text:
        missing.append(event)
if missing:
    raise SystemExit("missing events: " + ", ".join(missing))
PY
}

codex_hooks_file_mentions_agent_signal() {
  local hooks_file="$1"
  /usr/bin/python3 - "$hooks_file" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
text = json.dumps(data.get("hooks", {}), ensure_ascii=False)
if "codex-signal-hook" not in text:
    raise SystemExit(1)
PY
}

if [[ -f "$CODEX_PROJECT_HOOKS_FILE" ]]; then
  if check_codex_hooks_file "$CODEX_PROJECT_HOOKS_FILE"; then
    pass "Codex project hooks configured for current checkout"
  else
    warn "Codex project hooks file exists but is missing current checkout wrapper/events; run ./script/install_hooks.py --target codex --codex-scope project --install"
  fi
else
  warn "Codex project hooks file not found at $CODEX_PROJECT_HOOKS_FILE; run ./script/install_hooks.py --target codex --codex-scope project --install"
fi

if [[ -f "$CODEX_HOOKS_FILE" ]]; then
  if check_codex_hooks_file "$CODEX_HOOKS_FILE" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    pass "Codex user hooks configured for current checkout"
  elif codex_hooks_file_mentions_agent_signal "$CODEX_HOOKS_FILE" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    warn "Codex user hooks contain stale/incomplete Agent Signal Bar entries; run ./script/install_hooks.py --target codex --codex-scope user --remove --install"
  else
    pass "Codex user hooks not configured; project hooks are primary"
  fi
fi

if [[ -f "$CLAUDE_SETTINGS_FILE" ]]; then
  if /usr/bin/python3 - "$CLAUDE_SETTINGS_FILE" "$ROOT_DIR/scripts/claude-code-signal-hook" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
needle = sys.argv[2]
events = [
    "ConfigChange", "CwdChanged", "Elicitation", "ElicitationResult",
    "FileChanged", "InstructionsLoaded", "SessionStart", "TaskCreated",
    "TaskCompleted", "TeammateIdle", "UserPromptExpansion", "UserPromptSubmit",
    "PreToolUse", "PostToolBatch", "PostToolUse", "PostToolUseFailure",
    "PreCompact", "PostCompact", "SubagentStart", "SubagentStop",
    "PermissionRequest", "PermissionDenied", "Notification", "Stop",
    "StopFailure", "WorktreeCreate", "WorktreeRemove", "SessionEnd",
]
hooks = data.get("hooks", {})
missing = []
for event in events:
    blocks = hooks.get(event, [])
    text = json.dumps(blocks, ensure_ascii=False)
    if needle not in text:
        missing.append(event)
if missing:
    raise SystemExit("missing events: " + ", ".join(missing))
PY
  then
    pass "Claude hooks configured for current checkout"
  else
    warn "Claude settings file exists but is missing current checkout wrapper/events; run ./script/install_hooks.py --target claude --install"
  fi
else
  warn "Claude settings file not found at $CLAUDE_SETTINGS_FILE; run ./script/install_hooks.py --target claude --install"
fi

if command -v claude >/dev/null 2>&1; then
  pass "Claude Code CLI found at $(command -v claude)"
else
  warn "Claude Code CLI not found in PATH; terminal Claude Code sessions cannot exercise the hook"
fi

CLAUDE_DESKTOP_LOG="$HOME/Library/Logs/Claude/main.log"
if [[ -f "$CLAUDE_DESKTOP_LOG" ]]; then
  if tail -c 512000 "$CLAUDE_DESKTOP_LOG" | grep -q "Claude Code requires a Pro or Max subscription"; then
    warn "Claude Desktop log says Claude Code requires a Pro or Max subscription; Claude Code hook events will not fire until that runtime can start"
  elif tail -c 512000 "$CLAUDE_DESKTOP_LOG" | grep -q "user:sessions:claude_code"; then
    pass "Claude Desktop log includes Claude Code session authorization attempts"
  else
    warn "Claude Desktop log has no recent Claude Code session authorization evidence; normal Claude chat does not emit Claude Code hook events"
  fi
else
  warn "Claude Desktop log not found at $CLAUDE_DESKTOP_LOG"
fi

if [[ -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
  pass "packaged app exists at $APP_BUNDLE"
  if [[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
    pass "packaged app includes AppIcon.icns"
  else
    fail "packaged app is missing AppIcon.icns; run ./script/package_app.sh --release"
  fi

  APP_RESOURCE_ROOT="$APP_BUNDLE/Contents/Resources"
  if [[ -x "$APP_RESOURCE_ROOT/dist/bin/agent-signal" \
    && -x "$APP_RESOURCE_ROOT/script/export_diagnostics.sh" \
    && -x "$APP_RESOURCE_ROOT/script/install_hooks.py" \
    && -x "$APP_RESOURCE_ROOT/scripts/agent-signal" \
    && -x "$APP_RESOURCE_ROOT/scripts/agent-signal-run" \
    && -x "$APP_RESOURCE_ROOT/scripts/codex-signal-hook" \
    && -x "$APP_RESOURCE_ROOT/scripts/claude-code-signal-hook" \
    && -x "$APP_RESOURCE_ROOT/scripts/generic-agent-signal-hook" \
    && -f "$APP_RESOURCE_ROOT/$APP_NAME-release-info.json" ]]; then
    pass "packaged app includes bundled CLI, hook, and diagnostics resources"
  else
    fail "packaged app is missing bundled CLI, hook, or diagnostics resources; run ./script/package_app.sh --release"
  fi

  TMP_BUNDLE_STATE="$(mktemp -d)/status.json"
  if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_BUNDLE_STATE" "$APP_RESOURCE_ROOT/scripts/agent-signal" working --session bundled-doctor --agent bundled --event BundledResource >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    pass "bundled agent-signal wrapper writes state"
  else
    fail "bundled agent-signal wrapper failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  TMP_BUNDLED_DIAGNOSTICS_DIR="$(mktemp -d)"
  if "$APP_RESOURCE_ROOT/script/export_diagnostics.sh" --output "$TMP_BUNDLED_DIAGNOSTICS_DIR" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    if /usr/bin/python3 - "$DOCTOR_OUT" <<'PY'
import sys
from pathlib import Path

archive = None
for line in Path(sys.argv[1]).read_text().splitlines():
    prefix = "Diagnostics archive: "
    if line.startswith(prefix):
        archive = Path(line[len(prefix):].strip())
        break
if archive is None or not archive.exists() or archive.stat().st_size <= 1000:
    raise SystemExit("bundled diagnostics archive missing")
PY
    then
      pass "bundled diagnostics exporter writes archive"
    else
      fail "bundled diagnostics archive check failed"
    fi
  else
    fail "bundled diagnostics exporter failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  TMP_BUNDLE_PRIORITY_STATE="$(mktemp -d)/status.json"
  if AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_BUNDLE_PRIORITY_STATE" "$APP_RESOURCE_ROOT/scripts/agent-signal" blocked --session bundled-red --agent bundled --event Failure >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" \
    && AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_BUNDLE_PRIORITY_STATE" "$APP_RESOURCE_ROOT/scripts/agent-signal" working --json >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    if /usr/bin/python3 - "$DOCTOR_OUT" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
sessions = {item["session_id"]: item for item in data["sessions"]}
assert data["aggregate"] == "blocked"
assert data["display_state"] == "blocked"
assert sessions["bundled-red"]["signal"] == "blocked"
assert sessions["manual"]["signal"] == "working"
PY
    then
      pass "bundled wrapper preserves red priority"
    else
      fail "bundled wrapper priority check failed"
    fi
  else
    fail "bundled wrapper priority scenario failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  TMP_BUNDLE_RUNNER_STATE="$(mktemp -d)/status.json"
  AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_BUNDLE_RUNNER_STATE" "$APP_RESOURCE_ROOT/scripts/agent-signal-run" --session bundled-runner-fail --agent bundled -- /bin/sh -c "exit 9" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"
  BUNDLE_RUNNER_STATUS=$?
  if [[ "$BUNDLE_RUNNER_STATUS" -eq 9 ]]; then
    if /usr/bin/python3 - "$TMP_BUNDLE_RUNNER_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
sessions = data["sessions"]
assert data["aggregate"] == "blocked"
assert sessions["bundled-runner-fail"]["signal"] == "blocked"
assert sessions["bundled-runner-fail"]["last_event"] == "CommandFailed:9"
PY
    then
      pass "bundled agent-signal-run preserves failure exit code"
    else
      fail "bundled agent-signal-run state check failed"
    fi
  else
    fail "bundled agent-signal-run did not preserve failure exit code"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  TMP_HOOK_HOME="$(mktemp -d)"
  if /usr/bin/python3 "$APP_RESOURCE_ROOT/script/install_hooks.py" --target all --home "$TMP_HOOK_HOME" --dry-run >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    if /usr/bin/python3 - "$DOCTOR_OUT" "$APP_RESOURCE_ROOT/scripts/codex-signal-hook" "$APP_RESOURCE_ROOT/scripts/claude-code-signal-hook" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
if sys.argv[2] not in text:
    raise SystemExit("missing bundled Codex wrapper path")
if sys.argv[3] not in text:
    raise SystemExit("missing bundled Claude wrapper path")
PY
    then
      pass "bundled hook installer targets app resources"
    else
      fail "bundled hook installer output does not target app resources"
    fi
  else
    fail "bundled hook installer dry-run failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  TMP_MIGRATION_HOME="$(mktemp -d)"
  mkdir -p "$TMP_MIGRATION_HOME/.codex" "$TMP_MIGRATION_HOME/.claude"
  cat >"$TMP_MIGRATION_HOME/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "'/old/path/scripts/codex-signal-hook' PreToolUse",
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
  cat >"$TMP_MIGRATION_HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "'/old/path/scripts/claude-code-signal-hook'",
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
  if /usr/bin/python3 "$APP_RESOURCE_ROOT/script/install_hooks.py" --target all --home "$TMP_MIGRATION_HOME" --install >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    if /usr/bin/python3 - "$TMP_MIGRATION_HOME" "$APP_RESOURCE_ROOT/scripts/codex-signal-hook" "$APP_RESOURCE_ROOT/scripts/claude-code-signal-hook" <<'PY'
import sys
from pathlib import Path

home = Path(sys.argv[1])
codex_wrapper = sys.argv[2]
claude_wrapper = sys.argv[3]
checks = [
    (home / ".codex/hooks.json", codex_wrapper, "old/path/scripts/codex-signal-hook", "echo keep-codex"),
    (home / ".claude/settings.json", claude_wrapper, "old/path/scripts/claude-code-signal-hook", "echo keep-claude"),
]
for path, wrapper, stale, keep in checks:
    text = path.read_text()
    if wrapper not in text:
        raise SystemExit(f"missing current wrapper in {path}")
    if stale in text:
        raise SystemExit(f"stale wrapper was not removed from {path}")
    if keep not in text:
        raise SystemExit(f"unrelated hook was not preserved in {path}")
    if not list(path.parent.glob(path.name + ".bak-*")):
        raise SystemExit(f"backup was not created for {path}")
PY
    then
      pass "bundled hook installer migrates stale wrapper paths"
    else
      fail "bundled hook installer migration check failed"
    fi
  else
    fail "bundled hook installer migration install failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  TMP_REMOVE_HOME="$(mktemp -d)"
  mkdir -p "$TMP_REMOVE_HOME/.codex" "$TMP_REMOVE_HOME/.claude"
  cat >"$TMP_REMOVE_HOME/.codex/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "'$APP_RESOURCE_ROOT/scripts/codex-signal-hook' PreToolUse",
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
  cat >"$TMP_REMOVE_HOME/.claude/settings.json" <<JSON
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "'$APP_RESOURCE_ROOT/scripts/claude-code-signal-hook'",
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
  if /usr/bin/python3 "$APP_RESOURCE_ROOT/script/install_hooks.py" --target all --home "$TMP_REMOVE_HOME" --remove --install >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    if /usr/bin/python3 - "$TMP_REMOVE_HOME" <<'PY'
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
    then
      pass "bundled hook installer removes Agent Signal Bar hooks"
    else
      fail "bundled hook installer removal check failed"
    fi
  else
    fail "bundled hook installer removal failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  VERIFY_APP="$(mktemp -d)/$APP_NAME.app"
  ditto --norsrc "$APP_BUNDLE" "$VERIFY_APP"
  if codesign --verify --deep --strict --verbose=2 "$VERIFY_APP" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    pass "packaged app code signature verifies on a clean copy"
  else
    fail "packaged app code signature does not verify; run ./script/package_app.sh --release"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  TMP_INSTALL_ROOT="$(mktemp -d)"
  if AGENT_SIGNAL_APP_INSTALL_DIR="$TMP_INSTALL_ROOT/Applications" "$ROOT_DIR/script/install_app.sh" --source-app "$APP_BUNDLE" --no-open >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    INSTALLED_TEST_APP="$TMP_INSTALL_ROOT/Applications/$APP_NAME.app"
    if [[ -x "$INSTALLED_TEST_APP/Contents/MacOS/$APP_NAME" ]] \
      && codesign --verify --deep --strict --verbose=2 "$INSTALLED_TEST_APP" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
      pass "install script installs existing app without rebuilding"
    else
      fail "install script copied app does not verify"
      sed -n '1,5p' "$DOCTOR_ERR"
    fi
  else
    fail "install script failed with existing app source"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi
  rm -rf "$TMP_INSTALL_ROOT"
else
  warn "packaged app missing; run ./script/package_app.sh --release"
fi

if [[ -f "$ROOT_DIR/dist/.packaged-release" ]]; then
  pass "running from packaged release payload"
elif [[ -f "$ROOT_DIR/dist/$APP_NAME-local.zip" && -f "$ROOT_DIR/dist/$APP_NAME-SHA256SUMS.txt" ]]; then
  if (cd "$ROOT_DIR" && shasum -a 256 -c "dist/$APP_NAME-SHA256SUMS.txt" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"); then
    pass "release artifact checksums verify"
  else
    fail "release artifact checksum failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi
else
  warn "release archive missing; run ./script/package_release.sh"
fi

if [[ "$MODE" == "full" ]]; then
  if "$ROOT_DIR/script/verify_uninstall.sh" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    pass "uninstall flow verifies"
  else
    fail "uninstall flow verification failed"
    sed -n '1,8p' "$DOCTOR_ERR"
  fi

  if [[ -f "$ROOT_DIR/dist/$APP_NAME-local.zip" ]]; then
    if "$ROOT_DIR/script/verify_release_zip.sh" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
      pass "release zip install verifies"
    else
      fail "release zip install verification failed"
      sed -n '1,8p' "$DOCTOR_ERR"
    fi
  else
    warn "release zip missing; run ./script/package_release.sh"
  fi
fi

if [[ -f "$RELEASE_MANIFEST" ]]; then
  if /usr/bin/python3 - "$ROOT_DIR" "$RELEASE_MANIFEST" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text())
assert manifest["schema_version"] == 1
assert manifest["app_name"] == "AgentSignalLight"
assert manifest["bundle_identifier"] == "com.agentsignallight.AgentSignalLight"
assert manifest["version"]
assert manifest["build"]
assert manifest["signing"]["mode"] in {"ad_hoc", "developer_id"}
assert isinstance(manifest["notarization"]["ready_to_submit"], bool)

artifacts = {item["role"]: item for item in manifest["artifacts"]}
for role in ("source_zip", "installer_dmg"):
    item = artifacts[role]
    path = root / item["path"]
    if not path.exists():
        raise SystemExit(f"missing artifact {path}")
    if path.stat().st_size != item["bytes"]:
        raise SystemExit(f"size mismatch for {path}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != item["sha256"]:
        raise SystemExit(f"sha256 mismatch for {path}")
PY
  then
    pass "release manifest matches artifacts"
  else
    fail "release manifest does not match artifacts"
  fi
else
  warn "release manifest missing; run ./script/package_release.sh"
fi

if [[ -f "$DMG" ]]; then
  if hdiutil verify "$DMG" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    pass "release DMG verifies"
  else
    fail "release DMG verification failed"
    sed -n '1,5p' "$DOCTOR_ERR"
  fi

  if [[ "$MODE" == "full" ]]; then
    DMG_MOUNT="$(mktemp -d)"
    if hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT" "$DMG" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
      if [[ -x "$DMG_MOUNT/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
        && -L "$DMG_MOUNT/Applications" \
        && -f "$DMG_MOUNT/Read Me.txt" \
        && -f "$DMG_MOUNT/$APP_NAME.app/Contents/Resources/$APP_NAME-release-info.json" ]]; then
        pass "release DMG contains app, Applications shortcut, text readme, and release info"
      else
        fail "release DMG is missing app, Applications shortcut, text readme, or release info"
      fi
      if [[ -f "$RELEASE_MANIFEST" && -f "$DMG_MOUNT/$APP_NAME.app/Contents/Resources/$APP_NAME-release-info.json" ]]; then
        if /usr/bin/python3 - "$RELEASE_MANIFEST" "$DMG_MOUNT/$APP_NAME.app/Contents/Resources/$APP_NAME-release-info.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
release_info = json.loads(Path(sys.argv[2]).read_text())
for key in ("schema_version", "app_name", "bundle_identifier", "version", "build"):
    if manifest[key] != release_info[key]:
        raise SystemExit(f"{key} mismatch")
if manifest["signing"]["mode"] != release_info["signing"]["mode"]:
    raise SystemExit("signing mode mismatch")
if manifest["notarization"]["ready_to_submit"] != release_info["notarization"]["ready_to_submit"]:
    raise SystemExit("notary readiness mismatch")
PY
        then
          pass "release DMG app release info matches manifest"
        else
          fail "release DMG app release info does not match manifest"
        fi
      fi
      hdiutil detach "$DMG_MOUNT" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR" || true
    else
      fail "release DMG could not be mounted"
      sed -n '1,5p' "$DOCTOR_ERR"
    fi
    rmdir "$DMG_MOUNT" >/dev/null 2>&1 || true

    if "$ROOT_DIR/script/verify_release_install.sh" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
      pass "release DMG install verifies"
    else
      fail "release DMG install verification failed"
      sed -n '1,8p' "$DOCTOR_ERR"
    fi

    TMP_DMG_INSTALL_ROOT="$(mktemp -d)"
    if AGENT_SIGNAL_APP_INSTALL_DIR="$TMP_DMG_INSTALL_ROOT/Applications" "$ROOT_DIR/script/install_app.sh" --dmg "$DMG" --no-open >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
      INSTALLED_DMG_APP="$TMP_DMG_INSTALL_ROOT/Applications/$APP_NAME.app"
      if [[ -x "$INSTALLED_DMG_APP/Contents/MacOS/$APP_NAME" ]] \
        && codesign --verify --deep --strict --verbose=2 "$INSTALLED_DMG_APP" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
        pass "install script installs from DMG"
      else
        fail "install script DMG install app does not verify"
        sed -n '1,5p' "$DOCTOR_ERR"
      fi
    else
      fail "install script failed with DMG source"
      sed -n '1,5p' "$DOCTOR_ERR"
    fi
    rm -rf "$TMP_DMG_INSTALL_ROOT"
  fi
else
  warn "release DMG missing; run ./script/package_release.sh"
fi

if [[ -f "$STATE_FILE" ]]; then
  pass "state file exists at $STATE_FILE"
else
  warn "state file not present yet at $STATE_FILE"
fi

if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
  if plutil -lint "$LAUNCH_AGENT_PLIST" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
    pass "launch-at-login plist is valid"
    if /usr/bin/python3 - "$LAUNCH_AGENT_PLIST" "$APP_NAME" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
app_name = sys.argv[2]
data = plistlib.loads(plist_path.read_bytes())
args = data.get("ProgramArguments")
if not isinstance(args, list) or len(args) < 2:
    raise SystemExit("ProgramArguments should contain /usr/bin/open app")
if args[0] != "/usr/bin/open":
    raise SystemExit("ProgramArguments should start with /usr/bin/open")
if len(args) > 1 and args[1] == "-n":
    raise SystemExit("ProgramArguments should not use /usr/bin/open -n because it opens duplicate app instances")
app_path = Path(args[1])
if app_path.name != f"{app_name}.app":
    raise SystemExit(f"ProgramArguments app should be {app_name}.app")
executable = app_path / "Contents" / "MacOS" / app_name
if not executable.exists():
    raise SystemExit(f"app executable not found: {executable}")
PY
    then
      pass "launch-at-login plist points to an installed app"
    else
      warn "launch-at-login plist does not point to a usable $APP_NAME.app"
    fi
    if launchctl print "gui/$(id -u)/$BUNDLE_ID" >"$DOCTOR_OUT" 2>"$DOCTOR_ERR"; then
      pass "launch-at-login job is loaded"
    else
      warn "launch-at-login plist exists but launchctl does not report a loaded job"
    fi
  else
    fail "launch-at-login plist is invalid"
  fi
else
  warn "launch-at-login is not enabled"
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pass "$APP_NAME process is running"
else
  warn "$APP_NAME is not running"
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "doctor: failed"
  exit 1
fi

if [[ "$WARNED" -ne 0 ]]; then
  if [[ "$STRICT_WARNINGS" -ne 0 ]]; then
    echo "doctor: failed due to warnings"
    exit 1
  fi
  echo "doctor: passed with warnings"
else
  echo "doctor: ok"
fi
