#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${AGENT_SIGNAL_APP_INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$BUNDLE_ID.plist"
DEFAULT_STATE_DIR="$HOME/Library/Application Support/Agent Signal Bar/SignalState"
STATE_DIR="${AGENT_SIGNAL_LIGHT_STATE_DIR:-${SIGNAL_LIGHT_STATE_DIR:-$DEFAULT_STATE_DIR}}"
STATE_DIR_USES_DEFAULT=0
if [[ -z "${AGENT_SIGNAL_LIGHT_STATE_DIR:-}" && -z "${SIGNAL_LIGHT_STATE_DIR:-}" ]]; then
  STATE_DIR_USES_DEFAULT=1
fi
ENABLE_LOGIN_ITEM=0
OPEN_AFTER_INSTALL=1
REBUILD_APP=0
SOURCE_APP=""
SOURCE_DMG=""
TMP_ROOT=""
MOUNT_DIR=""

usage() {
  cat <<EOF
usage: $0 [--login-item] [--no-open] [--rebuild] [--source-app <path>] [--dmg <path>]

Install Agent Signal Bar into the current user's Applications directory.

By default the script installs an existing dist/$APP_NAME.app when present,
so release zip users do not need Xcode or Swift installed. Use --rebuild to
force a fresh release build from source, or --dmg to install from a DMG.
EOF
}

absolute_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf "%s\n" "$path"
  else
    printf "%s/%s\n" "$(pwd)" "$path"
  fi
}

cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

prepare_launch_state() {
  /usr/bin/python3 - "$STATE_DIR" "$STATE_DIR_USES_DEFAULT" <<'PY'
import ctypes
import errno
import os
import stat
import sys
from pathlib import Path

state_dir = Path(sys.argv[1])
uses_default = sys.argv[2] == "1"
created = False

ACL_TYPE_EXTENDED = 0x100
libc = ctypes.CDLL(None, use_errno=True)
libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
libc.acl_get_fd_np.restype = ctypes.c_void_p
libc.acl_get_entry.argtypes = [
    ctypes.c_void_p,
    ctypes.c_int,
    ctypes.POINTER(ctypes.c_void_p),
]
libc.acl_get_entry.restype = ctypes.c_int
libc.acl_init.argtypes = [ctypes.c_int]
libc.acl_init.restype = ctypes.c_void_p
libc.acl_set_fd_np.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
libc.acl_set_fd_np.restype = ctypes.c_int
libc.acl_free.argtypes = [ctypes.c_void_p]
libc.acl_free.restype = ctypes.c_int


def has_extended_acl(descriptor: int) -> bool:
    ctypes.set_errno(0)
    acl = libc.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        error_number = ctypes.get_errno()
        if error_number == errno.ENOENT:
            return False
        raise OSError(error_number, os.strerror(error_number))
    try:
        entry = ctypes.c_void_p()
        return libc.acl_get_entry(acl, 0, ctypes.byref(entry)) == 0
    finally:
        libc.acl_free(acl)


def clear_extended_acl(descriptor: int) -> None:
    acl = libc.acl_init(0)
    if not acl:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    try:
        if libc.acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) != 0:
            error_number = ctypes.get_errno()
            raise OSError(error_number, os.strerror(error_number))
    finally:
        libc.acl_free(acl)

try:
    state_info = os.lstat(state_dir)
except FileNotFoundError:
    try:
        state_dir.mkdir(parents=True, mode=0o700, exist_ok=False)
        created = True
    except FileExistsError:
        # A concurrently created explicit directory must pass the same checks
        # as any other pre-existing override.
        created = False
else:
    if stat.S_ISLNK(state_info.st_mode):
        raise SystemExit(f"install_app: refusing symlink state directory: {state_dir}")
    if not stat.S_ISDIR(state_info.st_mode):
        raise SystemExit(f"install_app: state path is not a directory: {state_dir}")

directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
try:
    directory_fd = os.open(state_dir, directory_flags)
except OSError as error:
    raise SystemExit(f"install_app: cannot safely open state directory {state_dir}: {error}") from error

try:
    state_info = os.fstat(directory_fd)
    if not stat.S_ISDIR(state_info.st_mode):
        raise SystemExit(f"install_app: state path is not a directory: {state_dir}")
    if state_info.st_uid != os.getuid():
        raise SystemExit(
            f"install_app: state directory is not owned by the current user: {state_dir}"
        )

    state_mode = stat.S_IMODE(state_info.st_mode)
    if not uses_default and not created and state_mode & 0o022:
        raise SystemExit(
            f"install_app: explicit state directory is group/other writable "
            f"(mode {state_mode:04o}): {state_dir}"
        )
    if not uses_default and not created and has_extended_acl(directory_fd):
        raise SystemExit(
            f"install_app: explicit state directory has an extended ACL: {state_dir}"
        )
    if uses_default or created:
        clear_extended_acl(directory_fd)
        os.fchmod(directory_fd, 0o700)

    log_flags = (
        os.O_WRONLY
        | os.O_APPEND
        | os.O_CREAT
        | os.O_NOFOLLOW
        | os.O_CLOEXEC
        | os.O_NONBLOCK
    )
    for log_name in ("app.out.log", "app.err.log"):
        try:
            log_fd = os.open(log_name, log_flags, 0o600, dir_fd=directory_fd)
        except OSError as error:
            raise SystemExit(
                f"install_app: cannot safely open launchd log {state_dir / log_name}: {error}"
            ) from error
        try:
            log_info = os.fstat(log_fd)
            if not stat.S_ISREG(log_info.st_mode):
                raise SystemExit(
                    f"install_app: launchd log is not a regular file: {state_dir / log_name}"
                )
            if log_info.st_uid != os.getuid():
                raise SystemExit(
                    f"install_app: launchd log is not owned by the current user: "
                    f"{state_dir / log_name}"
                )
            if log_info.st_nlink != 1:
                raise SystemExit(
                    f"install_app: launchd log has multiple hard links: {state_dir / log_name}"
                )
            clear_extended_acl(log_fd)
            os.fchmod(log_fd, 0o600)
        finally:
            os.close(log_fd)
finally:
    os.close(directory_fd)
PY
}

write_launch_agent_plist() {
  /usr/bin/python3 - "$LAUNCH_AGENT_PLIST" "$BUNDLE_ID" "$INSTALLED_APP" "$STATE_DIR" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
bundle_id = sys.argv[2]
installed_app = sys.argv[3]
state_dir = Path(sys.argv[4])

plist = {
    "Label": bundle_id,
    "ProgramArguments": [
        "/usr/bin/open",
        installed_app,
    ],
    "RunAtLoad": True,
    "StandardOutPath": str(state_dir / "app.out.log"),
    "StandardErrorPath": str(state_dir / "app.err.log"),
}

plist_path.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=False))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --login-item|--launch-at-login)
      ENABLE_LOGIN_ITEM=1
      shift
      ;;
    --no-open)
      OPEN_AFTER_INSTALL=0
      shift
      ;;
    --rebuild)
      REBUILD_APP=1
      shift
      ;;
    --source-app)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "install_app: missing value for --source-app" >&2
        exit 2
      fi
      SOURCE_APP="$(absolute_path "$2")"
      shift 2
      ;;
    --dmg|--from-dmg)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "install_app: missing value for $1" >&2
        exit 2
      fi
      SOURCE_DMG="$(absolute_path "$2")"
      shift 2
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

cd "$ROOT_DIR"

if [[ -n "$SOURCE_APP" && -n "$SOURCE_DMG" ]]; then
  echo "install_app: use either --source-app or --dmg, not both" >&2
  exit 2
fi

if [[ "$REBUILD_APP" -eq 1 ]] && { [[ -n "$SOURCE_APP" ]] || [[ -n "$SOURCE_DMG" ]]; }; then
  echo "install_app: --rebuild cannot be combined with --source-app or --dmg" >&2
  exit 2
fi

if [[ "$REBUILD_APP" -eq 1 ]]; then
  APP_BUNDLE="$("$ROOT_DIR/script/package_app.sh" --release)"
elif [[ -n "$SOURCE_APP" ]]; then
  APP_BUNDLE="$SOURCE_APP"
elif [[ -n "$SOURCE_DMG" ]]; then
  [[ -f "$SOURCE_DMG" ]] || { echo "install_app: DMG not found at $SOURCE_DMG" >&2; exit 1; }
  TMP_ROOT="$(mktemp -d)"
  MOUNT_DIR="$TMP_ROOT/mount"
  mkdir -p "$MOUNT_DIR"
  hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$SOURCE_DMG" >/dev/null
  APP_BUNDLE="$MOUNT_DIR/$APP_NAME.app"
elif [[ -x "$ROOT_DIR/dist/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]]; then
  APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
else
  APP_BUNDLE="$("$ROOT_DIR/script/package_app.sh" --release)"
fi

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
  echo "install_app: app executable not found in $APP_BUNDLE" >&2
  exit 1
fi
SOURCE_DESCRIPTION="$APP_BUNDLE"
if [[ -z "$TMP_ROOT" ]]; then
  TMP_ROOT="$(mktemp -d)"
fi
CLEAN_APP="$TMP_ROOT/source/$APP_NAME.app"
mkdir -p "$(dirname "$CLEAN_APP")"
ditto --norsrc "$APP_BUNDLE" "$CLEAN_APP"
plutil -lint "$CLEAN_APP/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$CLEAN_APP" >/dev/null 2>&1

if [[ "$ENABLE_LOGIN_ITEM" -eq 1 ]]; then
  prepare_launch_state
fi

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
ditto --norsrc "$CLEAN_APP" "$INSTALLED_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP" >/dev/null 2>&1

if [[ "$ENABLE_LOGIN_ITEM" -eq 1 ]]; then
  mkdir -p "$LAUNCH_AGENT_DIR"
  write_launch_agent_plist

  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
fi

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
  /usr/bin/open "$INSTALLED_APP"
fi

echo "Installed app: $INSTALLED_APP"
echo "Source app: $SOURCE_DESCRIPTION"
if [[ "$ENABLE_LOGIN_ITEM" -eq 1 ]]; then
  echo "Launch at login: enabled via $LAUNCH_AGENT_PLIST"
fi
