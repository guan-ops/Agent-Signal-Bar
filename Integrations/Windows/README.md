# Agent Signal Bar for Windows（Qt 6）

Windows 版沿用 CodexBar `Integrations/Linux` 的分层方式：C++ 控制器 + QML 窗口，用 qmake 构建，代码放在主仓库的 `Integrations/Windows/` 下，和 macOS 版共享文档与素材。

**当前阶段：界面壳 + Codex 与 Claude Code 实时监控。** 所有窗口和交互都已经做出来。信号灯、托盘面板、“运行”页和悬浮灯会跟随 Codex 会话日志（`rollout-*.jsonl`）和 Claude Code Hook 实时变化。状态保存在与 macOS 版格式相同的 `status.json` 里，由应用和 Hook 命令 `agent-signal.exe` 共同读写。日志解析、Claude Hook 解析、状态存储和显示规则都按 Swift 版移植，并与 Swift 实现逐条比对。用量、额度和账号仍然是合成演示数据（界面上标了“演示数据”）。

## 目录

| 路径 | 内容 |
| --- | --- |
| `src/SignalModel.*` | `AgentSignalLightCore` 灯语的移植，包括信号别名、显示状态、各灯效的亮度与缩放，以及低功耗模式和新西兰模式的节奏 |
| `src/AppController.*` | 偏好设置（INI，键名对应 macOS UserDefaults）、共享动画时钟、语言、主题、托盘弹窗定位、Mica/亚克力背景、开机自启动（`HKCU\…\Run`）、试听提示音 |
| `src/TrayIconRenderer.*` | 托盘图标绘制，提供经典灯牌、极简圆点、单灯三种风格，支持横向和竖向，并适配任务栏深浅色 |
| `src/CodexSessionParser.*` | `CodexDesktopSessionParser.swift` 的移植：把 rollout 日志行转成思考、工作、等待授权、完成等活动 |
| `src/CodexActivityMonitor.*` | `CodexDesktopActivityMonitor.swift` 的移植：找最近写入的 8 个 rollout 文件并只读新增的完整行；首次轮询不回放历史 |
| `src/SignalStore.*`、`src/SignalStateFile.*` | `SignalStateStore.swift` 的移植：会话、事件、过期与授权保持规则；`status.json` 的加锁读写（键名与 macOS 版相同） |
| `src/HookAdapters.*` | `ClaudeHookAdapter` 的移植：把 Claude Code Hook 的输入转成信号、会话和事件名（不保存提示词和工具参数） |
| `src/ClaudeHookInstaller.*` | 在 Claude Code 的 `settings.json` 里安装、检查、卸载 Hook，只动自己的条目，修改前备份 |
| `cli/` | `agent-signal.exe`：Claude Code Hook 调用的命令（只依赖 QtCore，始终返回 0、不输出内容） |
| `src/ActivityDisplay.*`、`src/ActivityText.*` | `ActivityPresentation.swift` 与 `MenuBarStatusModel` 显示规则的移植：哪些会话显示、按来源去重、灯显示什么，以及会话和事件的中英文文案 |
| `src/SignalRuntime.*` | 后台线程每 2 秒（低功耗 6 秒）轮询一次，每 5 秒（15 秒）刷新显示，让完成和中断的会话按时消失 |
| `qml/Theme.qml` | `DesignSystem.swift`（ASB）的移植，包括字号、间距、圆角、色调和灯色 |
| `qml/*Page.qml`、`SettingsWindow.qml` | 设置窗口：运行、用量、灯效、连接、通用、调试、关于 |
| `qml/TrayPanel.qml`、`SystemMenu.qml` | 托盘的两种展示方式：卡片面板和系统菜单 |
| `qml/FloatingSignal.qml` | 桌面悬浮灯：置顶、拖动、右下角自由缩放、三个角标、右键菜单、点击弹出浮层 |
| `tests/` | `tst_signalmodel`（灯效）与 `tst_codex`（解析、状态存储、监控、显示规则），golden 数据由 Swift 源码生成（`tests/golden/generate.sh`）；`make_live_fixture.py` 生成合成 rollout 文件；`parity_strings.py` 用来对比 Swift 与 QML 的界面文案 |

## 在 Windows 上构建

需要 Windows 10 1809 及以上（Mica 需要 Windows 11 22H2）、Visual Studio 2022（MSVC x64），以及 Qt 6.8 或更新版本的 MSVC 套件（含 Qt Quick Controls 和 Qt SVG）。

> [!IMPORTANT]
> 请把仓库 clone 到**只含英文字符的路径**（例如 `C:\src\Agent-Signal-Bar`）。Qt 的 `rcc` 打不开中文路径下的 `.qrc`，测试也会把 golden 文件路径编译进程序。

在 “x64 Native Tools Command Prompt for VS 2022” 中运行：

```bat
powershell -ExecutionPolicy Bypass -File Integrations\Windows\build.ps1 -QtDir C:\Qt\6.8.3\msvc2022_64
```

脚本会先编译并运行灯效与数据层测试，再编译 `AgentSignalBar.exe` 和 `agent-signal.exe`，最后用 `windeployqt` 安装到 `%LOCALAPPDATA%\Programs\AgentSignalBar\`（可用 `-InstallDir` 修改）。这个目录必须固定：Claude Code 的 Hook 会指向其中的 `agent-signal.exe`。重新编译前请先退出 Agent Signal Bar。

安装目录自带 Qt 和 MSVC 运行库（`vcruntime140.dll` 等，从 `VCToolsRedistDir` 复制），没装 Visual C++ 运行库的电脑也能直接运行。不在 VS 命令提示符里运行时找不到这些 DLL，脚本会给出警告，这时目录里只有 `vc_redist.x64.exe` 安装包。

程序每个用户只运行一个实例：已经在运行时再次启动，会打开正在运行的那个的设置窗口，然后退出。`--signal`、`--settings`、`--capture` 和 `--probe` 不受这个限制，可以和正常运行的程序同时使用。

### 检查 Codex 数据目录

```bat
start /wait %LOCALAPPDATA%\Programs\AgentSignalBar\AgentSignalBar.exe --probe 10
```

`AgentSignalBar.exe` 是窗口程序，不加 `start /wait` 时命令提示符会立刻返回，输出会和提示符混在一起。`--probe` 不打开任何窗口，只在终端里打印 10 秒内看到的内容：Codex 数据目录、找到的 rollout 文件，以及信号灯和各会话的状态（会回放最近 30 分钟的活动）。每个文件一行，包括大小、已读取的字节数和“几秒前修改”；Codex 正在写入时，这几个数字应该在增长。数据目录的顺序是：设置里选择的目录 → `CODEX_HOME` → `%USERPROFILE%\.codex`，日志在其中的 `sessions` 文件夹。可以用 `--codex-dir <目录>` 临时指定别的目录，例如 WSL 里的 `\\wsl.localhost\Ubuntu\home\<用户>\.codex`。

运行时加上 `--signal working` 会进入演示模式，不读取 Codex，也不读写状态文件。

### 接入 Claude Code

设置 → 连接 → Claude Code Hook → 安装。它会在 `%USERPROFILE%\.claude\settings.json`（或 `CLAUDE_CONFIG_DIR`）里为 26 个 Hook 事件各加一条命令，原有设置和其他 Hook 保持不变，修改前会备份成 `settings.json.bak-*`（保留最近 5 份）。“卸载”只删除指向 `agent-signal` 的条目。

每条 Hook 用 exec 形式写入：`"command": "<安装目录>/agent-signal.exe", "args": ["claude-hook"]`，不经过 Git Bash 或 PowerShell 解析。路径里有空格时会改用 8.3 短路径，所以不支持 `args` 的旧版 Claude Code 通过 shell 运行时也能启动它。`agent-signal.exe` 读到 Hook 输入后只记录事件名、工具名和会话 ID，最多等 1.5 秒状态锁，始终返回 0 且不输出内容，所以不会拦住 Claude Code。

```bat
%LOCALAPPDATA%\Programs\AgentSignalBar\agent-signal.exe status
```

可以随时查看 Hook 写入的状态。如果安装后 Claude Code 报告设置错误（例如旧版本不认识 `args` 字段），先在“连接”页点“卸载”；不行的话，把 `settings.json` 旁边最新的 `settings.json.bak-*` 改名回 `settings.json` 即可恢复。状态文件在 `%LOCALAPPDATA%\Agent Signal Bar\SignalState\status.json`（可用 `AGENT_SIGNAL_LIGHT_STATE_FILE` 或 `AGENT_SIGNAL_LIGHT_STATE_DIR` 改位置）。

## 在 macOS 上开发

```bash
brew install qtbase qtdeclarative qtsvg
Integrations/Windows/dev-macos.sh capture
```

`--capture <目录>` 会按“中文深色、英文深色、中文浅色”三种组合，把每个设置页、两种托盘面板、悬浮灯以及托盘图标样张分别渲染成 PNG，然后退出。它使用临时 INI 文件和演示数据，不会读写真实设置，也不会写注册表或读取 `~/.codex`。

`dev-macos.sh capture-live` 先用 `tests/make_live_fixture.py` 在 `/private/tmp/asb-live-fixture` 生成三个合成 Codex 会话（终端运行工具、VS Code 等待授权、桌面版刚完成），再通过真实的 `agent-signal` 写入两条合成 Claude Code Hook 事件，最后用 `--codex-dir` 指向它截图，用来检查实时数据在界面上的样子。macOS 开发版的状态文件放在 `~/Library/Application Support/Agent Signal Bar (Windows port)/`，不会碰 macOS 版自己的状态；只有加上 `--claude-dir <目录>` 时才允许修改 Claude 设置。`--codex-dir` 只读取该目录，不会读取 macOS 上额外的 Xcode/JetBrains 目录。

## 与 macOS 版的对应关系

| macOS | Windows | 状态 |
| --- | --- | --- |
| 状态栏信号灯（`NSStatusItem`，较宽） | 通知区域托盘图标（正方形，16–64 px） | ✅ 三种风格、横向/竖向；单击打开面板，右键打开系统菜单，双击打开设置 |
| 卡片面板 / 系统菜单 | 托盘上方的无边框弹窗 | ✅ 按 1.7.0 的 `MenuBarPanelView` 和 `StatusBarController` 结构实现；点击其他位置时关闭 |
| 悬浮信号灯 | 置顶工具窗口 | ✅ 拖动、缩放预设、自定义缩放、角标、右键菜单、浮层；位置会保存，显示器拔掉后会移回主屏 |
| 灯语、灯效与节奏 | `SignalModel` | ✅ 与 Swift 实现逐帧比对（1998 组 golden 数据），节奏表另有单元测试 |
| 设置窗口 7 个页面 | QML 页面 | ⚠️ 页面结构与主要控件已完成（演示数据）。macOS 版 376 条界面文案中约 2/3 尚未出现，主要是加载中、错误、空状态等需要数据层的文案，以及 Claude 用量设置、探测日志、获取策略调试、OpenAI Cookie 等调试分区。运行 `python3 -I Integrations/Windows/tests/parity_strings.py <仓库根目录> <输出目录>` 可列出缺失项 |
| 液态玻璃 | Mica（标准）/ Mica Alt（增强），只用于设置窗口 | ⚠️ 已写 DWM 调用；低于 Windows 11 22H2 时自动保持不透明。需要实机验收 |
| 开机自启动（SMAppService） | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | ⚠️ 已实现，需要实机验收 |
| 提示音（AVFoundation，可调音量） | `PlaySound` 播放 WAV（新西兰录音已转成 WAV） | ⚠️ 只能在设置里试听：任务完成或等待授权时还不会自动播放；暂不支持音量档位，需要改用 Qt Multimedia 或 WASAPI |
| 多语言（10 种） | 目前只有简体中文和英文 | ❌ 其他语言暂时显示英文；需要移植 `AppLanguage.swift` 的翻译表 |
| Codex 日志监控（灯语） | `CodexActivityMonitor` + `SignalStore` + `ActivityDisplay` | ✅ 解析器（57 行样例 × 2 种默认来源）和状态存储（11 组事件序列）与 Swift 实现逐条比对；监控和显示规则有单元测试。已在 macOS 上对真实 `~/.codex` 只读运行过，但没有和 macOS 版逐项对比（当时 macOS 版关闭了 Codex 自动监控）。Windows 上的目录位置需要用 `--probe` 实机确认 |
| 状态文件 `status.json`（与 CLI、Hook 共享） | `SignalStateFile`（`%LOCALAPPDATA%\Agent Signal Bar\SignalState\status.json`） | ✅ 键名与 macOS 版相同，能读 Swift 写出的文件（有测试）；加锁读写，读不到时不覆盖，内容损坏时按 macOS 版视为“状态不可信”。重启后状态保留，所以启动时和 macOS 版一样只记下日志位置、不回放历史 |
| Claude Code Hook | `agent-signal.exe claude-hook` + `ClaudeHookInstaller` | ✅ Hook 解析与 Swift 实现逐条比对（46 组样例）；安装器有单元测试（保留其他设置、幂等、只删自己的条目、备份、拒绝损坏和符号链接的文件）。⚠️ 还没在 Windows 上实测：Claude Code 是否按 exec 形式启动 `agent-signal.exe` 要在 PC 上确认 |
| 灯效 Agent（按 Agent 跟随、空闲时显示其他 Agent） | — | ⚠️ 未移植：Codex 和 Claude 的会话一起参与灯效，取最需要处理的状态；macOS 版默认只跟随一个 Agent。“灯效 Agent”下拉框还没有效果 |
| 桌面应用在线检测（Codex/Claude 桌面版已打开） | — | ❌ 未移植 |
| Xcode、JetBrains 的 Codex 会话目录 | — | ⚠️ macOS 开发版会读取；Windows 上的 JetBrains 目录未知，暂不读取 |
| Token/费用扫描 | — | ❌ 未移植；用量页、卡片面板的用量与悬浮灯的额度、Token 角标仍是演示数据（实时模式下角标隐藏，用量标注“演示数据”） |
| Codex 多账号、额度、限额重置 | — | ❌ 未移植；Keychain 改用 Windows 凭据管理器或 DPAPI |
| Claude 额度 | — | ❌ 未移植 |
| 浏览器 Cookie 导入（SweetCookieKit） | — | ❌ 不打算直接移植；Windows 上的 Chrome Cookie 使用 App-Bound Encryption，要另行评估 |
| Claude 桌面回复状态（辅助功能） | UI Automation | ❌ 未实现 |
| Sparkle 自动更新 | GitHub Releases 检查，或 WinSparkle | ❌ 未实现 |
| `agent-signal` CLI | `agent-signal.exe` | ⚠️ 只有 `claude-hook` 和 `status`；`set`、`session`、`codex-hook`、`install-hooks` 等命令未移植 |
| Codex Hook | — | ❌ 未移植（Codex 状态已通过会话日志获取）；“连接”页标为“尚未移植” |
| DMG 打包 | windeployqt 打包目录 | ⚠️ 安装包（Inno Setup 或 MSIX）与代码签名未做 |

## Windows 实机验收清单

在 Windows 上运行安装目录（默认 `%LOCALAPPDATA%\Programs\AgentSignalBar`）中的 `AgentSignalBar.exe`，逐项检查：

1. 托盘：图标出现在通知区域（可能先被收进 `^` 溢出区）；没有 Codex 任务时为空闲。用 `--signal working` 启动时，绿灯按“工作中”节奏慢闪；任务栏切换深色/浅色后，极简圆点的描边颜色随之变化。
2. 单击托盘图标：卡片面板出现在图标上方并贴着任务栏；任务栏移到顶部或侧边后，面板仍然贴着任务栏；点击其他位置时面板关闭。
3. 右键托盘图标：弹出系统菜单；“显示/隐藏悬浮灯”“暂停监控”“关闭声音提醒”能立即生效。
4. 悬浮灯：可以拖动，并且始终在其他窗口之上；拖动右下角箭头可以缩放；右键菜单能切换大小和方向；退出后重新打开，位置保持不变。
5. 设置 → 通用：切换主题和语言后界面立即更新；打开“液态玻璃效果”后，Windows 11 上出现 Mica 背景（Windows 10 上应保持纯色，不报错）。
6. 设置 → 通用 → 开机自启动：开启后注册表 `HKCU\…\Run` 出现 `AgentSignalBar`，关闭后该项被删除。
7. 设置 → 灯效：各灯效下拉框和新西兰模式改变托盘与悬浮灯的节奏；“试听”按钮能播放四种提示音。
8. 设置 → 调试（在“通用”里打开“显示调试设置”）：逐个点击灯光调试按钮，托盘和悬浮灯同步变化。
9. 高 DPI（125% / 150% / 200% 缩放）：托盘图标清晰，窗口文字没有被截断。
10. `AgentSignalBar.exe --capture C:\temp\asb`：生成 PNG 截图，可以和 macOS 截图逐页对照。
11. `start /wait AgentSignalBar.exe --probe 10`：打印的数据目录就是 Codex 实际写日志的位置，`recent files` 大于 0；Codex 运行任务时，对应文件的 `size` 和 `read` 一起增长。如果 Codex 在 WSL 里运行，用 `--codex-dir` 试一下 WSL 路径，并把结果告诉我。
12. Codex 实时监控：在 Codex（CLI、VS Code 或桌面版）里发起一个任务，2 秒内托盘灯变绿（思考快闪、工作慢闪）；需要授权时变红；完成后显示“已完成”约 30 秒再回到空闲。中途关掉 Codex，灯最多 5 分钟后回到空闲。
13. 设置 → 连接 → Codex：显示“已连接 · 最近事件…”；“选择数据目录…”能打开文件夹对话框，选择后立即生效。
14. 设置 → 连接 → Claude Code Hook：点“安装”后显示“已配置”，`settings.json` 旁边多一份 `.bak-*` 备份，原有设置还在；再点“检查”仍是“已配置”。
15. 新开一个 Claude Code 会话发任务：灯变绿，“运行”页出现“Claude · 终端运行中”（VS Code 里会显示“claude-vscode · VS Code 运行中”：macOS 版源码的 `friendlyAgentName` 也没有把 `claude-vscode` 映射成 Claude，这里照搬，未在 macOS 版上实际核对）；需要授权时变红；完成后显示“已完成”。同时运行 `agent-signal.exe status` 能看到这个会话。如果灯没反应，请把 Claude Code 版本号（`claude --version`）、是否装了 Git for Windows，以及 `settings.json` 里任意一条 agent-signal 条目告诉我。
16. 点“卸载”：只删掉 agent-signal 的条目，其他 Hook 和设置保持不变。

## 素材

`resources/sounds/*-signal-nz.wav` 是由 `Sources/AgentSignalLight/Resources/` 中的新西兰录音（`.m4a`）转换成的单声道 22 kHz WAV，供 Windows `PlaySound` 播放；其余提示音直接引用原文件，`resources/AgentSignalBar.ico` 由 `docs/assets/app-icon.png` 生成。这些文件适用 `ASSET_LICENSES.md` 中的素材条款，但该文件目前还没有列出这个新路径。
