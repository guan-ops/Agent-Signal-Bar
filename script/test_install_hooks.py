#!/usr/bin/env python3
"""Focused regression tests for transactional hook config writes."""

from __future__ import annotations

import importlib.util
import copy
import io
import json
import errno
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("install_hooks.py")
SPEC = importlib.util.spec_from_file_location("agent_signal_install_hooks", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"unable to load {SCRIPT_PATH}")
install_hooks = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = install_hooks
SPEC.loader.exec_module(install_hooks)


class ClaudeWorktreeHookTests(unittest.TestCase):
    def claude_spec(self, home: Path):
        return install_hooks.specs_for(home, codex_scope="user", project_root=home)["claude"]

    def legacy_config(self, spec):
        data = install_hooks.merge_hooks(spec).data
        for event in ("WorktreeCreate", "WorktreeRemove"):
            data["hooks"][event] = [install_hooks.hook_block(
                install_hooks.hook_command(spec, event), event, spec.matcher,
            )]
        data["fixturePreference"] = {"keep": True}
        return data

    def test_new_install_keeps_worktree_management_with_claude(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            spec = self.claude_spec(Path(directory))
            result = install_hooks.merge_hooks(spec)
            self.assertEqual(len(result.data["hooks"]), 26)
            self.assertNotIn("WorktreeCreate", result.data["hooks"])
            self.assertNotIn("WorktreeRemove", result.data["hooks"])
            self.assertFalse(spec.path.exists(), "preview must not write config")
            install_hooks.write_result(result)
            self.assertFalse(install_hooks.merge_hooks(spec).changed)

    def test_legacy_install_removes_only_two_events_and_keeps_backup(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            spec = self.claude_spec(Path(directory))
            before = self.legacy_config(spec)
            spec.path.parent.mkdir(parents=True)
            spec.path.write_text(json.dumps(before), encoding="utf-8")
            before_bytes = spec.path.read_bytes()

            result = install_hooks.merge_hooks(spec)
            expected = copy.deepcopy(before)
            for event in ("WorktreeCreate", "WorktreeRemove"):
                del expected["hooks"][event]
            self.assertEqual(result.data, expected)
            self.assertEqual(result.added_events, [])
            self.assertEqual(result.migrated_events, [])
            self.assertEqual(set(result.removed_events), {"WorktreeCreate", "WorktreeRemove"})
            self.assertEqual(spec.path.read_bytes(), before_bytes)

            applied = install_hooks.write_result(result)
            self.assertIsNotNone(applied.backup)
            self.assertEqual(applied.backup.read_bytes(), before_bytes)
            self.assertEqual(json.loads(spec.path.read_text()), expected)
            self.assertFalse(install_hooks.merge_hooks(spec).changed)

    def test_migration_preserves_real_worktree_hooks_and_mixed_block_metadata(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            spec = self.claude_spec(Path(directory))
            before = self.legacy_config(spec)
            expected = copy.deepcopy(before)
            for event in ("WorktreeCreate", "WorktreeRemove"):
                external = {"type": "command", "command": f"/fixture/manage-worktree {event}"}
                before["hooks"][event][0]["hooks"].append(external)
                before["hooks"][event][0]["fixtureMetadata"] = "preserve"
                before["hooks"][event].append(install_hooks.hook_block(
                    "'/old/app/Contents/Resources/scripts/claude-code-signal-hook'", event, "",
                ))
                expected["hooks"][event] = [{
                    "hooks": [external], "matcher": "", "fixtureMetadata": "preserve",
                }]
            spec.path.parent.mkdir(parents=True)
            spec.path.write_text(json.dumps(before), encoding="utf-8")

            result = install_hooks.merge_hooks(spec)
            self.assertEqual(result.data, expected)
            install_hooks.write_result(result)
            self.assertFalse(install_hooks.merge_hooks(spec).changed)

    def test_doctor_accepts_safe_config_and_rejects_legacy_worktree_hooks(self) -> None:
        doctor = SCRIPT_PATH.with_name("doctor.sh").read_text()
        marker = '  if /usr/bin/python3 - "$CLAUDE_SETTINGS_FILE"'
        source = doctor.split(marker, 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            spec = self.claude_spec(Path(directory))
            spec.path.parent.mkdir(parents=True)
            for legacy in (False, True):
                with self.subTest(legacy=legacy):
                    data = self.legacy_config(spec) if legacy else install_hooks.merge_hooks(spec).data
                    spec.path.write_text(json.dumps(data), encoding="utf-8")
                    result = subprocess.run(
                        [sys.executable, "-", str(spec.path), str(spec.wrapper), str(SCRIPT_PATH)],
                        input=source, capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, 1 if legacy else 0, result.stderr)
                    if legacy:
                        self.assertIn("status hooks override worktree management", result.stderr)


class ClaudeRuntimeDiscoveryTests(unittest.TestCase):
    def test_native_install_is_found_outside_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / ".local/bin/claude"
            binary.parent.mkdir(parents=True)
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o700)
            with mock.patch.dict(os.environ, {"PATH": "/usr/bin:/bin"}, clear=True):
                self.assertEqual(install_hooks.resolve_claude_cli(home), str(binary))

    def test_explicit_executable_is_respected_without_falling_back(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / "custom claude"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o700)
            with mock.patch.dict(os.environ, {"AGENT_SIGNAL_CLAUDE_EXECUTABLE": str(binary)}, clear=True):
                self.assertEqual(install_hooks.resolve_claude_cli(home), str(binary))
                binary.chmod(0o600)
                self.assertIsNone(install_hooks.resolve_claude_cli(home))

    def test_desktop_presence_and_found_cli_are_informational(self) -> None:
        output = io.StringIO()
        with mock.patch.object(install_hooks, "resolve_claude_cli", return_value="/fixture/claude"), \
             mock.patch.object(install_hooks, "process_is_running", return_value=True), \
             mock.patch.object(install_hooks, "read_recent_text", return_value=""), redirect_stdout(output):
            install_hooks.print_claude_runtime_diagnostics(Path("/fixture/home"))
        self.assertNotIn("[diagnostic]", output.getvalue())
        self.assertIn("[info] Claude Desktop: running", output.getvalue())


class InstallHooksAtomicWriteTests(unittest.TestCase):
    def test_atomic_write_preserves_existing_mode_and_leaves_valid_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "hooks.json"
            path.write_text('{"before": true}\n', encoding="utf-8")
            path.chmod(0o640)

            install_hooks.atomic_write_json(path, {"after": ["ok"]})

            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"after": ["ok"]})
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(list(path.parent.glob(f".{path.name}.*.tmp")), [])

    def test_atomic_write_preserves_acl_and_extended_attributes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "hooks.json"
            path.write_text('{"before": true}\n', encoding="utf-8")
            subprocess.run(
                ["/usr/bin/xattr", "-w", "com.agent-signal.test", "preserved", str(path)],
                check=True,
            )
            subprocess.run(
                ["/bin/chmod", "+a", "everyone allow read", str(path)],
                check=True,
            )

            install_hooks.atomic_write_json(path, {"after": ["ok"]})

            attribute = subprocess.run(
                ["/usr/bin/xattr", "-p", "com.agent-signal.test", str(path)],
                check=True,
                capture_output=True,
                text=True,
            )
            acl = subprocess.run(
                ["/bin/ls", "-lde", str(path)],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(attribute.stdout.strip(), "preserved")
            self.assertIn(" allow read", acl.stdout)

    def test_symlink_and_hardlink_targets_are_rejected_without_topology_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.json"
            source.write_text('{"owner": "source"}\n', encoding="utf-8")

            symlink = root / "symlink.json"
            symlink.symlink_to(source)
            with self.assertRaisesRegex(ValueError, "symlink"):
                install_hooks.atomic_write_json(symlink, {"after": True})
            self.assertTrue(symlink.is_symlink())
            self.assertEqual(source.read_text(encoding="utf-8"), '{"owner": "source"}\n')

            hardlink = root / "hardlink.json"
            os.link(source, hardlink)
            with self.assertRaisesRegex(ValueError, "multiple hard links"):
                install_hooks.atomic_write_json(hardlink, {"after": True})
            self.assertEqual(source.stat().st_ino, hardlink.stat().st_ino)
            self.assertEqual(source.read_text(encoding="utf-8"), '{"owner": "source"}\n')

    def test_concurrent_create_after_merge_is_not_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / ".codex" / "hooks.json"
            spec = install_hooks.TargetSpec(
                name="Codex Test",
                path=path,
                wrapper=install_hooks.CODEX_WRAPPER,
                events=install_hooks.CODEX_EVENTS,
                pass_event_argument=True,
                matcher="*",
            )
            result = install_hooks.merge_hooks(spec)
            path.parent.mkdir(parents=True)
            concurrent_content = b'{"concurrent": "created"}\n'
            path.write_bytes(concurrent_content)

            with self.assertRaisesRegex(
                install_hooks.ConcurrentConfigChangeError,
                "concurrently created",
            ):
                install_hooks.write_result(result)

            self.assertEqual(path.read_bytes(), concurrent_content)
            self.assertEqual(list(path.parent.glob(f".{path.name}.*.tmp")), [])

    def test_atomic_create_commit_cannot_clobber_last_moment_creator(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "hooks.json"
            concurrent_content = b'{"concurrent": "last moment"}\n'
            real_link = os.link

            def create_then_link(
                source: os.PathLike[str],
                target: os.PathLike[str],
                *,
                follow_symlinks: bool = True,
            ) -> None:
                Path(target).write_bytes(concurrent_content)
                real_link(source, target, follow_symlinks=follow_symlinks)

            with mock.patch.object(install_hooks.os, "link", side_effect=create_then_link):
                with self.assertRaisesRegex(
                    install_hooks.ConcurrentConfigChangeError,
                    "concurrently created",
                ):
                    install_hooks.atomic_write_json(path, {"installer": "data"})

            self.assertEqual(path.read_bytes(), concurrent_content)
            self.assertEqual(list(path.parent.glob(f".{path.name}.*.tmp")), [])

    def test_concurrent_edit_after_merge_is_not_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / ".codex" / "hooks.json"
            path.parent.mkdir(parents=True)
            path.write_text('{"owner": "original"}\n', encoding="utf-8")
            spec = install_hooks.TargetSpec(
                name="Codex Test",
                path=path,
                wrapper=install_hooks.CODEX_WRAPPER,
                events=install_hooks.CODEX_EVENTS,
                pass_event_argument=True,
                matcher="*",
            )
            result = install_hooks.merge_hooks(spec)
            concurrent_content = b'{"owner": "concurrent editor"}\n'
            path.write_bytes(concurrent_content)

            with self.assertRaisesRegex(
                install_hooks.ConcurrentConfigChangeError,
                "concurrently changed",
            ):
                install_hooks.write_result(result)

            self.assertEqual(path.read_bytes(), concurrent_content)
            self.assertEqual(list(path.parent.glob(f".{path.name}.*.tmp")), [])

    def test_post_replace_failure_restores_current_target_before_raising(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "hooks.json"
            original = b'{"owner": "original"}\n'
            path.write_bytes(original)
            real_fsync_parent = install_hooks.fsync_parent_directory
            fsync_calls = 0

            def fail_first_parent_fsync(target: Path) -> None:
                nonlocal fsync_calls
                fsync_calls += 1
                if fsync_calls == 1:
                    raise OSError(errno.EIO, "injected post-replace fsync failure")
                real_fsync_parent(target)

            with mock.patch.object(
                install_hooks,
                "fsync_parent_directory",
                side_effect=fail_first_parent_fsync,
            ):
                with self.assertRaisesRegex(OSError, "post-replace fsync failure"):
                    install_hooks.atomic_write_json(path, {"after": True})

            self.assertEqual(fsync_calls, 2)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(path.parent.glob(f".{path.name}.*.tmp")), [])

    def test_later_target_replace_failure_rolls_back_earlier_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            home = Path(temporary_directory) / "home"
            codex_path = home / ".codex" / "hooks.json"
            claude_path = home / ".claude" / "settings.json"
            codex_path.parent.mkdir(parents=True)
            claude_path.parent.mkdir(parents=True)
            codex_original = b'{"owner": "codex-user"}\n'
            claude_original = b'{"owner": "claude-user"}\n'
            codex_path.write_bytes(codex_original)
            claude_path.write_bytes(claude_original)

            real_replace = os.replace
            replace_calls = 0

            def fail_second_replace(source: os.PathLike[str], target: os.PathLike[str]) -> None:
                nonlocal replace_calls
                replace_calls += 1
                if replace_calls == 2:
                    raise OSError("injected second-target replace failure")
                real_replace(source, target)

            arguments = [
                str(SCRIPT_PATH),
                "--target",
                "all",
                "--home",
                str(home),
                "--install",
                "--skip-runtime-diagnostics",
            ]
            stdout = io.StringIO()
            stderr = io.StringIO()
            with mock.patch.object(install_hooks.os, "replace", side_effect=fail_second_replace), \
                 mock.patch.object(install_hooks.sys, "argv", arguments), \
                 redirect_stdout(stdout), \
                 redirect_stderr(stderr):
                exit_code = install_hooks.main()

            self.assertEqual(exit_code, 1)
            self.assertGreaterEqual(replace_calls, 3, "rollback must atomically replace the first target")
            self.assertEqual(codex_path.read_bytes(), codex_original)
            self.assertEqual(claude_path.read_bytes(), claude_original)
            self.assertEqual(stdout.getvalue(), "", "failed transactions must not report targets as installed")
            self.assertIn("[rollback] restored", stderr.getvalue())
            self.assertIn("injected second-target replace failure", stderr.getvalue())
            self.assertEqual(list(codex_path.parent.glob(".*.tmp")), [])
            self.assertEqual(list(claude_path.parent.glob(".*.tmp")), [])

    def test_keyboard_interrupt_rolls_back_applied_target_and_is_reraised(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            home = Path(temporary_directory) / "home"
            codex_path = home / ".codex" / "hooks.json"
            claude_path = home / ".claude" / "settings.json"
            codex_path.parent.mkdir(parents=True)
            claude_path.parent.mkdir(parents=True)
            codex_original = b'{"owner": "codex-user"}\n'
            claude_original = b'{"owner": "claude-user"}\n'
            codex_path.write_bytes(codex_original)
            claude_path.write_bytes(claude_original)

            real_write_result = install_hooks.write_result
            write_calls = 0

            def interrupt_second_write(result: install_hooks.MergeResult):
                nonlocal write_calls
                write_calls += 1
                if write_calls == 2:
                    raise KeyboardInterrupt()
                return real_write_result(result)

            arguments = [
                str(SCRIPT_PATH),
                "--target",
                "all",
                "--home",
                str(home),
                "--install",
                "--skip-runtime-diagnostics",
            ]
            stderr = io.StringIO()
            with mock.patch.object(
                install_hooks,
                "write_result",
                side_effect=interrupt_second_write,
            ), mock.patch.object(install_hooks.sys, "argv", arguments), redirect_stderr(stderr):
                with self.assertRaises(KeyboardInterrupt):
                    install_hooks.main()

            self.assertEqual(codex_path.read_bytes(), codex_original)
            self.assertEqual(claude_path.read_bytes(), claude_original)
            self.assertIn("[rollback] restored", stderr.getvalue())

    def test_rollback_refuses_to_overwrite_concurrent_writer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            home = Path(temporary_directory) / "home"
            codex_path = home / ".codex" / "hooks.json"
            claude_path = home / ".claude" / "settings.json"
            codex_path.parent.mkdir(parents=True)
            claude_path.parent.mkdir(parents=True)
            codex_path.write_text('{"owner": "codex-user"}\n', encoding="utf-8")
            claude_path.write_text('{"owner": "claude-user"}\n', encoding="utf-8")
            concurrent_content = b'{"owner": "concurrent writer"}\n'

            real_write_result = install_hooks.write_result
            write_calls = 0

            def fail_after_concurrent_edit(result: install_hooks.MergeResult):
                nonlocal write_calls
                write_calls += 1
                if write_calls == 2:
                    codex_path.write_bytes(concurrent_content)
                    raise OSError("injected failure after concurrent edit")
                return real_write_result(result)

            arguments = [
                str(SCRIPT_PATH),
                "--target",
                "all",
                "--home",
                str(home),
                "--install",
                "--skip-runtime-diagnostics",
            ]
            stderr = io.StringIO()
            with mock.patch.object(
                install_hooks,
                "write_result",
                side_effect=fail_after_concurrent_edit,
            ), mock.patch.object(install_hooks.sys, "argv", arguments), redirect_stderr(stderr):
                exit_code = install_hooks.main()

            self.assertEqual(exit_code, 1)
            self.assertEqual(codex_path.read_bytes(), concurrent_content)
            self.assertIn("rollback also failed", stderr.getvalue())
            self.assertIn("concurrently changed", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
