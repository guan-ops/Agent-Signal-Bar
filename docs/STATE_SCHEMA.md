# State Schema

Agent Signal Bar 默认读取和写入：

```text
/tmp/agent-signal/status.json
```

当前 schema 版本是 `1`。缺失 `events` 或 `schema_version` 的旧文件仍可读取；新写出的文件会补齐这些字段。

## Document

```json
{
  "schema_version": 1,
  "aggregate": "working",
  "updated_at": "2026-05-28T03:45:00Z",
  "sessions": {
    "codex-main": {
      "agent": "codex",
      "signal": "working",
      "last_event": "PreToolUse",
      "updated_at": "2026-05-28T03:45:00Z"
    }
  },
  "events": [
    {
      "id": "D4204E0A-5B5D-4DFB-A3BC-643E6C7C6F8F",
      "session_id": "codex-main",
      "agent": "codex",
      "signal": "working",
      "event": "PreToolUse",
      "updated_at": "2026-05-28T03:45:00Z"
    }
  ]
}
```

## Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `schema_version` | yes | Schema version. Current value is `1`. |
| `aggregate` | yes | Current aggregate signal shown by the menu bar. |
| `updated_at` | yes | ISO-8601 document update time. |
| `sessions` | yes | Map of session id to latest session state. |
| `events` | yes | Recent event history, newest displayed first by the app. |

Session fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `agent` | no | Agent source, such as `codex`, `claude-code`, `local-script`, or `script`. |
| `signal` | yes | One of the supported signal names. |
| `last_event` | no | Last source event that produced the signal. |
| `updated_at` | yes | ISO-8601 session update time. |

Bare CLI signal commands that do not pass `--session` are stored as session id `manual` with agent `manual` and event `ManualSet`. This keeps manual testing and menu buttons inside the same aggregation model as Codex, Claude Code, and local scripts. Manual `idle` / `reset` clears sessions instead of leaving a stale manual session behind.

Event fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Event UUID. |
| `session_id` | yes | Session that produced the event. |
| `agent` | no | Agent source. |
| `signal` | yes | Signal written by the event. |
| `event` | no | Source event name. |
| `updated_at` | yes | ISO-8601 event time. |

## Environment

```bash
export AGENT_SIGNAL_LIGHT_STATE_FILE=/path/to/status.json
export AGENT_SIGNAL_LIGHT_STATE_DIR=/tmp/agent-signal
export AGENT_SIGNAL_LIGHT_EVENT_LIMIT=30
export AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS=90
export SIGNAL_LIGHT_SESSION_TTL_SECONDS=1800
```

If the JSON is missing, the app falls back to `ready` / `idle`. If the JSON is damaged or cannot be decoded, the app shows `stale` so the menu bar does not imply a trustworthy idle state. Unknown signal names are not accepted by the CLI.

`aggregate` is a fallback when there are no active sessions. A stale or paused aggregate does not lock the state forever; once a new non-paused session is written, the aggregate is recomputed from sessions.

Completed sessions use a shorter TTL than normal sessions. By default `done` stays visible for 90 seconds, then the runtime prunes that completed session and returns to `idle` / `ready` instead of `stale`. Snapshot reads persist TTL pruning back into the JSON so direct file readers, the CLI, and the menu bar converge on the same aggregate. When pruning changes the aggregate, `updated_at` is refreshed to the prune time so the menu and CLI do not show the old event time as the current status update time.

## CLI Status Output

`agent-signal status --json` prints a machine-readable snapshot. Commands that update state, such as `agent-signal working --session job --json`, can also use the same output format.

`display_state` is the v2 menu-bar state: `ready`, `active`, `completed`, `needs_review`, `permission`, `blocked`, `stale`, or `paused`. `lamp_state` is kept for compatibility and currently has the same value.

```json
{
  "schema_version": 1,
  "aggregate": "working",
  "display_state": "active",
  "lamp_state": "active",
  "priority": 50,
  "display_name": "工作中",
  "summary": "Agent 正在读写文件、跑工具或测试。",
  "action": "不用处理",
  "state_file": "/tmp/agent-signal/status.json",
  "updated_at": "2026-05-28T03:45:00Z",
  "sessions": [
    {
      "session_id": "codex-main",
      "agent": "codex",
      "signal": "working",
      "last_event": "PreToolUse",
      "updated_at": "2026-05-28T03:45:00Z"
    }
  ],
  "recent_events": [
    {
      "id": "D4204E0A-5B5D-4DFB-A3BC-643E6C7C6F8F",
      "session_id": "codex-main",
      "agent": "codex",
      "signal": "working",
      "event": "PreToolUse",
      "updated_at": "2026-05-28T03:45:00Z"
    }
  ]
}
```
