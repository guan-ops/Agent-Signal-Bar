#!/bin/sh
# Regenerates lamp_golden.jsonl from the Swift AgentSignalLightCore sources (macOS only).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
out=/private/tmp/asb-windows-golden
mkdir -p "$out"
swiftc -O -module-cache-path "$out/cache" -o "$out/gen" "$here/main.swift" "$root"/Sources/AgentSignalLightCore/*.swift
"$out/gen" > "$here/lamp_golden.jsonl"
wc -l "$here/lamp_golden.jsonl"
