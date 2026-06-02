#!/usr/bin/env python3
"""Safely merge Agent Signal Bar hooks into local Codex and Claude configs."""

from __future__ import annotations

import argparse
import copy
import json
import os
import shutil
import shlex
import subprocess
import sys
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
    existed: bool
    changed: bool
    added_events: list[str]
    migrated_events: list[str]
    removed_events: list[str]
    already_present: list[str]
    data: dict[str, Any]


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
    parser.add_argument(
        "--remove",
        action="store_true",
        help="Remove Agent Signal Bar hook commands instead of installing them. Combine with --install to write.",
    )
    parser.add_argument(
        "--home",
        type=Path,
        default=Path(os.environ.get("HOME", "~")).expanduser(),
        help="Home directory to use for config paths. Defaults to $HOME.",
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


def load_json(path: Path) -> tuple[dict[str, Any], bool]:
    if not path.exists():
        return {}, False
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object at the top level")
    return value, True


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
    data, existed = load_json(spec.path)
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
        existed=existed,
        changed=bool(added_events or migrated_events or removed_events),
        added_events=added_events,
        migrated_events=migrated_events,
        removed_events=removed_events,
        already_present=already_present,
        data=merged,
    )


def remove_hooks(spec: TargetSpec) -> MergeResult:
    data, existed = load_json(spec.path)
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
        existed=existed,
        changed=bool(removed_events),
        added_events=[],
        migrated_events=[],
        removed_events=removed_events,
        already_present=[],
        data=merged,
    )


def backup_path(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d%H%M%S")
    return path.with_name(f"{path.name}.bak-{stamp}")


def write_result(result: MergeResult) -> Path | None:
    path = result.spec.path
    path.parent.mkdir(parents=True, exist_ok=True)
    backup: Path | None = None

    if result.existed and result.changed:
        backup = backup_path(path)
        shutil.copy2(path, backup)

    with path.open("w", encoding="utf-8") as handle:
        json.dump(result.data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    return backup


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

    try:
        for key in selected:
            result = remove_hooks(target_specs[key]) if args.remove else merge_hooks(target_specs[key])
            backup = write_result(result) if should_install and result.changed else None
            print_result(result, installed=should_install, backup=backup)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"install_hooks.py: {error}", file=sys.stderr)
        return 1

    if not args.skip_runtime_diagnostics and not args.remove and ("claude" in selected):
        print_claude_runtime_diagnostics(args.home)

    if not should_install:
        action = "--remove --install" if args.remove else "--install"
        print(f"No files were written. Re-run with {action} to apply these changes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
