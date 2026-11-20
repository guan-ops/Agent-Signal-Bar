#!/bin/sh
# Development loop on macOS: build the Qt shell and the lamp tests under /private/tmp,
# run the tests, then either run the app or render every surface with --capture.
#
#   Integrations/Windows/dev-macos.sh            # build, test, run
#   Integrations/Windows/dev-macos.sh capture    # build, test, write PNGs to /private/tmp/asb-capture
#
# Needs Homebrew Qt: brew install qtbase qtdeclarative qtsvg
set -eu
here=$(cd "$(dirname "$0")" && pwd)
build=/private/tmp/asb-windows-build
qmake=${QMAKE:-/opt/homebrew/bin/qmake}
# rcc cannot open .qrc files under non-ASCII paths, so build through an ASCII symlink.
ln -sfn "$here" /private/tmp/asb-windows-src
src=/private/tmp/asb-windows-src

mkdir -p "$build/tests" "$build/app"
(cd "$build/tests" && "$qmake" "$src/tests/signalmodel.pro" >/dev/null && make -s -j8 && ./tst_signalmodel -silent)
# qmake cannot list .qrc dependencies under that path either; always regenerate resources.
(cd "$build/app" && "$qmake" "$src/agent-signal-bar-windows.pro" >/dev/null 2>&1 && rm -f qrc_resources.cpp && make -s -j8)

if [ "${1:-}" = "capture" ]; then
    rm -rf /private/tmp/asb-capture
    "$build/app/AgentSignalBar" --capture /private/tmp/asb-capture
    ls /private/tmp/asb-capture
else
    "$build/app/AgentSignalBar"
fi
