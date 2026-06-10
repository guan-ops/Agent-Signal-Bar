<h1 align="center">Agent Signal Bar</h1>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <strong>Local status lights for AI agents on macOS.</strong>
</p>

<p align="center">
  Customizable light effects · Multilingual UI · Local-first · Codex Desktop monitoring · Claude Code hooks
</p>

<p align="center">
  <a href="https://github.com/guan-ops/Agent-Signal-Bar/releases/latest"><img src="https://img.shields.io/badge/release-v1.3.0-111827.svg" alt="Latest release: v1.3.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111827.svg" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift 6.0">
  <a href="https://github.com/guan-ops/Agent-Signal-Bar/releases/latest"><img src="https://img.shields.io/badge/download-DMG-0ea5e9.svg" alt="Download DMG"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-635bff.svg" alt="License: Apache-2.0"></a>
  <a href="https://agentsignalbar.app"><img src="https://img.shields.io/badge/site-agentsignalbar.app-14b8a6.svg" alt="Website: agentsignalbar.app"></a>
</p>

<p align="center">
  <a href="https://agentsignalbar.app">
    <img src="docs/assets/readme-hero-en.svg?v=20260603-2320" alt="Agent Signal Bar website hero preview" width="100%">
  </a>
</p>

<table width="100%">
  <tr>
    <td align="center" width="18%"><strong>Layout</strong></td>
    <td align="center" width="41%"><strong>Minimal Dots</strong></td>
    <td align="center" width="41%"><strong>Classic Lamp</strong></td>
  </tr>
  <tr>
    <td align="center"><strong>Horizontal</strong></td>
    <td align="center"><img src="docs/assets/status-bar-minimal-dots.gif" alt="Agent Signal Bar Minimal Dots horizontal animated status bar preview" width="100%"></td>
    <td align="center"><img src="docs/assets/status-bar-classic-lamp.gif" alt="Agent Signal Bar Classic Lamp horizontal animated status bar preview" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><strong>Vertical</strong></td>
    <td align="center"><img src="docs/assets/status-bar-minimal-dots-vertical.gif" alt="Agent Signal Bar Minimal Dots vertical animated status bar preview" width="100%"></td>
    <td align="center"><img src="docs/assets/status-bar-classic-lamp-vertical.gif" alt="Agent Signal Bar Classic Lamp vertical animated status bar preview" width="100%"></td>
  </tr>
</table>

<p align="center">
  <em>All styles use the red/yellow/green sequence effect.</em>
</p>

Agent Signal Bar is a local-first macOS menu bar app that uses three red, yellow, and green signal lights to show the current state of local AI agents. It helps you see whether Codex, Claude Code, or a local script is idle, thinking, working, done, waiting for approval, or blocked without switching back to a terminal or editor.

## Download And Open

For normal use, download the app from [GitHub Releases](https://github.com/guan-ops/Agent-Signal-Bar/releases/latest), not from the green `Code` button. The `Code > Download ZIP` file is source code and does not contain a ready-to-open app installer.

1. Open the [latest release](https://github.com/guan-ops/Agent-Signal-Bar/releases/latest).
2. Download `AgentSignalBar.dmg`.
3. Open the DMG and drag `AgentSignalLight.app` to `Applications`.
4. Open Agent Signal Bar from `Applications`.

If macOS blocks the first launch because the build is not notarized yet, right-click the app and choose `Open`, or use `System Settings > Privacy & Security > Open Anyway`.

Developers can also download the source code and run `./script/build_and_run.sh`.

## Menu Bar Panel

<table>
  <tr>
    <td align="center"><strong>Detailed Panel</strong></td>
    <td align="center"><strong>Simple Menu</strong></td>
  </tr>
  <tr>
    <td><img src="docs/assets/menu-bar-panel-detailed-v1.2.2-en.png" alt="Agent Signal Bar detailed menu bar panel" width="360"></td>
    <td><img src="docs/assets/menu-bar-panel-simple-v1.2.2-en.png" alt="Agent Signal Bar simple native menu bar panel" width="360"></td>
  </tr>
</table>

Click the menu bar signal light to open either the detailed panel or the simple native-style menu. Both show the current status and live agent activity. The detailed panel keeps the quick actions focused on pausing monitoring, opening settings, and quitting; the simple menu can also show open-agent shortcuts when relevant.

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
- Menu bar panel with current status, running agents, recent activity, pause/settings actions, and quit.
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
  <img src="docs/assets/light-effects-landscape-en.gif" alt="Agent Signal Bar light effect preview" width="900">
</p>

## Aggregation Priority

When multiple agents or sessions are active, the menu bar shows the highest-priority state:

```text
paused > blocked > permission > needs_review > stale > active > completed > ready
```

Red states are never overwritten by normal work. Yellow attention states are also protected from newer working events. `done` is visible for 30 seconds by default, then returns to idle.

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
export AGENT_SIGNAL_LIGHT_EVENT_LIMIT=50
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

## License

Source code is licensed under the [Apache License 2.0](LICENSE). Attribution is recorded in [NOTICE](NOTICE).

© 2026 XiongYang Guan ([guan-ops](https://github.com/guan-ops))
