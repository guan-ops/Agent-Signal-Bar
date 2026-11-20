#!/bin/sh
# Development loop on macOS: build the Qt shell and the lamp tests under /private/tmp,
# run the tests, then either run the app or render every surface with --capture.
#
#   Integrations/Windows/dev-macos.sh            # build, test, run
#   Integrations/Windows/dev-macos.sh capture    # build, test, write PNGs to /private/tmp/asb-capture
#   Integrations/Windows/dev-macos.sh capture-live  # same, but live data from synthetic rollouts
#
# Needs Homebrew Qt: brew install qtbase qtdeclarative qtsvg
set -eu
here=$(cd "$(dirname "$0")" && pwd)
build=/private/tmp/asb-windows-build
qmake=${QMAKE:-/opt/homebrew/bin/qmake}
# rcc cannot open .qrc files under non-ASCII paths, so build through an ASCII symlink.
ln -sfn "$here" /private/tmp/asb-windows-src
src=/private/tmp/asb-windows-src

mkdir -p "$build/tests" "$build/tests-codex" "$build/app" "$build/cli"
(cd "$build/tests" && "$qmake" "$src/tests/signalmodel.pro" >/dev/null && make -s -j8 && ./tst_signalmodel -silent)
(cd "$build/tests-codex" && "$qmake" "$src/tests/codex.pro" >/dev/null && make -s -j8 && ./tst_codex -silent)
# qmake cannot list .qrc dependencies under that path either; always regenerate resources.
(cd "$build/app" && "$qmake" "$src/agent-signal-bar-windows.pro" >/dev/null 2>&1 && rm -f qrc_resources.cpp && make -s -j8)
# The hook command lives next to the app, where the installer looks for it.
(cd "$build/cli" && "$qmake" "$src/cli/agent-signal.pro" >/dev/null && make -s -j8 && cp agent-signal "$build/app/agent-signal")

if [ "${1:-}" = "capture" ]; then
    rm -rf /private/tmp/asb-capture
    "$build/app/AgentSignalBar" --capture /private/tmp/asb-capture
    ls /private/tmp/asb-capture
elif [ "${1:-}" = "capture-live" ]; then
    # Live data path against synthetic rollouts only (never the real ~/.codex).
    python3 -I "$here/tests/make_live_fixture.py" /private/tmp/asb-live-fixture
    # Claude Code hook events through the real hook command, into a fixture state file.
    export AGENT_SIGNAL_LIGHT_STATE_FILE=/private/tmp/asb-live-fixture/status.json
    rm -f "$AGENT_SIGNAL_LIGHT_STATE_FILE"
    printf '{"hook_event_name":"UserPromptSubmit","session_id":"fixture-claude-1","prompt":"synthetic"}' \
        | CLAUDE_CODE_ENTRYPOINT=cli "$build/app/agent-signal" claude-hook
    printf '{"hook_event_name":"PreToolUse","session_id":"fixture-claude-1","tool_name":"Edit"}' \
        | CLAUDE_CODE_ENTRYPOINT=cli "$build/app/agent-signal"
    "$build/app/agent-signal" status
    rm -rf /private/tmp/asb-capture-live
    "$build/app/AgentSignalBar" --codex-dir /private/tmp/asb-live-fixture --capture /private/tmp/asb-capture-live
    ls /private/tmp/asb-capture-live
else
    "$build/app/AgentSignalBar"
fi
