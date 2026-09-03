#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentSignalLight"
BUNDLE_ID="com.agentsignallight.AgentSignalLight"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${AGENT_SIGNAL_APP_INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
DEFAULT_STATE_DIR="$HOME/Library/Application Support/Agent Signal Bar/SignalState"
STATE_DIR="${AGENT_SIGNAL_LIGHT_STATE_DIR:-${SIGNAL_LIGHT_STATE_DIR:-$DEFAULT_STATE_DIR}}"
HOOK_PROJECT_ROOT="${AGENT_SIGNAL_CODEX_PROJECT_ROOT:-$ROOT_DIR}"
HOOK_HOME=""
PURGE_STATE=0
REMOVE_HOOKS=0
KILL_RUNNING_APP=1
RUN_LAUNCHCTL=1

usage() {
  cat <<EOF
usage: $0 [--remove-hooks] [--hook-home DIR] [--purge-state] [--no-kill] [--no-launchctl]

Uninstall Agent Signal Bar from the current user's Applications directory.

Options:
  --remove-hooks  Remove Agent Signal Bar hooks from Codex and Claude config.
  --hook-home DIR Use DIR for hook config paths. Intended for explicit alternate-home installs.
  --purge-state   Remove the state directory. Defaults to $STATE_DIR.
  --no-kill       Do not terminate running AgentSignalLight processes.
  --no-launchctl  Remove the launch-agent plist without calling launchctl.
EOF
}

validate_state_dir_for_purge() {
  /usr/bin/python3 - "$STATE_DIR" "$DEFAULT_STATE_DIR" "$HOME" <<'PY'
import ctypes
import errno
import os
import stat
import sys
from pathlib import Path

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

raw_target = Path(sys.argv[1]).expanduser()
default_target = Path(sys.argv[2]).expanduser().resolve(strict=False)
home = Path(sys.argv[3]).expanduser().resolve(strict=False)
target = raw_target.resolve(strict=False)

unsafe_targets = {
    Path("/"),
    Path("/tmp"),
    Path("/var"),
    Path("/var/tmp"),
    Path("/Users"),
    home,
}
if target in unsafe_targets:
    raise SystemExit(f"Refusing to purge unsafe state directory: {target}")

normalized = str(target).lower()
looks_scoped = any(marker in normalized for marker in ("agent-signal", "agentsignal", "agent_signal"))
if target != default_target and not looks_scoped:
    raise SystemExit(f"Refusing to purge non-Agent-Signal-looking directory: {target}")

try:
    target_info = os.lstat(raw_target)
except FileNotFoundError:
    raise SystemExit(0)

if stat.S_ISLNK(target_info.st_mode):
    raise SystemExit(f"Refusing to purge symlink state directory: {raw_target}")
if not stat.S_ISDIR(target_info.st_mode):
    raise SystemExit(f"Refusing to purge non-directory state path: {raw_target}")
if target_info.st_uid != os.getuid():
    raise SystemExit(f"Refusing to purge state directory not owned by the current user: {raw_target}")
if stat.S_IMODE(target_info.st_mode) & 0o022:
    raise SystemExit(f"Refusing to purge group/other-writable state directory: {raw_target}")

directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
directory_fd = os.open(raw_target, directory_flags)
try:
    opened_info = os.fstat(directory_fd)
    if (opened_info.st_dev, opened_info.st_ino) != (target_info.st_dev, target_info.st_ino):
        raise SystemExit(f"Refusing to purge state directory changed during validation: {raw_target}")
    if not stat.S_ISDIR(opened_info.st_mode):
        raise SystemExit(f"Refusing to purge non-directory state path: {raw_target}")
    if opened_info.st_uid != os.getuid():
        raise SystemExit(
            f"Refusing to purge state directory not owned by the current user: {raw_target}"
        )
    if stat.S_IMODE(opened_info.st_mode) & 0o022:
        raise SystemExit(
            f"Refusing to purge group/other-writable state directory: {raw_target}"
        )
    if has_extended_acl(directory_fd):
        raise SystemExit(f"Refusing to purge state directory with an extended ACL: {raw_target}")
finally:
    os.close(directory_fd)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-hooks)
      REMOVE_HOOKS=1
      shift
      ;;
    --hook-home)
      [[ $# -ge 2 && -n "$2" ]] || {
        echo "--hook-home requires a directory" >&2
        exit 2
      }
      HOOK_HOME="$2"
      shift 2
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

# Refuse an unsafe purge target before removing hooks, the launch agent, or the
# installed app so a validation failure cannot leave a partial uninstall.
if [[ "$PURGE_STATE" -eq 1 ]]; then
  validate_state_dir_for_purge
fi

if [[ "$REMOVE_HOOKS" -eq 1 ]]; then
  HOOK_INSTALLER=""
  if [[ -x "$INSTALLED_APP/Contents/Resources/script/install_hooks.py" ]]; then
    HOOK_INSTALLER="$INSTALLED_APP/Contents/Resources/script/install_hooks.py"
  elif [[ -x "$ROOT_DIR/script/install_hooks.py" ]]; then
    HOOK_INSTALLER="$ROOT_DIR/script/install_hooks.py"
  fi

  if [[ -n "$HOOK_INSTALLER" ]]; then
    HOOK_ARGS=(
      --target all
      --codex-scope both
      --project-root "$HOOK_PROJECT_ROOT"
      --remove
      --install
    )
    if [[ -n "$HOOK_HOME" ]]; then
      HOOK_ARGS+=(--home "$HOOK_HOME")
    fi
    /usr/bin/python3 "$HOOK_INSTALLER" "${HOOK_ARGS[@]}"

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
  rm -rf "$STATE_DIR"
fi

echo "Uninstalled app: $INSTALLED_APP"
if [[ "$REMOVE_HOOKS" -eq 1 ]]; then
  echo "Agent Signal Bar hooks: removal requested"
fi
if [[ "$PURGE_STATE" -eq 1 ]]; then
  echo "State directory removed: $STATE_DIR"
fi
