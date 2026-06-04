#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
RELEASE_BASENAME="AgentSignalBar"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="$ROOT_DIR/dist/$RELEASE_BASENAME.zip"
RELEASE_MANIFEST="$ROOT_DIR/dist/$RELEASE_BASENAME-release-manifest.json"
RUN_LAUNCH_CHECK=0
KEEP_TEMP=0
TMP_ROOT=""
LAUNCHED_PID=""

usage() {
  cat <<EOF
usage: $0 [--zip <path>] [--launch] [--keep-temp]

Extract the release zip into a temporary directory, install the extracted app
with the packaged install script, and verify the installed app bundle, code
signature, bundled CLI, diagnostics exporter, and preview artifacts.

Options:
  --zip <path>   Zip to verify. Defaults to dist/$RELEASE_BASENAME.zip.
  --launch       Also launch the temporary installed app and verify it starts.
  --keep-temp    Keep the temporary extraction directory for manual inspection.
EOF
}

cleanup() {
  if [[ -n "$LAUNCHED_PID" ]]; then
    kill "$LAUNCHED_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_TEMP" -eq 0 && -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  elif [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    echo "Kept temporary zip verification root: $TMP_ROOT"
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
    --zip)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        die "missing value for --zip"
      fi
      ZIP_PATH="$2"
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

[[ -f "$ZIP_PATH" ]] || die "zip not found at $ZIP_PATH"

if [[ -f "$RELEASE_MANIFEST" ]]; then
  /usr/bin/python3 - "$ZIP_PATH" "$RELEASE_MANIFEST" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

zip_path = Path(sys.argv[1])
manifest = json.loads(Path(sys.argv[2]).read_text())
artifacts = {item["role"]: item for item in manifest.get("artifacts", [])}
item = artifacts.get("source_zip")
if not item:
    raise SystemExit("source_zip missing from manifest")
if zip_path.stat().st_size != item["bytes"]:
    raise SystemExit("zip size mismatch")
digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
if digest != item["sha256"]:
    raise SystemExit("zip sha256 mismatch")
PY
  pass "release zip matches release manifest"
fi

TMP_ROOT="$(mktemp -d)"
EXTRACT_DIR="$TMP_ROOT/extract"
INSTALL_ROOT="$TMP_ROOT/Applications"
mkdir -p "$EXTRACT_DIR" "$INSTALL_ROOT"

ditto -x -k --norsrc "$ZIP_PATH" "$EXTRACT_DIR"
PAYLOAD="$EXTRACT_DIR/$APP_NAME"
[[ -d "$PAYLOAD" ]] || die "zip did not extract $APP_NAME payload"
pass "release zip extracts"

[[ -f "$PAYLOAD/dist/.packaged-release" ]] || die "packaged release marker missing"
[[ -x "$PAYLOAD/script/install_app.sh" ]] || die "packaged install_app.sh missing"
[[ -x "$PAYLOAD/script/doctor.sh" ]] || die "packaged doctor.sh missing"
[[ -x "$PAYLOAD/script/verify_release_all.sh" ]] || die "packaged verify_release_all.sh missing"
[[ -x "$PAYLOAD/dist/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]] || die "packaged app executable missing"
[[ -x "$PAYLOAD/dist/bin/agent-signal" ]] || die "packaged release CLI missing"
[[ -x "$PAYLOAD/dist/bin/agent-signal-icon-preview" ]] || die "packaged icon preview CLI missing"
[[ -x "$PAYLOAD/scripts/agent-signal-run" ]] || die "packaged agent-signal-run wrapper missing"
[[ -x "$PAYLOAD/scripts/generic-agent-signal-hook" ]] || die "packaged generic agent hook wrapper missing"
[[ -f "$PAYLOAD/dist/status-icon-preview/status-icon-preview.png" ]] || die "packaged status icon preview missing"
[[ -f "$PAYLOAD/dist/status-icon-preview/manifest.json" ]] || die "packaged status icon preview manifest missing"
pass "release zip payload contains app, scripts, CLI, and previews"

/usr/bin/python3 - "$PAYLOAD/dist/status-icon-preview" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
sheet = root / "status-icon-preview.png"
manifest = root / "manifest.json"
data = json.loads(manifest.read_text())
records = data.get("records", [])
if len(records) != 48:
    raise SystemExit("preview manifest should contain 48 records")
if sheet.stat().st_size <= 10_000:
    raise SystemExit("preview sheet is unexpectedly small")
for item in records:
    path = root / item["path"]
    if not path.exists() or path.stat().st_size == 0:
        raise SystemExit(f"missing preview icon {path}")
PY
pass "release zip preview artifacts are complete"

(
  cd "$PAYLOAD"
  AGENT_SIGNAL_APP_INSTALL_DIR="$INSTALL_ROOT" ./script/install_app.sh --no-open >"$TMP_ROOT/install.out"
)
[[ ! -d "$PAYLOAD/.build" ]] || die "install script created .build; release zip install should not rebuild"
pass "release zip install script ran without rebuilding"

INSTALLED_APP="$INSTALL_ROOT/$APP_NAME.app"
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
[[ -x "$CLI_WRAPPER" ]] || die "installed bundled agent-signal wrapper missing"
[[ -x "$RUN_WRAPPER" ]] || die "installed bundled agent-signal-run wrapper missing"
[[ -x "$GENERIC_WRAPPER" ]] || die "installed bundled generic agent hook wrapper missing"
[[ -x "$CLI_BIN" ]] || die "installed bundled agent-signal binary missing"
[[ -x "$DIAGNOSTICS_EXPORTER" ]] || die "installed bundled diagnostics exporter missing"
[[ -x "$HOOK_INSTALLER" ]] || die "installed bundled hook installer missing"
[[ -f "$APP_RESOURCES/AppIcon.icns" ]] || die "installed AppIcon.icns missing"
[[ -f "$RELEASE_INFO" ]] || die "installed release info missing"
pass "release zip installed app bundle resources are present"

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
PY
pass "release zip installed app Info.plist and release info are coherent"

codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP" >/dev/null 2>&1
pass "release zip installed app code signature verifies"

TMP_STATE="$TMP_ROOT/status/status.json"
mkdir -p "$(dirname "$TMP_STATE")"
AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STATE" "$PAYLOAD/scripts/agent-signal" blocked --session zip-red --agent release-zip --event ZipVerifier >/dev/null
AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_STATE" "$CLI_WRAPPER" working --session zip-active --agent release-zip --event ZipVerifier --json >"$TMP_ROOT/status.json"
/usr/bin/python3 - "$TMP_ROOT/status.json" "$TMP_STATE" <<'PY'
import json
import sys
from pathlib import Path

output = json.loads(Path(sys.argv[1]).read_text())
state = json.loads(Path(sys.argv[2]).read_text())
if output["aggregate"] != "blocked":
    raise SystemExit("red priority was not preserved")
sessions = {item["session_id"]: item for item in output["sessions"]}
if sessions["zip-red"]["signal"] != "blocked":
    raise SystemExit("blocked zip session missing")
if sessions["zip-active"]["signal"] != "working":
    raise SystemExit("working zip session missing")
if state["aggregate"] != "blocked":
    raise SystemExit("state file aggregate mismatch")
PY
pass "release zip CLI wrappers write state and preserve red priority"

TMP_RUN_STATE="$TMP_ROOT/run-status/status.json"
set +e
AGENT_SIGNAL_LIGHT_STATE_FILE="$TMP_RUN_STATE" "$RUN_WRAPPER" --session zip-run-fail --agent release-zip -- /bin/sh -c "exit 8" >/dev/null
run_status=$?
set -e
[[ "$run_status" -eq 8 ]] || die "release zip agent-signal-run did not preserve wrapped exit code"
/usr/bin/python3 - "$TMP_RUN_STATE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
sessions = data["sessions"]
if data["aggregate"] != "blocked":
    raise SystemExit("agent-signal-run did not mark aggregate blocked")
if sessions["zip-run-fail"]["signal"] != "blocked":
    raise SystemExit("agent-signal-run did not mark failed session blocked")
if sessions["zip-run-fail"]["last_event"] != "CommandFailed:8":
    raise SystemExit("agent-signal-run did not record wrapped exit code")
PY
pass "release zip agent-signal-run preserves exit code and marks blocked"

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
pass "release zip installed diagnostics exporter writes archive"

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
  [[ -n "$LAUNCHED_PID" ]] || die "release zip installed app did not launch"
  pass "release zip installed app launches"
fi

echo "release zip verifier: ok"
