#!/usr/bin/env python3
"""Safely merge Agent Signal Bar hooks into local Codex and Claude configs."""

from __future__ import annotations

import argparse
import copy
import ctypes
import errno
import json
import os
import pwd
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parents[1]
CODEX_WRAPPER = ROOT_DIR / "scripts" / "codex-signal-hook"
CLAUDE_WRAPPER = ROOT_DIR / "scripts" / "claude-code-signal-hook"

CODEX_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Stop",
]

CLAUDE_EVENTS = [
    "ConfigChange",
    "CwdChanged",
    "Elicitation",
    "ElicitationResult",
    "FileChanged",
    "InstructionsLoaded",
    "SessionStart",
    "TaskCreated",
    "TaskCompleted",
    "TeammateIdle",
    "UserPromptExpansion",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolBatch",
    "PostToolUse",
    "PostToolUseFailure",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
    "PermissionRequest",
    "PermissionDenied",
    "Notification",
    "Stop",
    "StopFailure",
    "WorktreeCreate",
    "WorktreeRemove",
    "SessionEnd",
]


def current_user_home() -> Path:
    """Return the OS account home without trusting the inherited HOME value."""
    return Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()


@dataclass(frozen=True)
class TargetSpec:
    name: str
    path: Path
    wrapper: Path
    events: list[str]
    pass_event_argument: bool
    matcher: str


@dataclass
class MergeResult:
    spec: TargetSpec
    original: FileSnapshot
    changed: bool
    added_events: list[str]
    migrated_events: list[str]
    removed_events: list[str]
    already_present: list[str]
    data: dict[str, Any]

    @property
    def existed(self) -> bool:
        return self.original.existed


@dataclass(frozen=True)
class FileSnapshot:
    existed: bool
    data: bytes = b""
    device: int = 0
    inode: int = 0
    mode: int = 0
    uid: int = 0
    gid: int = 0
    link_count: int = 0
    size: int = 0
    modified_ns: int = 0
    changed_ns: int = 0
    flags: int = 0


@dataclass(frozen=True)
class AppliedWrite:
    result: MergeResult
    backup: Path | None
    written: FileSnapshot


class ConcurrentConfigChangeError(RuntimeError):
    """Raised when a config changes after it was read for a transaction."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge Agent Signal Bar hook commands into Codex and Claude Code JSON configs."
    )
    parser.add_argument(
        "--target",
        choices=["all", "codex", "claude"],
        default="all",
        help="Which config to update. Defaults to all.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--install",
        action="store_true",
        help="Write the merged config. A timestamped backup is created when the file already exists.",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview changes without writing. This is the default.",
    )
    mode.add_argument(
        "--rollback",
        type=Path,
        metavar="BACKUP",
        help="Restore a config file from a timestamped .bak-* backup created by --install.",
    )
    parser.add_argument(
        "--remove",
        action="store_true",
        help="Remove Agent Signal Bar hook commands instead of installing them. Combine with --install to write.",
    )
    parser.add_argument(
        "--home",
        type=Path,
        default=current_user_home(),
        help="Home directory to use for config paths. Defaults to the current OS account home.",
    )
    parser.add_argument(
        "--codex-scope",
        choices=["user", "project", "both"],
        default="user",
        help=(
            "Where to install Codex hooks. 'project' writes <project>/.codex/hooks.json, "
            "'user' writes ~/.codex/hooks.json, and 'both' writes both. Defaults to user."
        ),
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=ROOT_DIR,
        help="Project root used when --codex-scope includes project. Defaults to this checkout.",
    )
    parser.add_argument(
        "--skip-runtime-diagnostics",
        action="store_true",
        help="Do not print local runtime diagnostics after hook config checks.",
    )
    return parser.parse_args()


def specs_for(home: Path, *, codex_scope: str, project_root: Path) -> dict[str, TargetSpec]:
    specs: dict[str, TargetSpec] = {}

    if codex_scope in {"project", "both"}:
        specs["codex-project"] = TargetSpec(
            name="Codex Project",
            path=project_root / ".codex" / "hooks.json",
            wrapper=CODEX_WRAPPER,
            events=CODEX_EVENTS,
            pass_event_argument=True,
            matcher="*",
        )

    if codex_scope in {"user", "both"}:
        specs["codex-user"] = TargetSpec(
            name="Codex User",
            path=home / ".codex" / "hooks.json",
            wrapper=CODEX_WRAPPER,
            events=CODEX_EVENTS,
            pass_event_argument=True,
            matcher="*",
        )

    specs["claude"] = TargetSpec(
        name="Claude Code",
        path=home / ".claude" / "settings.json",
        wrapper=CLAUDE_WRAPPER,
        events=CLAUDE_EVENTS,
        pass_event_argument=False,
        matcher="",
    )
    return specs


def _validate_config_file(path: Path, file_info: os.stat_result) -> None:
    if stat.S_ISLNK(file_info.st_mode):
        raise ValueError(f"refusing symlink config target: {path}")
    if not stat.S_ISREG(file_info.st_mode):
        raise ValueError(f"config target is not a regular file: {path}")
    if file_info.st_nlink != 1:
        raise ValueError(f"refusing config target with multiple hard links: {path}")
    if file_info.st_uid != os.getuid():
        raise ValueError(f"config target is not owned by the current user: {path}")
    file_flags = getattr(file_info, "st_flags", 0)
    if file_flags:
        raise ValueError(f"refusing config target with unsupported file flags: {path}")


def _snapshot_from_stat(file_info: os.stat_result, data: bytes) -> FileSnapshot:
    return FileSnapshot(
        existed=True,
        data=data,
        device=file_info.st_dev,
        inode=file_info.st_ino,
        mode=stat.S_IMODE(file_info.st_mode),
        uid=file_info.st_uid,
        gid=file_info.st_gid,
        link_count=file_info.st_nlink,
        size=file_info.st_size,
        modified_ns=file_info.st_mtime_ns,
        changed_ns=file_info.st_ctime_ns,
        flags=getattr(file_info, "st_flags", 0),
    )


def read_file_snapshot(path: Path) -> FileSnapshot:
    """Read a regular single-link config without following a final symlink."""
    try:
        path_info = os.lstat(path)
    except FileNotFoundError:
        return FileSnapshot(existed=False)

    _validate_config_file(path, path_info)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        _validate_config_file(path, before)
        if (before.st_dev, before.st_ino) != (path_info.st_dev, path_info.st_ino):
            raise ConcurrentConfigChangeError(f"config changed while opening: {path}")

        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 128 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        data = b"".join(chunks)

        after = os.fstat(descriptor)
        _validate_config_file(path, after)
        before_identity = (
            before.st_dev,
            before.st_ino,
            stat.S_IMODE(before.st_mode),
            before.st_uid,
            before.st_gid,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            getattr(before, "st_flags", 0),
        )
        after_identity = (
            after.st_dev,
            after.st_ino,
            stat.S_IMODE(after.st_mode),
            after.st_uid,
            after.st_gid,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            getattr(after, "st_flags", 0),
        )
        if before_identity != after_identity or len(data) != after.st_size:
            raise ConcurrentConfigChangeError(f"config changed while reading: {path}")
        return _snapshot_from_stat(after, data)
    finally:
        os.close(descriptor)


def load_json(path: Path) -> tuple[dict[str, Any], FileSnapshot]:
    snapshot = read_file_snapshot(path)
    if not snapshot.existed:
        return {}, snapshot
    value = json.loads(snapshot.data.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object at the top level")
    return value, snapshot


def hook_command(spec: TargetSpec, event: str) -> str:
    command = shlex.quote(str(spec.wrapper))
    if spec.pass_event_argument:
        command += f" {event}"
    return command


def hook_block(command: str, event: str, matcher: str) -> dict[str, Any]:
    timeout = 10 if event == "PermissionRequest" else 5
    return {
        "hooks": [
            {
                "type": "command",
                "command": command,
                "timeout": timeout,
            }
        ],
        "matcher": matcher,
    }


def event_contains_command(blocks: list[Any], command: str) -> bool:
    for block in blocks:
        if not isinstance(block, dict):
            continue
        hooks = block.get("hooks", [])
        if not isinstance(hooks, list):
            continue
        for item in hooks:
            if isinstance(item, dict) and item.get("command") == command:
                return True
    return False


def command_points_to_agent_signal_wrapper(command: str, spec: TargetSpec) -> bool:
    try:
        parts = shlex.split(command)
    except ValueError:
        parts = command.split()

    if not parts:
        return False

    executable = Path(parts[0]).expanduser()
    if executable.name != spec.wrapper.name:
        return False

    if executable.resolve(strict=False) == spec.wrapper.resolve(strict=False):
        return True

    normalized_path = str(executable).lower()
    if any(
        marker in normalized_path
        for marker in [
            "agent-signal",
            "agentsignal",
            "agent signal",
            "ai agent状态栏红绿灯",
        ]
    ):
        return True

    # Older bundled installers used a plain ".../scripts/<wrapper>" path before
    # the app resource location was stable. Only accept that exact legacy shape
    # after the executable basename has already matched above.
    return executable.parent.name == "scripts"


def remove_stale_agent_signal_commands(
    blocks: list[Any],
    *,
    spec: TargetSpec,
    current_command: str,
) -> tuple[list[Any], bool]:
    migrated = False
    filtered_blocks: list[Any] = []

    for block in blocks:
        if not isinstance(block, dict):
            filtered_blocks.append(block)
            continue

        hooks = block.get("hooks", [])
        if not isinstance(hooks, list):
            filtered_blocks.append(block)
            continue

        filtered_hooks: list[Any] = []
        for item in hooks:
            command = item.get("command") if isinstance(item, dict) else None
            if (
                isinstance(command, str)
                and command != current_command
                and command_points_to_agent_signal_wrapper(command, spec)
            ):
                migrated = True
                continue
            filtered_hooks.append(item)

        if filtered_hooks:
            next_block = copy.deepcopy(block)
            next_block["hooks"] = filtered_hooks
            filtered_blocks.append(next_block)
        elif len(hooks) != len(filtered_hooks):
            migrated = True

    return filtered_blocks, migrated


def merge_hooks(spec: TargetSpec) -> MergeResult:
    data, original = load_json(spec.path)
    merged = copy.deepcopy(data)
    hooks = merged.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"{spec.path} has a non-object 'hooks' value")

    added_events: list[str] = []
    migrated_events: list[str] = []
    removed_events: list[str] = []
    already_present: list[str] = []

    for event in spec.events:
        blocks = hooks.setdefault(event, [])
        if not isinstance(blocks, list):
            raise ValueError(f"{spec.path} has a non-list hooks.{event} value")

        command = hook_command(spec, event)
        blocks, migrated = remove_stale_agent_signal_commands(
            blocks,
            spec=spec,
            current_command=command,
        )
        hooks[event] = blocks
        if migrated:
            migrated_events.append(event)

        if event_contains_command(blocks, command):
            already_present.append(event)
            continue

        blocks.append(hook_block(command, event, spec.matcher))
        added_events.append(event)

    allowed_events = set(spec.events)
    for event, blocks in list(hooks.items()):
        if event in allowed_events:
            continue
        if not isinstance(blocks, list):
            continue
        filtered, removed = remove_stale_agent_signal_commands(
            blocks,
            spec=spec,
            current_command="",
        )
        if removed:
            removed_events.append(str(event))
            if filtered:
                hooks[event] = filtered
            else:
                hooks.pop(event, None)

    return MergeResult(
        spec=spec,
        original=original,
        changed=bool(added_events or migrated_events or removed_events),
        added_events=added_events,
        migrated_events=migrated_events,
        removed_events=removed_events,
        already_present=already_present,
        data=merged,
    )


def remove_hooks(spec: TargetSpec) -> MergeResult:
    data, original = load_json(spec.path)
    merged = copy.deepcopy(data)
    hooks = merged.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"{spec.path} has a non-object 'hooks' value")

    removed_events: list[str] = []

    for event, blocks in list(hooks.items()):
        if not isinstance(blocks, list):
            raise ValueError(f"{spec.path} has a non-list hooks.{event} value")

        filtered_blocks: list[Any] = []
        removed_from_event = False

        for block in blocks:
            if not isinstance(block, dict):
                filtered_blocks.append(block)
                continue

            block_hooks = block.get("hooks", [])
            if not isinstance(block_hooks, list):
                filtered_blocks.append(block)
                continue

            filtered_hooks: list[Any] = []
            for item in block_hooks:
                command = item.get("command") if isinstance(item, dict) else None
                if isinstance(command, str) and command_points_to_agent_signal_wrapper(command, spec):
                    removed_from_event = True
                    continue
                filtered_hooks.append(item)

            if filtered_hooks:
                next_block = copy.deepcopy(block)
                next_block["hooks"] = filtered_hooks
                filtered_blocks.append(next_block)
            elif len(block_hooks) != len(filtered_hooks):
                removed_from_event = True

        if removed_from_event:
            removed_events.append(str(event))
            if filtered_blocks:
                hooks[event] = filtered_blocks
            else:
                hooks.pop(event, None)

    return MergeResult(
        spec=spec,
        original=original,
        changed=bool(removed_events),
        added_events=[],
        migrated_events=[],
        removed_events=removed_events,
        already_present=[],
        data=merged,
    )


def backup_path(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d%H%M%S")
    candidate = path.with_name(f"{path.name}.bak-{stamp}")
    if not os.path.lexists(candidate):
        return candidate

    index = 1
    while True:
        next_candidate = path.with_name(f"{path.name}.bak-{stamp}-{index}")
        if not os.path.lexists(next_candidate):
            return next_candidate
        index += 1


def _snapshot_identity(snapshot: FileSnapshot) -> tuple[Any, ...]:
    if not snapshot.existed:
        return (False,)
    return (
        True,
        snapshot.device,
        snapshot.inode,
        snapshot.mode,
        snapshot.uid,
        snapshot.gid,
        snapshot.link_count,
        snapshot.size,
        snapshot.modified_ns,
        snapshot.changed_ns,
        snapshot.flags,
        snapshot.data,
    )


def require_unchanged(path: Path, expected: FileSnapshot) -> FileSnapshot:
    current = read_file_snapshot(path)
    if _snapshot_identity(current) != _snapshot_identity(expected):
        state = "created" if not expected.existed and current.existed else "changed"
        raise ConcurrentConfigChangeError(f"config was concurrently {state}: {path}")
    return current


def fsync_parent_directory(path: Path) -> None:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    descriptor = os.open(path.parent, flags)
    try:
        try:
            os.fsync(descriptor)
        except OSError as error:
            if error.errno not in {errno.EINVAL, errno.ENOTSUP}:
                raise
    finally:
        os.close(descriptor)


COPYFILE_ACL = 1 << 0
COPYFILE_XATTR = 1 << 2
_LIBC = ctypes.CDLL(None, use_errno=True)
_LIBC.fcopyfile.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
_LIBC.fcopyfile.restype = ctypes.c_int


def copy_security_metadata(
    source_path: Path,
    source_snapshot: FileSnapshot,
    destination_descriptor: int,
) -> None:
    """Copy macOS ACLs and xattrs from the verified source descriptor."""
    if not source_snapshot.existed:
        return
    source_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    source_descriptor = os.open(source_path, source_flags)
    try:
        source_info = os.fstat(source_descriptor)
        _validate_config_file(source_path, source_info)
        if (source_info.st_dev, source_info.st_ino) != (
            source_snapshot.device,
            source_snapshot.inode,
        ):
            raise ConcurrentConfigChangeError(
                f"metadata source was concurrently changed: {source_path}"
            )
        result = _LIBC.fcopyfile(
            source_descriptor,
            destination_descriptor,
            None,
            COPYFILE_ACL | COPYFILE_XATTR,
        )
        if result != 0:
            error_number = ctypes.get_errno()
            raise OSError(
                error_number,
                os.strerror(error_number),
                str(source_path),
            )
    finally:
        os.close(source_descriptor)

    # ACL/xattr changes update ctime. Rechecking the complete snapshot prevents
    # copying metadata from one version while replacing another version's data.
    require_unchanged(source_path, source_snapshot)


def _write_descriptor(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short write while saving hook configuration")
        view = view[written:]


def _set_descriptor_metadata(
    descriptor: int,
    *,
    mode: int,
    uid: int | None,
    gid: int | None,
) -> None:
    if uid is not None and gid is not None:
        os.fchown(descriptor, uid, gid)
    # chown may clear special permission bits, so restore the complete mode last.
    os.fchmod(descriptor, mode)


def _restore_expected_after_failed_commit(
    path: Path,
    expected: FileSnapshot,
    *,
    committed_device: int,
    committed_inode: int,
    committed_data: bytes,
    committed_mode: int,
    committed_uid: int | None,
    committed_gid: int | None,
) -> None:
    current = read_file_snapshot(path)
    if (
        not current.existed
        or (current.device, current.inode) != (committed_device, committed_inode)
        or current.data != committed_data
        or current.mode != committed_mode
        or (committed_uid is not None and current.uid != committed_uid)
        or (committed_gid is not None and current.gid != committed_gid)
    ):
        raise ConcurrentConfigChangeError(
            f"refusing failed-commit rollback because target changed: {path}"
        )

    if expected.existed:
        # The committed file already carries the original ACLs/xattrs, so it is
        # the safe metadata source while restoring the original bytes.
        atomic_write_bytes(
            path,
            expected.data,
            mode=expected.mode,
            expected=current,
            uid=expected.uid,
            gid=expected.gid,
            rollback_on_commit_failure=False,
        )
    else:
        require_unchanged(path, current)
        os.unlink(path)
        fsync_parent_directory(path)


def atomic_write_bytes(
    path: Path,
    data: bytes,
    *,
    mode: int,
    expected: FileSnapshot | None = None,
    uid: int | None = None,
    gid: int | None = None,
    metadata_source_path: Path | None = None,
    metadata_source_snapshot: FileSnapshot | None = None,
    rollback_on_commit_failure: bool = True,
) -> FileSnapshot:
    """Replace path only after a same-directory temporary file is durable."""
    if expected is None:
        expected = read_file_snapshot(path)
    if expected.existed:
        uid = expected.uid if uid is None else uid
        gid = expected.gid if gid is None else gid
        if metadata_source_path is None:
            metadata_source_path = path
            metadata_source_snapshot = expected

    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary_path = Path(temporary_name)
    temporary_device = 0
    temporary_inode = 0
    committed = False
    try:
        _set_descriptor_metadata(descriptor, mode=mode, uid=uid, gid=gid)
        if metadata_source_path is not None and metadata_source_snapshot is not None:
            copy_security_metadata(
                metadata_source_path,
                metadata_source_snapshot,
                descriptor,
            )
        _write_descriptor(descriptor, data)
        os.fsync(descriptor)
        temporary_info = os.fstat(descriptor)
        temporary_device = temporary_info.st_dev
        temporary_inode = temporary_info.st_ino
        os.close(descriptor)
        descriptor = -1

        # This is intentionally checked after the replacement file is fully
        # durable and immediately before rename. It catches both edits to an
        # existing config and creation of a config that was absent at load time.
        require_unchanged(path, expected)
        if expected.existed:
            os.replace(temporary_path, path)
            committed = True
        else:
            try:
                # link(2) is an atomic create-if-absent commit. Unlike replace,
                # it cannot clobber a file created after the final snapshot check.
                os.link(temporary_path, path, follow_symlinks=False)
            except FileExistsError as error:
                raise ConcurrentConfigChangeError(
                    f"config was concurrently created: {path}"
                ) from error
            committed = True
            temporary_path.unlink()
        fsync_parent_directory(path)

        written = read_file_snapshot(path)
        if (
            not written.existed
            or written.data != data
            or written.mode != mode
            or written.link_count != 1
            or (uid is not None and written.uid != uid)
            or (gid is not None and written.gid != gid)
        ):
            raise ConcurrentConfigChangeError(f"written config was concurrently changed: {path}")
        return written
    except BaseException as error:
        if descriptor >= 0:
            os.close(descriptor)
        temporary_path.unlink(missing_ok=True)

        if rollback_on_commit_failure and temporary_inode:
            if not committed:
                try:
                    target_info = os.lstat(path)
                    committed = (target_info.st_dev, target_info.st_ino) == (
                        temporary_device,
                        temporary_inode,
                    )
                except FileNotFoundError:
                    committed = False
            if committed:
                try:
                    _restore_expected_after_failed_commit(
                        path,
                        expected,
                        committed_device=temporary_device,
                        committed_inode=temporary_inode,
                        committed_data=data,
                        committed_mode=mode,
                        committed_uid=uid,
                        committed_gid=gid,
                    )
                except Exception as rollback_error:
                    if hasattr(error, "add_note"):
                        error.add_note(
                            f"failed to roll back committed config {path}: {rollback_error}"
                        )
        raise


def atomic_write_json(
    path: Path,
    data: dict[str, Any],
    *,
    expected: FileSnapshot | None = None,
) -> FileSnapshot:
    if expected is None:
        expected = read_file_snapshot(path)
    mode = expected.mode if expected.existed else 0o644
    payload = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    return atomic_write_bytes(
        path,
        payload,
        mode=mode,
        expected=expected,
        uid=expected.uid if expected.existed else None,
        gid=expected.gid if expected.existed else None,
    )


def create_backup(path: Path, source_path: Path, original: FileSnapshot) -> None:
    """Create a backup without replacing any pre-existing directory entry."""
    if not original.existed:
        raise ValueError("cannot back up a config that did not exist")
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(path, flags, original.mode)
    try:
        _set_descriptor_metadata(
            descriptor,
            mode=original.mode,
            uid=original.uid,
            gid=original.gid,
        )
        # The config is revalidated after copying so a concurrent metadata or
        # content edit prevents both the backup and the eventual replacement.
        copy_security_metadata(source_path, original, descriptor)
        _write_descriptor(descriptor, original.data)
        os.fsync(descriptor)
    except BaseException:
        os.close(descriptor)
        path.unlink(missing_ok=True)
        raise
    else:
        os.close(descriptor)
    fsync_parent_directory(path)


def write_result(result: MergeResult) -> AppliedWrite:
    path = result.spec.path
    path.parent.mkdir(parents=True, exist_ok=True)
    backup: Path | None = None

    if result.existed and result.changed:
        backup = backup_path(path)
        create_backup(backup, path, result.original)

    written = atomic_write_json(path, result.data, expected=result.original)

    return AppliedWrite(result=result, backup=backup, written=written)


def rollback_result(applied: AppliedWrite) -> None:
    target = applied.result.spec.path
    # Never overwrite or delete another writer's change while unwinding a
    # multi-target transaction.
    require_unchanged(target, applied.written)
    original = applied.result.original
    if original.existed:
        atomic_write_bytes(
            target,
            original.data,
            mode=original.mode,
            expected=applied.written,
            uid=original.uid,
            gid=original.gid,
        )
    else:
        require_unchanged(target, applied.written)
        os.unlink(target)
        fsync_parent_directory(target)


def rollback_backup(backup_path: Path) -> Path:
    backup = backup_path.expanduser()
    backup_snapshot = read_file_snapshot(backup)
    if not backup_snapshot.existed:
        raise ValueError(f"rollback backup not found: {backup}")

    marker = ".bak-"
    if marker not in backup.name:
        raise ValueError(f"rollback backup must be a timestamped .bak-* file: {backup}")

    target_name = backup.name.split(marker, 1)[0]
    if not target_name:
        raise ValueError(f"cannot infer rollback target from backup name: {backup}")

    target = backup.with_name(target_name)
    target_snapshot = read_file_snapshot(target)
    atomic_write_bytes(
        target,
        backup_snapshot.data,
        mode=backup_snapshot.mode,
        expected=target_snapshot,
        uid=backup_snapshot.uid,
        gid=backup_snapshot.gid,
        metadata_source_path=backup,
        metadata_source_snapshot=backup_snapshot,
    )
    return target


def print_result(result: MergeResult, *, installed: bool, backup: Path | None = None) -> None:
    status = "updated" if result.changed else "already configured"
    mode = "installed" if installed else "dry-run"
    print(f"[{mode}] {result.spec.name}: {status}")
    print(f"  file: {result.spec.path}")
    print(f"  wrapper: {result.spec.wrapper}")
    if result.added_events:
        print(f"  add events: {', '.join(result.added_events)}")
    if result.migrated_events:
        print(f"  migrate events: {', '.join(result.migrated_events)}")
    if result.removed_events:
        print(f"  remove events: {', '.join(result.removed_events)}")
    if result.already_present:
        print(f"  present: {', '.join(result.already_present)}")
    if backup is not None:
        print(f"  backup: {backup}")


def command_exists(command: str) -> bool:
    return shutil.which(command) is not None


def process_is_running(pattern: str) -> bool:
    try:
        result = subprocess.run(
            ["/usr/bin/pgrep", "-fl", pattern],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def read_recent_text(path: Path, byte_limit: int = 512_000) -> str:
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            if size > byte_limit:
                handle.seek(size - byte_limit)
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def print_claude_runtime_diagnostics(home: Path) -> None:
    log_path = home / "Library" / "Logs" / "Claude" / "main.log"
    log_text = read_recent_text(log_path)
    desktop_running = process_is_running("Claude")
    cli_available = command_exists("claude")

    if not cli_available:
        print("[diagnostic] Claude CLI: not found in PATH")
        print("  effect: terminal Claude Code sessions cannot be exercised with `claude` from this environment.")

    if "Claude Code requires a Pro or Max subscription" in log_text:
        print("[diagnostic] Claude Code runtime: blocked")
        print("  reason: Claude Desktop log says \"Claude Code requires a Pro or Max subscription.\"")
        print("  effect: normal Claude Desktop chat does not emit Claude Code hook events, so Agent Signal Bar can only show app presence until Claude Code/local-agent sessions can start.")
    elif "oauth failed" in log_text and "user:sessions:claude_code" in log_text:
        print("[diagnostic] Claude Code runtime: OAuth failed recently")
        print(f"  log: {log_path}")
        print("  effect: Claude Code hook events may not fire until Claude Code authorization succeeds.")
    elif desktop_running:
        print("[diagnostic] Claude Desktop: running")
        print("  note: Desktop app presence alone is not a Claude Code hook event; thinking/working states require Claude Code/local-agent hook events.")


def main() -> int:
    args = parse_args()
    if args.rollback is not None:
        try:
            target = rollback_backup(args.rollback)
        except (OSError, ValueError, ConcurrentConfigChangeError) as error:
            print(f"install_hooks.py: {error}", file=sys.stderr)
            return 1
        print(f"[rollback] restored {target} from {args.rollback.expanduser()}")
        return 0

    target_specs = specs_for(
        args.home,
        codex_scope=args.codex_scope,
        project_root=args.project_root.expanduser().resolve(),
    )
    if args.target == "all":
        selected = list(target_specs.keys())
    elif args.target == "codex":
        selected = [key for key in target_specs if key.startswith("codex-")]
    else:
        selected = [args.target]
    should_install = bool(args.install)

    applied: list[AppliedWrite] = []
    rendered_results: list[tuple[MergeResult, Path | None]] = []
    try:
        for key in selected:
            result = remove_hooks(target_specs[key]) if args.remove else merge_hooks(target_specs[key])
            applied_write = write_result(result) if should_install and result.changed else None
            backup = applied_write.backup if applied_write is not None else None
            if should_install and result.changed:
                if applied_write is None:
                    raise RuntimeError(f"missing applied write for changed target: {result.spec.path}")
                applied.append(applied_write)
            rendered_results.append((result, backup))
    except BaseException as error:
        rollback_errors: list[str] = []
        for applied_write in reversed(applied):
            try:
                rollback_result(applied_write)
                print(f"[rollback] restored {applied_write.result.spec.path}", file=sys.stderr)
            except Exception as rollback_error:
                rollback_errors.append(
                    f"{applied_write.result.spec.path}: {rollback_error}"
                )

        if isinstance(error, (KeyboardInterrupt, SystemExit, GeneratorExit)):
            if rollback_errors:
                print(
                    "install_hooks.py: rollback also failed: " + "; ".join(rollback_errors),
                    file=sys.stderr,
                )
            raise

        if not isinstance(
            error,
            (OSError, json.JSONDecodeError, ValueError, ConcurrentConfigChangeError),
        ):
            raise

        print(f"install_hooks.py: {error}", file=sys.stderr)
        if rollback_errors:
            print(
                "install_hooks.py: rollback also failed: " + "; ".join(rollback_errors),
                file=sys.stderr,
            )
        return 1

    for result, backup in rendered_results:
        print_result(result, installed=should_install, backup=backup)

    if not args.skip_runtime_diagnostics and not args.remove and ("claude" in selected):
        print_claude_runtime_diagnostics(args.home)

    if not should_install:
        action = "--remove --install" if args.remove else "--install"
        print(f"No files were written. Re-run with {action} to apply these changes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
