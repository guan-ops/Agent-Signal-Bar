"""Write synthetic Codex rollout files with timestamps relative to now.

    python3 -I Integrations/Windows/tests/make_live_fixture.py
    AgentSignalBar --codex-dir <fixture> --capture <out>   (or --probe 5)

<fixture> is /tmp/asb-live-fixture (on Windows, asb-live-fixture in the temp
folder); the script prints its sessions folder. The folder is fixed on purpose:
its sessions folder is deleted first, so no path is taken from the command line.

Three sessions: a CLI turn running a tool, a VS Code turn waiting for escalated
permission, and a Desktop turn that just finished. All content is made up.
"""
import json
import os
import shutil
import tempfile
from datetime import datetime, timedelta, timezone

home = os.path.join("/tmp" if os.name == "posix" else tempfile.gettempdir(), "asb-live-fixture")
sessions = os.path.join(home, "sessions")
shutil.rmtree(sessions, ignore_errors=True)
now = datetime.now(timezone.utc)


def ts(seconds_ago):
    return (now - timedelta(seconds=seconds_ago)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def write(name, session_id, source, originator, events):
    day = os.path.join(sessions, now.strftime("%Y"), now.strftime("%m"), now.strftime("%d"))
    os.makedirs(day, exist_ok=True)
    rows = [{"timestamp": ts(600), "type": "session_meta",
             "payload": {"id": session_id, "source": source, "originator": originator, "cwd": "/tmp/fixture"}}]
    for seconds_ago, kind, payload in events:
        rows.append({"timestamp": ts(seconds_ago), "type": kind, "payload": payload})
    with open(os.path.join(day, f"rollout-{now:%Y-%m-%dT%H-%M-%S}-{name}-{session_id}.jsonl"), "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")


write("cli", "0199a1b2-0000-7000-8000-00000000c011", "exec", "codex_cli_rs", [
    (90, "event_msg", {"type": "task_started"}),
    (80, "response_item", {"type": "reasoning"}),
    (60, "response_item", {"type": "function_call", "name": "shell", "arguments": "{\"command\":[\"make\",\"test\"]}"}),
])
write("vscode", "0199a1b2-0000-7000-8000-0000000005c0", "vscode", "codex_vscode", [
    (50, "event_msg", {"type": "task_started"}),
    (20, "response_item", {"type": "function_call", "name": "shell",
                           "arguments": "{\"command\":[\"rm\",\"build\"],\"sandbox_permissions\":\"require_escalated\"}"}),
])
write("desktop", "0199a1b2-0000-7000-8000-0000000de5c0", "vscode", "Codex Desktop", [
    (40, "event_msg", {"type": "task_started"}),
    (30, "response_item", {"type": "function_call", "name": "apply_patch", "arguments": "{}"}),
    (25, "response_item", {"type": "function_call_output", "output": "ok"}),
    (8, "event_msg", {"type": "task_complete"}),
])
print(sessions)
