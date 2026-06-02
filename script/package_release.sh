#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_ROOT="$DIST_DIR/release"
PAYLOAD_DIR="$RELEASE_ROOT/$APP_NAME"
ARCHIVE="$DIST_DIR/${APP_NAME}-local.zip"
DMG="$DIST_DIR/${APP_NAME}-local.dmg"
CHECKSUMS="$DIST_DIR/${APP_NAME}-SHA256SUMS.txt"
MANIFEST="$DIST_DIR/${APP_NAME}-release-manifest.json"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

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

cleanup_duplicate_artifacts() {
  mkdir -p "$DIST_DIR"
  find "$DIST_DIR" -maxdepth 1 \( \
    -name "$APP_NAME-local *.zip" -o \
    -name "$APP_NAME-SHA256SUMS *.txt" -o \
    -name "$APP_NAME *.app" \
  \) -exec rm -rf {} +
}

cleanup_duplicate_artifacts

APP_BUNDLE="$("$ROOT_DIR/script/package_app.sh" --release)"
"$ROOT_DIR/script/install_cli.sh" >/dev/null
swift_tool build -c release --product agent-signal-icon-preview >/dev/null
PREVIEW_BINARY="$(swift_tool build -c release --show-bin-path)/agent-signal-icon-preview"
mkdir -p "$ROOT_DIR/dist/bin"
cp "$PREVIEW_BINARY" "$ROOT_DIR/dist/bin/agent-signal-icon-preview"
chmod +x "$ROOT_DIR/dist/bin/agent-signal-icon-preview"
"$ROOT_DIR/dist/bin/agent-signal-icon-preview" "$ROOT_DIR/dist/status-icon-preview" >/dev/null

rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR/dist/bin"

cp "$ROOT_DIR/Package.swift" "$PAYLOAD_DIR/Package.swift"
cp "$ROOT_DIR/README.md" "$PAYLOAD_DIR/README.md"
if [[ -f "$ROOT_DIR/README.zh-CN.md" ]]; then
  cp "$ROOT_DIR/README.zh-CN.md" "$PAYLOAD_DIR/README.zh-CN.md"
fi
cp -R "$ROOT_DIR/Sources" "$PAYLOAD_DIR/Sources"
cp -R "$ROOT_DIR/Tests" "$PAYLOAD_DIR/Tests"
cp -R "$ROOT_DIR/script" "$PAYLOAD_DIR/script"
cp -R "$ROOT_DIR/scripts" "$PAYLOAD_DIR/scripts"
cp -R "$ROOT_DIR/docs" "$PAYLOAD_DIR/docs"
mkdir -p "$PAYLOAD_DIR/.codex"
if [[ -f "$ROOT_DIR/.codex/config.toml" ]]; then
  cp "$ROOT_DIR/.codex/config.toml" "$PAYLOAD_DIR/.codex/config.toml"
fi
if [[ -d "$ROOT_DIR/.codex/environments" ]]; then
  cp -R "$ROOT_DIR/.codex/environments" "$PAYLOAD_DIR/.codex/environments"
fi
cp -R "$APP_BUNDLE" "$PAYLOAD_DIR/dist/$APP_NAME.app"
cp "$ROOT_DIR/dist/bin/agent-signal" "$PAYLOAD_DIR/dist/bin/agent-signal"
cp "$ROOT_DIR/dist/bin/agent-signal-icon-preview" "$PAYLOAD_DIR/dist/bin/agent-signal-icon-preview"
cp -R "$ROOT_DIR/dist/status-icon-preview" "$PAYLOAD_DIR/dist/status-icon-preview"
printf "packaged-release\n" >"$PAYLOAD_DIR/dist/.packaged-release"

find "$PAYLOAD_DIR" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$PAYLOAD_DIR" -type f \( -name '*.pyc' -o -name '.DS_Store' \) -delete
rm -rf "$PAYLOAD_DIR/marketing"
rm -f "$PAYLOAD_DIR/.codex/hooks.json" "$PAYLOAD_DIR/.codex"/hooks.json.*

chmod +x "$PAYLOAD_DIR/dist/bin/agent-signal" \
  "$PAYLOAD_DIR/dist/bin/agent-signal-icon-preview" \
  "$PAYLOAD_DIR/scripts/agent-signal" \
  "$PAYLOAD_DIR/scripts/codex-signal-hook" \
  "$PAYLOAD_DIR/scripts/claude-code-signal-hook" \
  "$PAYLOAD_DIR/script/"*.sh \
  "$PAYLOAD_DIR/script/"*.py

plutil -lint "$PAYLOAD_DIR/dist/$APP_NAME.app/Contents/Info.plist" >/dev/null
VERIFY_APP="$(mktemp -d)/$APP_NAME.app"
ditto --norsrc "$PAYLOAD_DIR/dist/$APP_NAME.app" "$VERIFY_APP"
codesign --verify --deep --strict --verbose=2 "$VERIFY_APP" >/dev/null

rm -f "$ARCHIVE" "$DMG" "$CHECKSUMS" "$MANIFEST"
(
  cd "$RELEASE_ROOT"
  ditto -c -k --norsrc --keepParent "$APP_NAME" "$ARCHIVE"
)

"$ROOT_DIR/script/package_dmg.sh" --use-existing-app --output "$DMG" >/dev/null

/usr/bin/python3 - "$ROOT_DIR" "$APP_NAME" "$APP_BUNDLE" "$ARCHIVE" "$DMG" "$MANIFEST" <<'PY'
import hashlib
import json
import os
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
app_name = sys.argv[2]
app_bundle = Path(sys.argv[3])
archive = Path(sys.argv[4])
dmg = Path(sys.argv[5])
manifest_path = Path(sys.argv[6])

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def run_output(args):
    try:
        return subprocess.check_output(args, cwd=root, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return None

def developer_id_count() -> int:
    output = run_output(["security", "find-identity", "-v", "-p", "codesigning"])
    if not output:
        return 0
    return sum(1 for line in output.splitlines() if "Developer ID Application" in line)

info_path = app_bundle / "Contents" / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
signing_identity = os.environ.get("AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY") or os.environ.get("CODE_SIGN_IDENTITY")
notary_profile = os.environ.get("AGENT_SIGNAL_LIGHT_NOTARY_PROFILE") or os.environ.get("NOTARYTOOL_PROFILE")
git_commit = run_output(["git", "rev-parse", "--short", "HEAD"])
git_dirty = run_output(["git", "status", "--short"])

artifacts = []
for role, path in [("source_zip", archive), ("installer_dmg", dmg)]:
    artifacts.append(
        {
            "role": role,
            "path": str(path.relative_to(root)),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        }
    )

manifest = {
    "schema_version": 1,
    "app_name": app_name,
    "bundle_identifier": info.get("CFBundleIdentifier"),
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "minimum_system_version": info.get("LSMinimumSystemVersion"),
    "git": {
        "commit": git_commit,
        "dirty": bool(git_dirty),
    },
    "signing": {
        "mode": "developer_id" if signing_identity else "ad_hoc",
        "identity_configured": bool(signing_identity),
        "developer_id_identities_available": developer_id_count(),
        "hardened_runtime_requested": bool(signing_identity),
        "timestamp_requested": bool(signing_identity),
    },
    "notarization": {
        "profile_configured": bool(notary_profile),
        "ready_to_submit": bool(signing_identity and notary_profile),
        "status": "not_submitted",
    },
    "artifacts": artifacts,
}

manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
PY

(
  cd "$ROOT_DIR"
  shasum -a 256 \
    "dist/$(basename "$ARCHIVE")" \
    "dist/$(basename "$DMG")" \
    "dist/$(basename "$MANIFEST")" >"$CHECKSUMS"
)

echo "Release archive: $ARCHIVE"
echo "Release DMG: $DMG"
echo "Release manifest: $MANIFEST"
echo "Checksums: $CHECKSUMS"
