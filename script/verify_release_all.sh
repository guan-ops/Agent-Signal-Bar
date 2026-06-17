#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
RELEASE_BASENAME="AgentSignalBar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

SKIP_PACKAGE=0
RUN_UI_VERIFY=0
RUN_LAUNCH_CHECKS=0
STRICT_DOCTOR=0

usage() {
  cat <<EOF
usage: $0 [--skip-package] [--ui] [--launch]

Run the full local release gate for $APP_NAME.

By default this script rebuilds release artifacts, runs tests, verifies
checksums, validates the release zip and DMG install paths, rehearses uninstall,
and runs doctor --full. It uses temporary install roots for release validation.

Options:
  --skip-package  Reuse existing dist/ release artifacts instead of rebuilding.
  --ui            Also run the on-screen Debug Window smoke check, then restore
                  the normal menu bar app launch.
  --launch        Also launch temporary zip/DMG-installed app copies during
                  release artifact verification.
  --strict-doctor Treat doctor warnings as failures. Useful for final local
                  setup checks after hooks/login item are intentionally enabled.
EOF
}

die() {
  printf "[fail] %s\n" "$1" >&2
  exit 1
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

run_step() {
  local title="$1"
  shift
  printf "\n[step] %s\n" "$title"
  "$@"
  printf "[ok] %s\n" "$title"
}

lint_shell_scripts() {
  local path
  for path in "$ROOT_DIR"/script/*.sh "$ROOT_DIR"/scripts/*; do
    [[ -f "$path" ]] || continue
    bash -n "$path"
  done
}

verify_required_artifacts() {
  [[ -d "$ROOT_DIR/dist/$APP_NAME.app" ]] || die "missing dist/$APP_NAME.app"
  [[ -f "$ROOT_DIR/dist/$RELEASE_BASENAME.zip" ]] || die "missing dist/$RELEASE_BASENAME.zip"
  [[ -f "$ROOT_DIR/dist/$RELEASE_BASENAME.dmg" ]] || die "missing dist/$RELEASE_BASENAME.dmg"
  [[ -f "$ROOT_DIR/dist/appcast.xml" ]] || die "missing dist/appcast.xml"
  [[ -f "$ROOT_DIR/dist/$RELEASE_BASENAME-release-manifest.json" ]] || die "missing release manifest"
  [[ -f "$ROOT_DIR/dist/$RELEASE_BASENAME-SHA256SUMS.txt" ]] || die "missing SHA256SUMS file"
}

verify_status_json() {
  local state_file
  state_file="$(mktemp "${TMPDIR:-/tmp}/agent-signal-release-json.XXXXXX")"
  AGENT_SIGNAL_LIGHT_STATE_FILE="$state_file" "$ROOT_DIR/scripts/agent-signal" status --json >/tmp/agent-signal-release-status.json
  /usr/bin/python3 - /tmp/agent-signal-release-status.json <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
if "aggregate" not in data or "sessions" not in data:
    raise SystemExit("status JSON missing aggregate or sessions")
PY
  rm -f "$state_file" /tmp/agent-signal-release-status.json
}

prepare_running_app_for_strict_doctor() {
  local app_bundle="$ROOT_DIR/dist/$APP_NAME.app"
  [[ -x "$app_bundle/Contents/MacOS/$APP_NAME" ]] || die "missing runnable app at $app_bundle"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open "$app_bundle"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      return 0
    fi
    sleep 0.5
  done

  pgrep -x "$APP_NAME" >/dev/null
}

cd "$ROOT_DIR"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-package)
      SKIP_PACKAGE=1
      shift
      ;;
    --ui)
      RUN_UI_VERIFY=1
      shift
      ;;
    --launch)
      RUN_LAUNCH_CHECKS=1
      shift
      ;;
    --strict-doctor)
      STRICT_DOCTOR=1
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

printf "Agent Signal Bar release gate\n"
printf "root: %s\n" "$ROOT_DIR"

run_step "shell scripts parse" lint_shell_scripts

if [[ "$SKIP_PACKAGE" -eq 0 ]]; then
  run_step "release artifacts package" "$ROOT_DIR/script/package_release.sh"
else
  printf "\n[skip] release artifacts package\n"
fi

run_step "required release artifacts exist" verify_required_artifacts
run_step "Swift test suite" swift_tool test
run_step "release checksums verify" shasum -a 256 -c "$ROOT_DIR/dist/$RELEASE_BASENAME-SHA256SUMS.txt"
run_step "CLI status JSON parses" verify_status_json
run_step "local script integrations verify" "$ROOT_DIR/script/verify_local_integrations.sh"

if [[ "$RUN_LAUNCH_CHECKS" -eq 1 ]]; then
  run_step "release zip verifies" "$ROOT_DIR/script/verify_release_zip.sh" --launch
  run_step "release DMG install verifies" "$ROOT_DIR/script/verify_release_install.sh" --launch
else
  run_step "release zip verifies" "$ROOT_DIR/script/verify_release_zip.sh"
  run_step "release DMG install verifies" "$ROOT_DIR/script/verify_release_install.sh"
fi
run_step "uninstall flow verifies" "$ROOT_DIR/script/verify_uninstall.sh"
if [[ "$STRICT_DOCTOR" -eq 1 ]]; then
  run_step "strict doctor app process prepared" prepare_running_app_for_strict_doctor
  run_step "doctor full passes without warnings" "$ROOT_DIR/script/doctor.sh" --full --strict
else
  run_step "doctor full passes" "$ROOT_DIR/script/doctor.sh" --full
fi

if [[ "$RUN_UI_VERIFY" -eq 1 ]]; then
  run_step "on-screen Debug Window UI smoke check" "$ROOT_DIR/script/build_and_run.sh" --ui-verify
  run_step "normal menu bar launch restored" "$ROOT_DIR/script/build_and_run.sh" --verify
  run_step "status bar item runtime health verifies" "$ROOT_DIR/script/build_and_run.sh" --status-item-verify
else
  printf "\n[skip] UI smoke check; run with --ui to include it\n"
fi

printf "\nrelease gate: ok\n"
