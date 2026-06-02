<h1 align="center">Agent Signal Bar</h1>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/assets/app-icon.png" alt="Agent Signal Bar app icon" width="104">
</p>

<p align="center">
  <strong>Local status lights for AI agents on macOS.</strong>
</p>

<p align="center">
  Customizable light effects · Multilingual UI · Local-first · Codex Desktop monitoring · Claude Code hooks
</p>

<table>
  <tr>
    <td align="center"><strong>Minimal Dots</strong></td>
    <td align="center"><strong>Classic Lamp</strong></td>
  </tr>
  <tr>
    <td><img src="docs/assets/status-bar-minimal-dots.gif" alt="Agent Signal Bar Minimal Dots real macOS menu bar recording converted to GIF" width="360"></td>
    <td><img src="docs/assets/status-bar-classic-lamp.gif" alt="Agent Signal Bar Classic Lamp real macOS menu bar recording converted to GIF" width="360"></td>
  </tr>
</table>

<p align="center">
  <em>Real macOS menu bar recordings converted to GIF. Both styles use the red/yellow/green sequence effect.</em>
</p>

Agent Signal Bar is a local-first macOS menu bar app that uses three red, yellow, and green signal lights to show the current state of local AI agents. It helps you see whether Codex, Claude Code, or a local script is idle, thinking, working, done, waiting for approval, or blocked without switching back to a terminal or editor.

## Download And Open

For normal use, download the app from [GitHub Releases](https://github.com/guan-ops/Agent-Signal-Bar/releases/latest), not from the green `Code` button. The `Code > Download ZIP` file is source code and does not contain a ready-to-open app installer.

1. Open the [latest release](https://github.com/guan-ops/Agent-Signal-Bar/releases/latest).
2. Download `AgentSignalLight-local.dmg`.
3. Open the DMG and drag `AgentSignalLight.app` to `Applications`.
4. Open Agent Signal Bar from `Applications`.

If macOS blocks the first launch because the build is not notarized yet, right-click the app and choose `Open`, or use `System Settings > Privacy & Security > Open Anyway`.

Developers can also download the source code and run `./script/build_and_run.sh`.

## Menu Bar Panel

<p align="center">
  <img src="docs/assets/menu-bar-panel-en.png" alt="Agent Signal Bar menu bar panel" width="560">
</p>

Click the menu bar signal light to open a compact panel with the current status, running agents, the latest event, and quick actions for opening agents, clearing alerts, pausing monitoring, opening settings, and quitting.

## Settings Liquid Glass Comparison

<table>
  <tr>
    <td align="center"><strong>Without Liquid Glass</strong></td>
    <td align="center"><strong>Default Liquid Glass</strong></td>
  </tr>
  <tr>
    <td><img src="docs/assets/settings-solid-en.png" alt="Agent Signal Bar settings window Activity page without Liquid Glass" width="420"></td>
    <td><img src="docs/assets/settings-liquid-glass-default-en.png" alt="Agent Signal Bar settings window Activity page with the default standard Liquid Glass effect" width="420"></td>
  </tr>
</table>

Both images are real screenshots of the current Activity page. The left image shows the normal solid settings window, while the right image shows the default Standard Liquid Glass style with the desktop background participating in the window material. Liquid Glass is on by default and can be adjusted between Standard and Enhanced in `General > Liquid glass`.

## Features

- macOS menu bar signal light with horizontal and vertical layouts.
- Two visual styles: classic signal board and minimal dots.
- Menu bar panel with current status, running agents, latest event, quick actions, and quit.
- Settings window with Activity, General, Connections, Advanced, and About pages.
- Codex Desktop activity monitoring without required hooks, plus optional Codex hooks, Claude Code hooks, and generic JSON event input.
- Multi-session aggregation so permission, failure, and blocked states are not overwritten by normal working states.
- Local CLI for scripts, automation, and custom agents.
- Multilingual UI with system-language detection and manual language switching.
- Customizable light effects, including blink speed, breathing strength, and per-state effect choices.
- Theme selection and launch at login.
- No cloud service is required. State files, hooks, and diagnostics stay on your Mac.

## Signal Language

| Agent state | Default effect | Meaning |
| --- | --- | --- |
| Idle `idle` | steady green | Nothing needs attention |
| Thinking `thinking` | fast green flash | The agent is reasoning about the task |
| Working `working` | slow green flash | The agent is editing files, running tools, or testing |
| Step done `tool_done` | slow green flash | One step finished and the workflow may continue |
| Done `done` | steady green | The task is complete and will return to idle shortly |
| Attention `attention` / `notification` | flashing yellow | Check when convenient |
| Permission `permission` / `permission_request` | flashing red | Approval is needed now |
| Blocked `blocked` / `failure` / `error` | fast flashing red | Immediate action is needed |
| Stale `stale` | gray/yellow warning | The state file is old, damaged, or untrusted |
| Off `off` / `pause` | all lights off or static gray | Monitoring is paused |

Default effect settings:

- Thinking: fast green flash
- Working: slow green flash
- Done: steady green

Effects can be customized in the Advanced page of the settings window.

## Light Effect Preview

<p align="center">
  <img src="docs/assets/light-effects-en.gif" alt="Agent Signal Bar animated light effect preview rendered from the real status bar icon renderer" width="720">
</p>

This animated effect preview is rendered from the same status bar icon renderer used by the app, with both the classic signal board and minimal dot styles shown for each effect.

## Aggregation Priority

When multiple agents or sessions are active, the menu bar shows the highest-priority state:

```text
paused > blocked > permission > needs_review > stale > active > completed > ready
```

Red states are never overwritten by normal work. Yellow attention states are also protected from newer working events. `done` is visible for 90 seconds by default, then returns to idle.

## Quick Start

Build and run:

```bash
./script/build_and_run.sh
```

Verify the app:

```bash
./script/build_and_run.sh --verify
```

Open the settings window for UI verification:

```bash
./script/build_and_run.sh --ui-verify
```

Run local diagnostics:

```bash
./script/doctor.sh
./script/doctor.sh --full
```

Package the app:

```bash
./script/package_app.sh --release
```

Build local zip and DMG artifacts:

```bash
./script/package_release.sh
```

## CLI

Install the CLI:

```bash
./script/install_cli.sh
```

Update state:

```bash
./scripts/agent-signal idle
./scripts/agent-signal thinking --session codex-main --agent codex
./scripts/agent-signal working --session codex-main --agent codex --event PreToolUse
./scripts/agent-signal permission --session claude-main --agent claude-code --event PermissionRequest
./scripts/agent-signal blocked --session job-1 --agent script --event Failed
./scripts/agent-signal done --session codex-main --agent codex --event Stop
```

Read state:

```bash
./scripts/agent-signal status
./scripts/agent-signal status --json
```

Clear warnings:

```bash
./scripts/agent-signal clear-warning
```

Reset to idle:

```bash
./scripts/agent-signal reset
```

Wrap any command as an agent run:

```bash
./scripts/agent-signal-run \
  --session nightly-build \
  --agent script \
  -- ./run-build.sh
```

## Agent Integration

Codex Desktop can work without manually installing hooks. Keep `Monitor Codex Desktop` enabled in the app and Agent Signal Bar will read local Codex session logs to detect thinking, working, step-done, and done states. Hooks are optional for Codex Desktop, but they are still useful for Codex CLI/TUI, Codex IDE compatibility, project-scoped automation, Claude Code, and other local agents that report events directly.

Codex Desktop activity comes from the local Codex session log. Normal browser usage does not trigger Agent Signal Bar unless it is part of an active Codex task that is using tools.

Integration verification status:

- Codex has been tested in real use and is fully verified.
- Claude Code hook support is implemented, but it has not yet been verified with a live Claude Code workflow.

Install hooks when you need CLI/IDE or Claude Code integration:

```bash
./script/install_hooks.py --target all --codex-scope project --dry-run
./script/install_hooks.py --target all --codex-scope project --install
```

For development, project-scoped Codex hooks are recommended so project-level and user-level hooks do not fire at the same time.

Generic JSON input:

```bash
echo '{"event":"AgentStarted","agent":"local-script","session_id":"local-main"}' \
  | ./scripts/generic-agent-signal-hook

echo '{"event":"ApprovalRequired","agent":"local-script","session_id":"local-main"}' \
  | ./scripts/generic-agent-signal-hook
```

## State File

Default state file:

```text
/tmp/agent-signal/status.json
```

Example:

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

Environment variables:

```bash
export AGENT_SIGNAL_LIGHT_STATE_FILE=/path/to/status.json
export AGENT_SIGNAL_LIGHT_STATE_DIR=/tmp/agent-signal
export AGENT_SIGNAL_LIGHT_EVENT_LIMIT=30
export AGENT_SIGNAL_LIGHT_COMPLETED_TTL_SECONDS=90
export SIGNAL_LIGHT_SESSION_TTL_SECONDS=1800
```

## Project Layout

```text
Sources/
  AgentSignalLight/        macOS app, menu bar, settings window
  AgentSignalLightCore/    state model, aggregation, hook mapping
  AgentSignalLightUI/      signal rendering and icon geometry
  AgentSignalCLI/          agent-signal CLI
scripts/                   CLI wrappers and hook wrappers
script/                    build, install, diagnostics, packaging scripts
docs/                      integration docs, state schema, release checklist
Tests/                     Swift tests
```

## Documentation

- [Signal language](docs/LAMP_LANGUAGE.md)
- [State schema](docs/STATE_SCHEMA.md)
- [Codex setup](docs/CODEX_SETUP.md)
- [Claude Code setup](docs/CLAUDE_CODE_SETUP.md)
- [Local script setup](docs/LOCAL_SCRIPT_SETUP.md)
- [GitHub release management](docs/GITHUB_RELEASES.md)
- [Release checklist](docs/RELEASE_CHECKLIST.md)
- [Changelog](CHANGELOG.md)

## Developer

Hemi Guan
