#!/usr/bin/env python3
"""Exercise universal packaging with synthetic Swift/lipo executables."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BUILD_SCRIPT = Path(__file__).with_name("universal_build.sh")


class UniversalBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asb-universal-test-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "tools"
        self.bin.mkdir()
        self.scratch = self.root / "temporary slices"
        self.scratch.mkdir()
        self.shared = self.root / "shared products"
        self.shared.mkdir()
        self.output = self.root / "output/fixture-cli"
        self.inputs = self.root / "lipo-inputs.json"
        self.exit_marker = self.root / "caller-exit"
        self.return_marker = self.root / "caller-return"
        self.environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                                TMPDIR=str(self.scratch), ASB_TEST_SHARED_BIN=str(self.shared),
                                ASB_TEST_LIPO_INPUTS=str(self.inputs),
                                ASB_TEST_EXIT_MARKER=str(self.exit_marker),
                                ASB_TEST_RETURN_MARKER=str(self.return_marker))
        self.write_tool("swift", '''
import os, sys
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ["ASB_TEST_SHARED_BIN"])
if "--show-bin-path" in args:
    print(root)
    raise SystemExit(0)
arch = args[args.index("--triple") + 1].split("-")[0] if "--triple" in args else "native"
if arch == os.environ.get("ASB_TEST_FAIL_ARCH"):
    raise SystemExit(32)
binary = root / "fixture-cli"
binary.write_text(arch)
binary.chmod(0o755)
''')
        self.write_tool("lipo", '''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
inputs = args[1:args.index("-output")]
architectures = [Path(path).read_text() for path in inputs]
Path(os.environ["ASB_TEST_LIPO_INPUTS"]).write_text(json.dumps({
    "paths": inputs, "architectures": architectures}))
if os.environ.get("ASB_TEST_FAIL_LIPO"):
    raise SystemExit(43)
if len(set(architectures)) != len(architectures):
    print("same architectures: " + ", ".join(architectures), file=sys.stderr)
    raise SystemExit(42)
Path(args[args.index("-output") + 1]).write_text(" ".join(architectures))
''')

    def write_tool(self, name, source):
        path = self.bin / name
        path.write_text("#!/usr/bin/python3\n" + source)
        path.chmod(0o755)

    def build(self, architectures, **overrides):
        # Calling without errexit also checks that failures are propagated explicitly.
        command = '''
source "$1"
trap 'printf "exit\\n" >> "$ASB_TEST_EXIT_MARKER"' EXIT
trap 'printf "return\\n" >> "$ASB_TEST_RETURN_MARKER"' RETURN
before="$(trap -p EXIT RETURN)"
agent_signal_build_product fixture fixture-cli release "$2" "$3"
result=$?
after="$(trap -p EXIT RETURN)"
[[ "$before" == "$after" ]] || exit 93
source /dev/null
exit "$result"
'''
        return subprocess.run(["/bin/bash", "-c", command, "test-universal-build",
                               str(BUILD_SCRIPT), str(self.output), architectures],
                              env=dict(self.environment, **overrides),
                              capture_output=True, text=True, timeout=10)

    def assert_cleanup_and_caller_traps(self):
        self.assertEqual(list(self.scratch.glob("agent-signal-slices.*")), [])
        self.assertEqual(self.exit_marker.read_text(), "exit\n")
        self.assertTrue(self.return_marker.exists())

    def test_shared_swift_product_directory_preserves_both_architecture_slices(self):
        result = self.build("arm64 x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "arm64 x86_64")
        self.assertTrue(os.access(self.output, os.X_OK))
        inputs = json.loads(self.inputs.read_text())
        self.assertEqual(inputs["architectures"], ["arm64", "x86_64"])
        self.assertEqual(len(set(inputs["paths"])), 2)
        self.assertTrue(all(not Path(path).exists() for path in inputs["paths"]))
        self.assert_cleanup_and_caller_traps()

    def test_second_build_failure_cleans_first_slice_and_preserves_exit_code(self):
        result = self.build("arm64 x86_64", ASB_TEST_FAIL_ARCH="x86_64")
        self.assertEqual(result.returncode, 32, result.stderr)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.inputs.exists())
        self.assert_cleanup_and_caller_traps()

    def test_lipo_failure_cleans_slices_and_preserves_exit_code(self):
        result = self.build("arm64 x86_64", ASB_TEST_FAIL_LIPO="1")
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertFalse(self.output.exists())
        self.assert_cleanup_and_caller_traps()

    def test_single_architecture_remains_executable_without_lipo(self):
        result = self.build("arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "arm64")
        self.assertTrue(os.access(self.output, os.X_OK))
        self.assertFalse(self.inputs.exists())
        self.assert_cleanup_and_caller_traps()

    def test_native_build_remains_executable_without_lipo(self):
        result = self.build("native")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "native")
        self.assertTrue(os.access(self.output, os.X_OK))
        self.assertFalse(self.inputs.exists())
        self.assert_cleanup_and_caller_traps()


if __name__ == "__main__":
    unittest.main()
