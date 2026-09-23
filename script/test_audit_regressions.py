#!/usr/bin/env python3
"""Regression checks using synthetic commands and temporary archive inputs."""

import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parent.parent


class CommandRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asb-runner-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.runner = scripts / "agent-signal-run"
        shutil.copy2(ROOT / "scripts/agent-signal-run", self.runner)
        signal = scripts / "agent-signal"
        signal.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$ASB_TEST_SIGNALS"\n')
        signal.chmod(0o700)
        self.log = self.root / "signals"
        self.environment = dict(os.environ, ASB_TEST_SIGNALS=str(self.log))

    def run_command(self, args):
        try:
            return subprocess.run(["/bin/bash", str(self.runner), *args],
                                  env=self.environment, capture_output=True, text=True, timeout=1)
        except subprocess.TimeoutExpired:
            self.fail("Argument rejection must exit promptly, not loop")

    def test_missing_option_values_exit_without_starting_a_command(self):
        for option in ["--session", "-s", "--agent", "--source", "--start-event",
                       "--done-event", "--blocked-event", "--failed-event"]:
            with self.subTest(option=option):
                result = self.run_command([option])
                self.assertEqual(result.returncode, 2)
                self.assertEqual(len(result.stderr.splitlines()), 1)
                self.assertFalse(self.log.exists())

    def test_invalid_values_do_not_run_the_wrapped_command(self):
        marker = self.root / "unexpected-command"
        for value in ["", "--invalid"]:
            with self.subTest(value=value):
                result = self.run_command(["--agent", value, "--", "/usr/bin/touch", str(marker)])
                self.assertEqual(result.returncode, 2)
                self.assertFalse(marker.exists())
                self.assertFalse(self.log.exists())

    def test_valid_commands_keep_exit_status_and_completion_signal(self):
        for status, signal in [(0, "done"), (7, "blocked")]:
            with self.subTest(status=status):
                self.log.unlink(missing_ok=True)
                result = self.run_command(["--session", "fixture with spaces", "--",
                                           "/bin/sh", "-c", f"exit {status}"])
                self.assertEqual(result.returncode, status)
                lines = self.log.read_text().splitlines()
                self.assertEqual(len(lines), 2)
                self.assertTrue(lines[0].startswith("working "))
                self.assertTrue(lines[1].startswith(signal + " "))


class DiagnosticsArchiveTests(unittest.TestCase):
    def export_archive(self, root, source="fixture"):
        # Exercise the real packaging boundary without collecting user diagnostics.
        script = (ROOT / "script/export_diagnostics.sh").read_text()
        packaging = script[script.index('\nrm -f "$ARCHIVE"') + 1:]
        return subprocess.run(["/bin/bash", "-u", "-c", packaging],
                              env=dict(os.environ, OUTPUT_ROOT=str(root), RUN_ID=source,
                                       WORK_DIR=str(root / source), ARCHIVE=str(root / "fixture.zip")),
                              capture_output=True, text=True, timeout=5)

    def test_archive_destination_error_is_not_reported_as_success(self):
        with tempfile.TemporaryDirectory(prefix="asb-export-test-") as directory:
            root = Path(directory)
            (root / "fixture").mkdir()
            (root / "fixture.zip").mkdir()
            result = self.export_archive(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("Diagnostics archive:", result.stdout)

    def test_ditto_failure_is_not_reported_as_success(self):
        with tempfile.TemporaryDirectory(prefix="asb-export-test-") as directory:
            root = Path(directory)
            result = self.export_archive(root, source="missing")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("Diagnostics archive:", result.stdout)
            self.assertFalse((root / "fixture.zip").exists())

    def test_success_returns_a_readable_zip_with_the_expected_payload(self):
        with tempfile.TemporaryDirectory(prefix="asb-export-test-") as directory:
            root = Path(directory)
            (root / "fixture").mkdir()
            (root / "fixture/note.txt").write_text("synthetic diagnostics")
            result = self.export_archive(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Diagnostics archive:", result.stdout)
            with zipfile.ZipFile(root / "fixture.zip") as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(archive.read("fixture/note.txt"), b"synthetic diagnostics")


class ReleaseIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asb-isolation-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "script").mkdir()
        self.home = self.root / "diagnostic-home"
        self.home.mkdir()
        self.environment = dict(os.environ)
        for key in ["AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME", "AGENT_SIGNAL_LIGHT_STATE_FILE",
                    "AGENT_SIGNAL_LIGHT_STATE_DIR", "SIGNAL_LIGHT_STATE_DIR"]:
            self.environment.pop(key, None)

    def script(self, name, text):
        path = self.root / "script" / name
        path.write_text(text)
        path.chmod(0o700)
        return path

    def run_script(self, path, *arguments, environment=None):
        return subprocess.run(["/bin/bash", str(path), *arguments],
                              env=environment or self.environment,
                              capture_output=True, text=True, timeout=10)

    def test_doctor_resolves_all_user_paths_from_diagnostic_home(self):
        # Stop before diagnostics: the pre-fix run must never read real user files.
        source = (ROOT / "script/doctor.sh").read_text()
        preamble = source[:source.index('\ncd "$ROOT_DIR"')]
        log_assignment = next(line for line in source.splitlines() if line.startswith("CLAUDE_DESKTOP_LOG="))
        preamble += "\n" + log_assignment + "\n"
        probe = self.script("doctor.sh", preamble + '''
printf '%s\\n' "$STATE_FILE" "$LAUNCH_AGENT_PLIST" "$CODEX_HOOKS_FILE" "$CLAUDE_SETTINGS_FILE" "$CLAUDE_DESKTOP_LOG"
''')
        result = self.run_script(probe, environment=dict(
            self.environment, AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME=str(self.home)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            str(self.home / "Library/Application Support/Agent Signal Bar/SignalState/status.json"),
            str(self.home / "Library/LaunchAgents/com.agentsignallight.AgentSignalLight.plist"),
            str(self.home / ".codex/hooks.json"), str(self.home / ".claude/settings.json"),
            str(self.home / "Library/Logs/Claude/main.log")])

    def test_export_forwards_home_and_copies_only_fixture_state_and_launch_agent(self):
        source = (ROOT / "script/export_diagnostics.sh").read_text()
        # Fail closed before any capture/copy if the override was not applied.
        boundary = '\nrun_capture "sw_vers"'
        guard = '''
[[ "$LAUNCH_AGENT_PLIST" == "$AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME/Library/LaunchAgents/com.agentsignallight.AgentSignalLight.plist" ]] || exit 91
'''
        exporter = self.script("export_diagnostics.sh", source.replace(boundary, guard + boundary, 1))
        (self.root / "scripts").mkdir()
        signal = self.root / "scripts/agent-signal"
        signal.write_text('#!/bin/bash\nprintf "%s\\n" "${AGENT_SIGNAL_LIGHT_STATE_FILE:-UNSCOPED}"\n')
        signal.chmod(0o700)
        self.script("doctor.sh", '#!/bin/bash\nprintf "fixture doctor\\n"\n')
        self.script("install_hooks.py", '''#!/usr/bin/python3
import json, sys
print(json.dumps(sys.argv[1:]))
''')
        launch = self.home / "Library/LaunchAgents/com.agentsignallight.AgentSignalLight.plist"
        launch.parent.mkdir(parents=True)
        launch.write_text("fixture launch agent")
        state = self.home / "Library/Application Support/Agent Signal Bar/SignalState/status.json"
        state.parent.mkdir(parents=True)
        state.write_text('{"fixture":true}')
        result = self.run_script(exporter, "--output", str(self.root / "output"),
                                 environment=dict(self.environment,
                                     AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME=str(self.home)))
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = next((self.root / "output").glob("*.zip"))
        with zipfile.ZipFile(archive) as package:
            def content(suffix):
                return package.read(next(name for name in package.namelist() if name.endswith(suffix))).decode()
            self.assertEqual(content("files/status.json"), '{"fixture":true}')
            self.assertEqual(content("config/launch-agent.plist"), "fixture launch agent")
            self.assertIn(str(state), content("commands/agent-signal-status-json.txt"))
            self.assertNotIn("UNSCOPED", content("commands/agent-signal-status-json.txt"))
            self.assertIn(json.dumps(["--target", "all", "--home", str(self.home), "--dry-run"]),
                          content("commands/install-hooks-dry-run.txt"))

    def prepare_gate(self):
        gate = self.script("verify_release_all.sh", (ROOT / "script/verify_release_all.sh").read_text())
        self.script("universal_build.sh", 'agent_signal_normalize_archs() { printf "%s" "$1"; }\n')
        (self.root / "VERSION").write_text("VERSION=1.0.0\n")
        self.script("package_release.sh", '''#!/bin/bash
/usr/bin/python3 - <<'PY'
import json, os
from pathlib import Path
home = os.environ.get("AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME", "")
Path(os.environ["ASB_TEST_GATE_CAPTURE"]).write_text(json.dumps({
    "home": home, "home_exists": Path(home).is_dir() if home else False,
    "state": os.environ.get("AGENT_SIGNAL_LIGHT_STATE_FILE", ""),
    "state_dir": os.environ.get("AGENT_SIGNAL_LIGHT_STATE_DIR", ""),
    "process_home": os.environ.get("HOME")}))
raise SystemExit(73)
PY
''')
        return gate

    def test_isolated_gate_scopes_children_and_cleans_up_on_failure(self):
        gate = self.prepare_gate()
        capture = self.root / "capture.json"
        result = self.run_script(gate, "--isolated", environment=dict(
            self.environment, ASB_TEST_GATE_CAPTURE=str(capture)))
        self.assertEqual(result.returncode, 73, result.stderr)
        data = json.loads(capture.read_text())
        self.assertTrue(data["home_exists"])
        self.assertTrue(Path(data["home"]).is_absolute())
        self.assertEqual(data["process_home"], os.environ.get("HOME"))
        self.assertEqual(Path(data["state"]).parent, Path(data["state_dir"]))
        self.assertFalse(Path(data["home"]).exists())

    def test_isolated_gate_rejects_options_that_restart_the_app(self):
        gate = self.prepare_gate()
        capture = self.root / "capture.json"
        for option in ["--ui", "--launch", "--strict-doctor"]:
            with self.subTest(option=option):
                result = self.run_script(gate, option, "--isolated", environment=dict(
                    self.environment, ASB_TEST_GATE_CAPTURE=str(capture)))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cannot be combined", result.stderr)
                self.assertFalse(capture.exists())

    def test_isolated_artifact_verifiers_reject_exporters_without_isolation_support(self):
        resources = self.root / "resources"
        (resources / "script").mkdir(parents=True)
        exporter = resources / "script/export_diagnostics.sh"
        doctor = resources / "script/doctor.sh"
        for name in ["verify_release_zip.sh", "verify_release_install.sh"]:
            source = (ROOT / "script" / name).read_text()
            # Execute the actual pre-export boundary without mounting or launching an app.
            boundary = source[source.index('DIAGNOSTICS_DIR="$TMP_ROOT/diagnostics"'):]
            boundary = boundary[:boundary.index('"$DIAGNOSTICS_EXPORTER" --output')]
            probe = self.script(name, 'set -euo pipefail\ndie() { echo "$1" >&2; exit 1; }\n'
                                + boundary + '\nprintf "safe to export\\n"\n')
            environment = dict(self.environment, TMP_ROOT=str(self.root),
                               APP_RESOURCES=str(resources), DIAGNOSTICS_EXPORTER=str(exporter),
                               AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME=str(self.home))
            for exporter_supported, doctor_supported in [(False, False), (True, False), (True, True)]:
                supported = exporter_supported and doctor_supported
                with self.subTest(verifier=name, exporter=exporter_supported, doctor=doctor_supported):
                    for path, supports_home in [(exporter, exporter_supported), (doctor, doctor_supported)]:
                        path.write_text('#!/bin/bash\necho "'
                                        + ("AGENT_SIGNAL_LIGHT_DIAGNOSTIC_HOME" if supports_home else "usage")
                                        + '"\n')
                        path.chmod(0o700)
                    result = self.run_script(probe, environment=environment)
                    self.assertEqual(result.returncode == 0, supported, result.stderr)
                    self.assertEqual("safe to export" in result.stdout, supported)


if __name__ == "__main__":
    unittest.main()
