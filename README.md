<h1 align="center">Agent Signal Bar 🚦</h1>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <strong>Know when your AI agent is working, finished, blocked, or waiting for you—without switching back to the terminal.</strong>
</p>

<p align="center">
  Codex auto-monitoring · Claude Code hooks · Custom agents · Local-first
</p>

<p align="center">
  <a href="https://github.com/guan-ops/Agent-Signal-Bar/releases/latest"><img src="https://img.shields.io/github/v/release/guan-ops/Agent-Signal-Bar?style=flat-square&amp;color=111827" alt="Latest release"></a>
  <a href="https://github.com/guan-ops/Agent-Signal-Bar/releases/latest"><img src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square" alt="macOS 14+"></a>
  <a href="https://github.com/guan-ops/Agent-Signal-Bar/releases/latest"><img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-0ea5e9?style=flat-square" alt="Universal for Apple Silicon and Intel Macs"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-635bff?style=flat-square" alt="License: Apache-2.0"></a>
  <a href="https://agentsignalbar.app"><img src="https://img.shields.io/badge/site-agentsignalbar.app-14b8a6?style=flat-square" alt="Website: agentsignalbar.app"></a>
</p>

<p align="center">
  <a href="https://agentsignalbar.app">
    <img src="docs/assets/readme-hero-en.svg?v=20260805-1" alt="Agent Signal Bar shows local AI-agent activity through menu bar traffic lights" width="100%">
  </a>
</p>

<p align="center">
  <a href="https://github.com/guan-ops/Agent-Signal-Bar/releases/latest/download/AgentSignalBar.dmg"><strong>Download the latest DMG</strong></a>
  · <a href="https://agentsignalbar.app">Website</a>
  · <a href="CHANGELOG.md">Changelog</a>
</p>

Agent Signal Bar turns local AI-agent activity into a simple traffic-light language in your macOS menu bar and an optional floating desktop signal. It automatically detects Codex activity across Desktop, CLI/TUI, VS Code, Xcode, and IDEA from known local session logs. Optional hooks add permission and low-latency events, while Claude Code, scripts, and custom agents can report through local hooks, the bundled CLI, or JSON events.

## Why Agent Signal Bar

- **Stay in flow.** See whether an agent is thinking, working, or done without reopening its terminal or editor.
- **Know when to act.** Permission and failure states take priority, so normal activity cannot hide a red alert.
- **Keep status visible.** Use the compact menu bar signal, the draggable desktop signal, or both.
- **Keep control local.** Core activity monitoring uses known local logs and state files; no Agent Signal Bar account or backend is required.

## Install

### Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel Mac

### Download and first run

1. Download [`AgentSignalBar.dmg`](https://github.com/guan-ops/Agent-Signal-Bar/releases/latest/download/AgentSignalBar.dmg) from the latest GitHub Release.
2. Open the DMG and drag `AgentSignalLight.app` into `Applications`.
3. Open Agent Signal Bar from `Applications`.

> [!NOTE]
> Current GitHub builds are ad-hoc signed and not notarized. If Gatekeeper blocks the first launch, right-click the app and choose **Open**, or use **System Settings → Privacy & Security → Open Anyway**.

The green **Code → Download ZIP** button downloads source code, not an app installer. After installation, use **Agent Signal Bar → Check for Updates…** or **Settings → About → Updates** for Sparkle updates.

## See it in action

<table width="100%">
  <tr>
    <td align="center" width="26%"><strong>Floating signal</strong></td>
    <td align="center" width="37%"><strong>Detailed menu</strong></td>
    <td align="center" width="37%"><strong>Simple menu</strong></td>
  </tr>
  <tr>
    <td align="center"><a href="docs/assets/floating-signal-light.png?v=20260908-1"><img src="docs/assets/floating-signal-light.png?v=20260908-1" alt="Floating Agent Signal Bar light with quota, active-agent, and token badges" width="180"></a></td>
    <td align="center"><a href="docs/assets/menu-bar-panel-detailed-en.png?v=20260908-1"><img src="docs/assets/menu-bar-panel-detailed-en.png?v=20260908-1" alt="Detailed Agent Signal Bar menu with a demo Codex account, quota, and token history" width="100%"></a></td>
    <td align="center"><a href="docs/assets/menu-bar-simple-en.png?v=20260908-1"><img src="docs/assets/menu-bar-simple-en.png?v=20260908-1" alt="Simple Agent Signal Bar menu with demo Codex quota, token history, and quick actions" width="100%"></a></td>
  </tr>
</table>

These are captures of the v1.6.0 app UI with synthetic demo data. Screenshots use Dark appearance; settings use Liquid Glass with the Standard effect. The floating signal stays above your desktop, follows the menu bar state, and supports dragging, free resizing, size presets, horizontal or vertical layouts, and compact session and usage popovers.

### Activity and usage

<table width="100%">
  <tr>
    <td align="center" width="50%"><strong>Activity</strong></td>
    <td align="center" width="50%"><strong>Usage</strong></td>
  </tr>
  <tr>
    <td align="center"><a href="docs/assets/settings-activity-en.png?v=20260908-1"><img src="docs/assets/settings-activity-en.png?v=20260908-1" alt="Agent Signal Bar Activity page showing a demo Codex CLI session and recent events" width="100%"></a></td>
    <td align="center"><a href="docs/assets/settings-usage-en.png?v=20260908-1"><img src="docs/assets/settings-usage-en.png?v=20260908-1" alt="Agent Signal Bar Usage page showing Codex quota, reset credits, and model token counts, estimated costs, and shares" width="100%"></a></td>
  </tr>
</table>

All account, activity, quota, and token values shown are synthetic. The demo email is `demo@agentsignalbar.app`. The Usage capture shows the hovered day with GPT-6 Astra and gpt-5.6 token counts, estimated costs, and shares. No personal account or credential data is included. Claude-specific captures are omitted pending real-account validation.

### Choose your look

<table width="100%">
  <tr>
    <td align="center" width="50%"><strong>Minimal Dots</strong></td>
    <td align="center" width="50%"><strong>Classic Lamp</strong></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/assets/status-bar-minimal-dots.gif" alt="Minimal Dots status light animation" width="100%"></td>
    <td align="center"><img src="docs/assets/status-bar-classic-lamp.gif" alt="Classic Lamp status light animation" width="100%"></td>
  </tr>
</table>

Both styles support horizontal and vertical layouts. You can also tune blink speed, breathing strength, per-state effects, color theme, Liquid Glass appearance, and completion or warning sounds—including the bundled New Zealand crossing sounds.

## What you get

- **Menu bar and desktop signals** with synchronized red, yellow, and green animations.
- **Attention-first multi-session aggregation** that protects permission, blocked, failure, and review states from ordinary work events.
- **Current Codex model estimates** for GPT-6 Astra/Sol/Luna and GPT-5.6, with distinct chart colors, Standard/Fast attribution, and per-request long-context pricing. See [model prices and estimation limits](docs/CODEX_MODEL_PRICING.md).
- **Codex monitoring without required hooks** across Desktop, CLI/TUI, VS Code, Xcode, and IDEA, plus session, quota, token, and cost views.
- **Saved Codex accounts** with account-bound credentials, quota snapshots, and reset-credit data.
- **Detailed and native-style menu panels** with live sessions, recent activity, pause, settings, and relevant app shortcuts.
- **Local extension points** through Codex hooks, Claude Code hooks, a generic JSON adapter, and the `agent-signal` CLI.
- **Desktop-friendly customization** with two visual styles, size presets, free resizing, sound profiles, themes, launch at login, and multilingual UI.

## Signal language

| Agent state | Default effect | What it means |
| --- | --- | --- |
| Idle `idle` | steady green | Nothing needs attention |
| Thinking `thinking` | fast green flash | The agent is reasoning about the task |
| Working `working` | slow green flash | The agent is editing, running tools, or testing |
| Step done `tool_done` | slow green flash | One step finished; the workflow may continue |
| Done `done` | steady green | The task finished and will soon return to idle |
| Attention `attention` / `notification` | flashing yellow | Check when convenient |
| Permission `permission` / `permission_request` | flashing red | Your approval is needed now |
| Blocked `blocked` / `failure` / `error` | fast flashing red | Immediate action is needed |
| Stale `stale` | gray/yellow warning | The local state is old, damaged, or untrusted |
| Off `off` / `pause` | off or static gray | Monitoring is paused |

Red and yellow states are protected from newer ordinary-work events. See the full [signal language and aggregation rules](docs/LAMP_LANGUAGE.md).

## Integrations

| Source | Connection | Current support |
| --- | --- | --- |
| Codex Desktop, CLI/TUI, VS Code, Xcode, and IDEA | Known local Codex session logs; optional hooks | Hook-free activity monitoring is verified; hooks add permission and low-latency events |
| Claude Code | Claude Code hooks | Not tested on a physical machine |
| Local scripts and custom agents | Bundled CLI or generic JSON events | Supported through the shared local state model |

Start with the [Codex setup](docs/CODEX_SETUP.md), [Claude Code setup](docs/CLAUDE_CODE_SETUP.md), or [local script setup](docs/LOCAL_SCRIPT_SETUP.md).

## Privacy and network access

Choose **General → Cost display currency** to display local Codex and Claude cost estimates in one of 17 currencies, including USD, CNY and NZD. [ExchangeRate-API](https://www.exchangerate-api.com) provides daily reference rates; the rate date is shown beside converted estimates. Today’s and historical costs use the same latest available rate. Offline conversion uses the dated cache, or retains USD if no rate is available. Original usage records remain in USD; account extra usage keeps its billing currency.

Agent Signal Bar is local-first, but it is not described as fully offline:

- Agent activity is detected from known local Codex logs or local hook, CLI, and JSON state.
- State snapshots, hook events, cost-scan caches, and exported diagnostics remain on your Mac unless you choose to share them.
- Optional Codex account and quota features connect directly to OpenAI and can use local Codex credentials or optional `chatgpt.com` browser-session data. Saved account credentials and manually entered cookies use macOS Keychain storage.
- Service-status and update checks contact OpenAI Status and GitHub/Sparkle respectively.
- Selecting a non-USD cost currency fetches public daily rates from `open.er-api.com`. This request contains no account credentials or usage records.
- No Agent Signal Bar backend account or project-hosted cloud service is required.

## CLI and custom agents

Install the bundled CLI wrappers:

```bash
./script/install_cli.sh
```

Publish and inspect state:

```bash
./scripts/agent-signal working --session build-1 --agent script --event BuildStarted
./scripts/agent-signal done --session build-1 --agent script --event BuildFinished
./scripts/agent-signal status --json
```

Wrap any command as an agent run:

```bash
./scripts/agent-signal-run --session nightly-build --agent script -- ./run-build.sh
```

The event contract and environment variables are documented in the [state schema](docs/STATE_SCHEMA.md).

## Build from source

Requires macOS 14+, Swift 6, and the full Xcode toolchain.

```bash
./script/build_and_run.sh --verify
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./script/doctor.sh
```

Release packaging and Sparkle-feed details live in [GitHub release management](docs/GITHUB_RELEASES.md) and the [release checklist](docs/RELEASE_CHECKLIST.md).

## Contributing

Issues and focused pull requests are welcome.

1. Open an [issue](https://github.com/guan-ops/Agent-Signal-Bar/issues) for bugs or behavior changes that need discussion.
2. Keep changes scoped and preserve the local-first data boundary.
3. Run the build verification and Swift tests above before opening a pull request.

For questions and product ideas, use [GitHub Discussions](https://github.com/guan-ops/Agent-Signal-Bar/discussions).

## Documentation

- [Signal language](docs/LAMP_LANGUAGE.md) · [State schema](docs/STATE_SCHEMA.md)
- [Codex setup](docs/CODEX_SETUP.md) · [Claude Code setup](docs/CLAUDE_CODE_SETUP.md) · [Local scripts](docs/LOCAL_SCRIPT_SETUP.md)
- [Changelog](CHANGELOG.md) · [GitHub releases](docs/GITHUB_RELEASES.md) · [Release checklist](docs/RELEASE_CHECKLIST.md)

## Credits and license

Agent Signal Bar is built by XiongYang Guan ([guan-ops](https://github.com/guan-ops)). The bundled New Zealand crossing sounds were recorded for this project.

Token-usage JSONL scanning is adapted from [CodexBar](https://github.com/steipete/CodexBar), created by Peter Steinberger and licensed under the MIT License. Full attribution is recorded in [NOTICE](NOTICE).

Source code is licensed under the [Apache License 2.0](LICENSE). Non-code assets use the terms in [ASSET_LICENSES.md](ASSET_LICENSES.md), and the project name and brand assets are covered by [TRADEMARKS.md](TRADEMARKS.md).
