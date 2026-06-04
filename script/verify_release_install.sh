#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
RELEASE_BASENAME="AgentSignalBar"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="$ROOT_DIR/dist/$RELEASE_BASENAME.dmg"
RELEASE_MANIFEST="$ROOT_DIR/dist/$RELEASE_BASENAME-release-manifest.json"
RUN_LAUNCH_CHECK=0
KEEP_TEMP=0
TMP_ROOT=""
MOUNT_DIR=""
INSTALL_ROOT=""
LAUNCHED_PID=""

usage() {
  cat <<EOF
usage: $0 [--dmg <path>] [--launch] [--keep-temp]

Mount the release DMG, copy $APP_NAME.app into a temporary Applications-like
directory, and verify the copied app bundle, code signature, bundled CLI,
release info, and diagnostics exporter.

Options:
  --dmg <path>   DMG to verify. Defaults to dist/$RELEASE_BASENAME.dmg.
  --launch       Also launch the temporary installed app and verify it starts.
  --keep-temp    Keep the temporary install directory for manual inspection.
EOF
}

cleanup() {
  if [[ -n "$LAUNCHED_PID" ]]; then
    kill "$LAUNCHED_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_TEMP" -eq 0 && -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  elif [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    echo "Kept temporary install root: $TMP_ROOT"
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
    --dmg)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        die "missing value for --dmg"
      fi
      DMG_PATH="$2"
      shift 2
      ;;
    --launch)
      RUN_LAUNCH_CHECK=1
      shift
      ;;
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

[[ -f "$DMG_PATH" ]] || die "DMG not found at $DMG_PATH"

TMP_ROOT="$(mktemp -d)"
MOUNT_DIR="$TMP_ROOT/mount"
INSTALL_ROOT="$TMP_ROOT/Applications"
mkdir -p "$MOUNT_DIR" "$INSTALL_ROOT"

hdiutil verify "$DMG_PATH" >/dev/null
pass "DMG verifies"

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
pass "DMG mounts read-only"

DMG_APP="$MOUNT_DIR/$APP_NAME.app"
[[ -x "$DMG_APP/Contents/MacOS/$APP_NAME" ]] || die "DMG is missing $APP_NAME.app executable"
[[ -L "$MOUNT_DIR/Applications" ]] || die "DMG is missing Applications shortcut"
[[ -f "$MOUNT_DIR/Read Me.txt" ]] || die "DMG is missing Read Me.txt"
pass "DMG layout contains app, Applications shortcut, and text readme"

INSTALLED_APP="$INSTALL_ROOT/$APP_NAME.app"
ditto --norsrc "$DMG_APP" "$INSTALLED_APP"
pass "app copies into temporary Applications directory"

APP_CONTENTS="$INSTALLED_APP/Contents"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
CLI_WRAPPER="$APP_RESOURCES/scripts/agent-signal"
RUN_WRAPPER="$APP_RESOURCES/scripts/agent-signal-run"
GENERIC_WRAPPER="$APP_RESOURCES/scripts/generic-agent-signal-hook"
CLI_BIN="$APP_RESOURCES/dist/bin/agent-signal"
DIAGNOSTICS_EXPORTER="$APP_RESOURCES/script/export_diagnostics.sh"
HOOK_INSTALLER="$APP_RESOURCES/script/install_hooks.py"
RELEASE_INFO="$APP_RESOURCES/$APP_NAME-release-info.json"

[[ -x "$APP_BINARY" ]] || die "installed app executable missing"
[[ -x "$CLI_WRAPPER" ]] || die "bundled agent-signal wrapper missing"
[[ -x "$RUN_WRAPPER" ]] || die "bundled agent-signal-run wrapper missing"
[[ -x "$GENERIC_WRAPPER" ]] || die "bundled generic agent hook wrapper missing"
[[ -x "$CLI_BIN" ]] || die "bundled agent-signal binary missing"
[[ -x "$DIAGNOSTICS_EXPORTER" ]] || die "bundled diagnostics exporter missing"
[[ -x "$HOOK_INSTALLER" ]] || die "bundled hook installer missing"
[[ -f "$APP_RESOURCES/AppIcon.icns" ]] || die "AppIcon.icns missing"
[[ -f "$RELEASE_INFO" ]] || die "release info JSON missing"
pass "installed app bundle resources are present"

/usr/bin/python3 - "$INSTALLED_APP" "$RELEASE_INFO" "$BUNDLE_ID" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
release_info_path = Path(sys.argv[2])
bundle_id = sys.argv[3]
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
release_info = json.loads(release_info_path.read_text())

if info.get("CFBundleIdentifier") != bundle_id:
    raise SystemExit("bundle identifier mismatch")
if info.get("CFBundleShortVersionString") != release_info.get("version"):
    raise SystemExit("release info version mismatch")
if info.get("CFBundleVersion") != release_info.get("build"):
    raise SystemExit("release info build mismatch")
if release_info.get("app_name") != "AgentSignalLight":
    raise SystemExit("release info app_name mismatch")
if release_info.get("bundle_identifier") != bundle_id:
    raise SystemExit("release info bundle identifier mismatch")
if release_info.get("signing", {}).get("mode") not in {"ad_hoc", "developer_id"}:
    raise SystemExit("unexpected signing mode")
PY
pass "installed app Info.plist and release info are coherent"

if [[ -f "$RELEASE_MANIFEST" ]]; then
  /usr/bin/python3 - "$RELEASE_MANIFEST" "$RELEASE_INFO" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
release_info = json.loads(Path(sys.argv[2]).read_text())
for key in ("schema_version", "app_name", "bundle_identifier", "version", "build"):
    if manifest.get(key) != release_info.get(key):
        raise SystemExit(f"{key} mismatch")
if manifest.get("signing", {}).get("mode") != release_info.get("signing", {}).get("mode"):
    raise SystemExit("signing mode mismatch")
if manifest.get("notarization", {}).get("ready_to_submit") != release_info.get("notarization", {}).get("ready_to_submit"):
    raise SystemExit("notary readiness mismatch")
PY
  pass "installed app release info matches release manifest"
fi

codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP" >/dev/null 2>&1
pass "installed app code signature verifies"

TMP_STATE="$TMP_ROOT/status/status.json"
mkdir -p "$(dirname "$TMP_STATE")"
AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STATE" "$CLI_WRAPPER" blocked --session install-red --agent release --event InstallVerifier >/dev/null
AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STATE" "$CLI_WRAPPER" working --session install-active --agent release --event InstallVerifier --json >"$TMP_ROOT/status.json"
/usr/bin/python3 - "$TMP_ROOT/status.json" "$TMP_STATE" <<'PY'
import json
import sys
from pathlib import Path

output = json.loads(Path(sys.argv[1]).read_text())
state = json.loads(Path(sys.argv[2]).read_text())
if output["aggregate"] != "blocked":
    raise SystemExit("red priority was not preserved")
sessions = {item["session_id"]: item for item in output["sessions"]}
if sessions["install-red"]["signal"] != "blocked":
    raise SystemExit("blocked session missing from JSON output")
if sessions["install-active"]["signal"] != "working":
    raise SystemExit("working session missing from JSON output")
if state["aggregate"] != "blocked":
    raise SystemExit("state file aggregate mismatch")
PY
pass "bundled CLI wrapper writes state and preserves red priority"

TMP_RUN_STATE="$TMP_ROOT/run-status/status.json"
set +e
AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_RUN_STATE" "$RUN_WRAPPER" --session install-run-fail --agent release -- /bin/sh -c "exit 8" >/dev/null
run_status=$?
set -e
[[ "$run_status" -eq 8 ]] || die "bundled agent-signal-run did not preserve wrapped exit code"
/usr/bin/python3 - "$TMP_RUN_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
sessions = data["sessions"]
if data["aggregate"] != "blocked":
    raise SystemExit("agent-signal-run did not mark aggregate blocked")
if sessions["install-run-fail"]["signal"] != "blocked":
    raise SystemExit("agent-signal-run did not mark failed session blocked")
if sessions["install-run-fail"]["last_event"] != "CommandFailed:8":
    raise SystemExit("agent-signal-run did not record wrapped exit code")
PY
pass "bundled agent-signal-run preserves exit code and marks blocked"

DIAGNOSTICS_DIR="$TMP_ROOT/diagnostics"
"$DIAGNOSTICS_EXPORTER" --output "$DIAGNOSTICS_DIR" >"$TMP_ROOT/diagnostics.out"
/usr/bin/python3 - "$TMP_ROOT/diagnostics.out" <<'PY'
import sys
import zipfile
from pathlib import Path

archive = None
for line in Path(sys.argv[1]).read_text().splitlines():
    prefix = "Diagnostics archive: "
    if line.startswith(prefix):
        archive = Path(line[len(prefix):].strip())
        break
if archive is None or not archive.exists() or archive.stat().st_size <= 1000:
    raise SystemExit("diagnostics archive missing")
with zipfile.ZipFile(archive) as package:
    names = package.namelist()
    if not any(name.endswith("manifest.json") for name in names):
        raise SystemExit("diagnostics manifest missing")
    if not any(name.endswith("commands/agent-signal-status-json.txt") for name in names):
        raise SystemExit("diagnostics CLI status missing")
PY
pass "bundled diagnostics exporter writes archive after install"

if [[ "$RUN_LAUNCH_CHECK" -eq 1 ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  open "$INSTALLED_APP"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    LAUNCHED_PID="$(pgrep -f "$APP_BINARY" | head -n 1 || true)"
    if [[ -n "$LAUNCHED_PID" ]]; then
      break
    fi
    sleep 0.5
  done
  [[ -n "$LAUNCHED_PID" ]] || die "temporary installed app did not launch"
  pass "temporary installed app launches"
fi

echo "release install verifier: ok"
