"""List macOS UI strings that the QML pages do not have yet.

    python3 -I Integrations/Windows/tests/parity_strings.py

Reads the Swift sources and QML of this checkout and writes parity-missing.txt and
parity-qml-only.txt to <temp>/asb-parity.
"""
import glob
import os
import re
import tempfile
from collections import Counter

# Paths come from this file's location, never from the command line.
root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
out = os.path.join(tempfile.gettempdir(), "asb-parity")
os.makedirs(out, exist_ok=True)
pat = re.compile(r'text\(\s*"([^"\\]*)"\s*,\s*"')
swift_files = [
    "Views/DebugWindowView.swift", "Views/MenuBarPanelView.swift", "Views/MenuUsageSummaryView.swift",
    "Services/FloatingSignalWindowController.swift", "Services/StatusBarController.swift",
    "Views/UsageSettingsComponents.swift", "Views/CodexUsageDetailsView.swift",
    "Views/ClaudeUsageSettingsView.swift", "Views/CostCurrencySettingsView.swift",
]
swift = {}
for rel in swift_files:
    text = open(os.path.join(root, "Sources/AgentSignalLight", rel), encoding="utf-8").read()
    for m in pat.finditer(text):
        swift.setdefault(m.group(1), set()).add(os.path.basename(rel))
qml = set()
for f in glob.glob(os.path.join(root, "Integrations/Windows/qml/*")):
    qml |= set(re.findall(r't\(\s*"([^"]*)"', open(f, encoding="utf-8").read()))
missing = {k: v for k, v in swift.items() if k not in qml}
extra = sorted(k for k in qml if k not in swift)
print("swift strings", len(swift), "qml strings", len(qml), "missing", len(missing), "qml-only", len(extra))
print(Counter(f for v in missing.values() for f in v))
with open(os.path.join(out, "parity-missing.txt"), "w", encoding="utf-8") as fh:
    for k, v in sorted(missing.items(), key=lambda kv: sorted(kv[1])):
        fh.write(f"{k}\t{','.join(sorted(v))}\n")
with open(os.path.join(out, "parity-qml-only.txt"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(extra))
print("written to", out)
