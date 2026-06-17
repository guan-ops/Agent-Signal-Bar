# Agent Signal Bar Release Checklist

Use this checklist before treating a build as ready for daily use or local sharing.

## Local Acceptance

- Run `./script/verify_release_all.sh`.
- Before handing off a build that should be visually smoke-tested, run `./script/verify_release_all.sh --skip-package --ui`.
- For final verification on this Mac after hooks, login item, and the app process are intentionally configured, run `./script/verify_release_all.sh --skip-package --ui --strict-doctor`.
- For a faster non-UI re-check after artifacts already exist, run `./script/verify_release_all.sh --skip-package`.

The all-in-one release gate replaces the old manual command chain. It packages release artifacts unless `--skip-package` is used, then verifies:

- shell scripts parse
- Swift tests pass
- release checksums match
- Sparkle `appcast.xml` exists and is included in release checksums
- `./scripts/agent-signal status --json` parses
- release zip extracts, contains the expected app/scripts/docs/previews, and installs without rebuilding
- release DMG verifies, mounts, copies to a temporary Applications directory, and preserves code signing
- bundled CLI wrappers preserve red priority
- bundled `agent-signal-run` preserves failed command exit codes and marks blocked
- local script integration verifier passes direct local-script signals, wrapped command success/failure, exit-code preservation, and red priority preservation
- bundled diagnostics exporter writes a real archive
- uninstall removes the app, launch-agent plist, Agent Signal Bar hooks, and configured state directory while preserving unrelated hooks
- `doctor --full` passes core checks, app build, test suite, lamp-language rendering, preview generation, diagnostics, hook mapping, wrapper behavior, install paths, manifest consistency, DMG layout, and release metadata checks
- when `--ui` is used, the settings window appears on screen, normal menu bar launch is restored, and the app writes a status item health report proving `NSStatusItem`, button, image, action, tooltip, and positive status item length all exist

`--strict-doctor` makes `doctor` warnings fail the gate. Use it for final local setup validation. Without `--strict-doctor`, warnings remain visible but do not fail the gate, which is useful when login startup or local hooks are intentionally not configured.

## UI Smoke Test

- Launch with `./script/build_and_run.sh --ui-verify`.
- Confirm `./script/build_and_run.sh --ui-verify` exits successfully; the script now checks for a real on-screen `Agent Signal Bar` settings window.
- Run `./script/build_and_run.sh --status-item-verify`; it should exit successfully after proving the status bar item exists and has an image/action/tooltip.
- Open `dist/status-icon-preview/status-icon-preview.png` and use it as the static reference for the status bar icon matrix.
- Confirm `显示状态栏信号` creates a menu bar icon.
- Confirm turning `显示状态栏信号` off removes the menu bar icon.
- Turn `显示状态栏信号` off; the settings window should open immediately so the app is recoverable.
- Close that settings window while `显示状态栏信号` is still off; the app should exit instead of running invisibly.
- Relaunch once with `显示状态栏信号` off; the settings window should open automatically.
- Open `高级`; confirm light-effect customization exposes active effect, active speed, alert flash speed, done effect, and breathing strength.
- Trigger real or CLI-driven `thinking`, `working`, `permission`, `blocked`, and `done` signals; confirm the status bar animation follows the current customization and returns to the live session state afterward.
- Confirm pause/resume monitoring plays the configured pause/resume light transitions and then returns to the correct live state.
- Confirm the menu shows the current version/build and release state such as `Local / not notarized`.
- Open `运行`, confirm it shows the current aggregate status, monitoring state, active sessions, and recent events without exposing raw JSON; the summary signal should be one pure-color lamp only, independent of the selected status bar style, while keeping the same status color and flashing/breathing timing.
- Open `通用`, confirm language is a dropdown menu, the status bar controls are in this same page, and switch between `跟随系统`, `简体中文`, `English`, and one additional language; the settings window and menu bar panel should update immediately.
- Open `连接` and click `版本`; Finder should select `dist/AgentSignalBar-release-manifest.json` when a release manifest is present, or the bundled `AgentSignalLight-release-info.json` after DMG installation.
- Set `圆点横向尺寸` to `默认` while the style is `极简圆点` and direction is `横向`; confirm the icon becomes the same footprint as horizontal `经典灯牌` while keeping transparent white-ring styling.
- Set `灯牌竖向尺寸` to `大` while the style is `经典灯牌` and direction is `竖向`; confirm the icon stays compact but no longer collapses into a tiny column, and still keeps the black lamp housing.
- Check both styles:
  - `经典灯牌`
  - `极简圆点`
- Check both directions:
  - `横向`
  - `竖向`
- Confirm the menu or settings window updates for:
  - `空闲`
  - `工作中` green active only, with no red or yellow light
  - `需要查看`
  - `已完成` green completed, not yellow; after the completed TTL it should return to `空闲`
  - `请求授权`
  - `阻塞`
  - `关闭灯` gray paused, not all black/off
- Use `./scripts/agent-signal stale --session smoke --agent script --event StaleCheck` and confirm stale uses the gray/yellow stale display.
- Open `连接`, click `导出诊断`, confirm Finder selects a new zip under `dist/diagnostics/`, and confirm the settings window shows the archive path.
- Open `关于`, click `检查更新`, and confirm the Sparkle update UI opens or reports the current build correctly. Confirm the `自动检查更新` switch maps to Sparkle rather than the legacy GitHub notification checker.

## Hook Smoke Test

- In the app, open `连接` and click `检查连接`; it should report the current project `.codex/hooks.json` and Claude Code as already configured after installation. User-level Codex hooks are optional and mainly for installed app bundles without a nearby project checkout.
- In the app, open `连接` and click `复制接入命令`; pasteboard should contain a `generic-agent-signal-hook` command that other agents can call with JSON events.
- If needed, click `安装连接`; existing JSON config should be merged, not replaced. Source/dist launches install Codex project hooks; installed app bundle launches install user hooks.
- If a previous Agent Signal Bar path was configured, confirm `安装连接` migrates that wrapper path instead of adding duplicate Agent Signal Bar hooks.
- Run `./script/doctor.sh --full` again and confirm:
  - `Codex hooks configured for current checkout`
  - `Claude hooks configured for current checkout`

## Install Smoke Test

- For manual startup, run `./script/install_app.sh`.
- For release zip startup, confirm `./script/install_app.sh --no-open` installs the existing `dist/AgentSignalLight.app` without rebuilding.
- For scripted DMG startup, run `./script/install_app.sh --dmg dist/AgentSignalBar.dmg`.
- For login startup, run `./script/install_app.sh --login-item`, or toggle `开机自启动` in the app.
- Run `./script/doctor.sh --full`.
- If login startup is enabled, confirm:
  - `launch-at-login plist is valid`
  - `launch-at-login plist points to an installed app`
  - `launch-at-login job is loaded`

## Uninstall Smoke Test

- Run `./script/uninstall_app.sh` to remove only the app and launch-at-login entry.
- Run `./script/uninstall_app.sh --remove-hooks` when you also want to remove Agent Signal Bar hooks from Codex and Claude Code configs.
- Run `./script/verify_uninstall.sh` for a non-destructive temp-home uninstall rehearsal.
- Confirm hook removal creates config backups and preserves unrelated hook commands.

## Distribution Notes

The current package is a local/self-use build:

- It is ad-hoc signed.
- It includes a local DMG installer.
- It is not Developer ID signed.
- It is not notarized.

For wider distribution:

- Run `./script/notarize_release.sh --readiness`.
- Package with `AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY="Developer ID Application: ..."` so the app is signed with hardened runtime and timestamp.
- Submit with `AGENT_SIGNAL_LIGHT_NOTARY_PROFILE=<profile> ./script/notarize_release.sh --submit`.
- Optionally add a polished DMG background or pkg installer.
- Keep the Sparkle private key in Keychain locally and in the GitHub Actions `SPARKLE_PRIVATE_KEY` secret for CI. Never commit the private key.
