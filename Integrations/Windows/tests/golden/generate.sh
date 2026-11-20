#!/bin/sh
# Regenerates the golden files from the Swift AgentSignalLightCore sources (macOS only):
#   lamp_golden.jsonl  - lamp intensity/scale tables (main.swift)
#   codex_golden.jsonl - Codex rollout parser results and SignalStateStore sequences (codex/main.swift)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
out=/private/tmp/asb-windows-golden
mkdir -p "$out"
swiftc -O -module-cache-path "$out/cache" -o "$out/gen" "$here/main.swift" "$root"/Sources/AgentSignalLightCore/*.swift
"$out/gen" > "$here/lamp_golden.jsonl"
wc -l "$here/lamp_golden.jsonl"

mkdir -p "$out/codex"
cp "$here/codex/main.swift" "$out/codex/main.swift"
swiftc -O -module-cache-path "$out/cache" -o "$out/gen-codex" "$out/codex/main.swift" "$root"/Sources/AgentSignalLightCore/*.swift
rm -rf "$out/codex-state"
"$out/gen-codex" "$here/codex/lines.jsonl" "$out/codex-state" > "$here/codex_golden.jsonl"
wc -l "$here/codex_golden.jsonl"
