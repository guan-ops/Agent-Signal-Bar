#!/usr/bin/env bash
set -euo pipefail

MODE="readiness"
APP_NAME="AgentSignalLight"
RELEASE_BASENAME="AgentSignalBar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="$ROOT_DIR/dist/$RELEASE_BASENAME.dmg"
DEFAULT_DMG_PATH="$ROOT_DIR/dist/$RELEASE_BASENAME.dmg"
PROFILE="${AGENT_SIGNAL_LIGHT_NOTARY_PROFILE:-${NOTARYTOOL_PROFILE:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --readiness|readiness|check)
      MODE="readiness"
      shift
      ;;
    --submit|submit)
      MODE="submit"
      shift
      ;;
    --dmg)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "notarize_release: missing value for --dmg" >&2
        exit 2
      fi
      DMG_PATH="$2"
      shift 2
      ;;
    --profile)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "notarize_release: missing value for --profile" >&2
        exit 2
      fi
      PROFILE="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
usage: $0 [--readiness|--submit] [--dmg <path>] [--profile <notarytool-profile>]

Environment:
  AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY   Developer ID Application identity used by package_app.sh.
  AGENT_SIGNAL_LIGHT_NOTARY_PROFILE       xcrun notarytool keychain profile.

Typical flow:
  AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY="Developer ID Application: ..." ./script/package_release.sh
  AGENT_SIGNAL_LIGHT_NOTARY_PROFILE="agent-signal-light" ./script/notarize_release.sh --submit
EOF
      exit 0
      ;;
    *)
      echo "usage: $0 [--readiness|--submit] [--dmg <path>] [--profile <notarytool-profile>]" >&2
      exit 2
      ;;
  esac
done

DMG_PATH="$(/usr/bin/python3 - "$DMG_PATH" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
)"
DEFAULT_DMG_PATH="$(/usr/bin/python3 - "$DEFAULT_DMG_PATH" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
)"

developer_id_count() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -c "Developer ID Application" || true
}

print_readiness() {
  local developer_ids
  developer_ids="$(developer_id_count)"
  echo "Agent Signal Bar notarization readiness"
  echo "dmg: $DMG_PATH"

  if xcrun notarytool --version >/dev/null 2>&1; then
    echo "[ok] notarytool available"
  else
    echo "[missing] notarytool unavailable; install full Xcode"
  fi

  if xcrun --find stapler >/dev/null 2>&1; then
    echo "[ok] stapler available"
  else
    echo "[missing] stapler unavailable; install full Xcode"
  fi

  if [[ "$developer_ids" -gt 0 ]]; then
    echo "[ok] Developer ID Application identities: $developer_ids"
  else
    echo "[missing] Developer ID Application identity"
  fi

  if [[ -n "$PROFILE" ]]; then
    echo "[ok] notarytool profile configured: $PROFILE"
  else
    echo "[missing] AGENT_SIGNAL_LIGHT_NOTARY_PROFILE or --profile"
  fi

  if [[ -f "$DMG_PATH" ]]; then
    if hdiutil verify "$DMG_PATH" >/dev/null 2>&1; then
      echo "[ok] DMG verifies"
    else
      echo "[missing] DMG verification failed"
    fi
  else
    echo "[missing] DMG not found; run ./script/package_release.sh"
  fi

  echo
  echo "Submit is available only after packaging with a Developer ID identity and configuring notarytool credentials."
}

refresh_release_metadata_after_staple() {
  local manifest="$ROOT_DIR/dist/$RELEASE_BASENAME-release-manifest.json"
  local appcast="$ROOT_DIR/dist/appcast.xml"
  local checksums="$ROOT_DIR/dist/$RELEASE_BASENAME-SHA256SUMS.txt"

  if [[ -f "$manifest" ]]; then
    /usr/bin/python3 - "$ROOT_DIR" "$manifest" "$DMG_PATH" "$appcast" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2]).resolve()
dmg_path = Path(sys.argv[3]).resolve()
appcast_path = Path(sys.argv[4]).resolve()

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

manifest = json.loads(manifest_path.read_text())

def relative_path(path: Path):
    try:
        return str(path.relative_to(root))
    except ValueError:
        return None

def refresh_artifact(role: str, path: Path):
    if not path.exists():
        return
    relative = relative_path(path)
    for artifact in manifest.get("artifacts", []):
        if artifact.get("role") != role and artifact.get("path") != relative:
            continue
        artifact["bytes"] = path.stat().st_size
        artifact["sha256"] = sha256(path)
        if relative:
            artifact["path"] = relative

refresh_artifact("installer_dmg", dmg_path)
refresh_artifact("sparkle_appcast", appcast_path)

notarization = manifest.setdefault("notarization", {})
notarization["status"] = "stapled"
notarization["stapled_at"] = datetime.now(timezone.utc).isoformat()
manifest["generated_at"] = datetime.now(timezone.utc).isoformat()
manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
PY
  fi

  if [[ -f "$checksums" ]]; then
    (
      cd "$ROOT_DIR"
      if [[ "$DMG_PATH" == "$ROOT_DIR/"* ]]; then
        dmg_checksum_target="${DMG_PATH#$ROOT_DIR/}"
      else
        dmg_checksum_target="$DMG_PATH"
      fi
      checksum_targets=()
      for candidate in \
        "dist/$RELEASE_BASENAME.zip" \
        "$dmg_checksum_target" \
        "dist/appcast.xml" \
        "dist/$RELEASE_BASENAME-release-manifest.json"; do
        if [[ -f "$candidate" ]]; then
          checksum_targets+=("$candidate")
        fi
      done
      if [[ "${#checksum_targets[@]}" -gt 0 ]]; then
        shasum -a 256 "${checksum_targets[@]}" >"$checksums"
        shasum -a 256 -c "$checksums" >/dev/null
      fi
    )
  fi
}

submit_notarization() {
  local developer_ids
  developer_ids="$(developer_id_count)"

  if [[ "$developer_ids" -eq 0 ]]; then
    echo "notarize_release: missing Developer ID Application identity" >&2
    exit 1
  fi
  if [[ -z "$PROFILE" ]]; then
    echo "notarize_release: missing AGENT_SIGNAL_LIGHT_NOTARY_PROFILE or --profile" >&2
    exit 1
  fi
  if [[ ! -f "$DMG_PATH" ]]; then
    echo "notarize_release: DMG not found at $DMG_PATH" >&2
    exit 1
  fi

  hdiutil verify "$DMG_PATH" >/dev/null
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  if [[ "$DMG_PATH" == "$DEFAULT_DMG_PATH" ]]; then
    "$ROOT_DIR/script/generate_appcast.sh" >/dev/null
  else
    echo "Skipping appcast regeneration for non-default DMG path: $DMG_PATH" >&2
  fi
  refresh_release_metadata_after_staple
  spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"
  echo "Notarized DMG: $DMG_PATH"
}

case "$MODE" in
  readiness)
    print_readiness
    ;;
  submit)
    submit_notarization
    ;;
esac
