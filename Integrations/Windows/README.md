# Agent Signal Bar for Windows（Qt 6）

Windows 版沿用 CodexBar `Integrations/Linux` 的分层方式：C++ 控制器 + QML 窗口，用 qmake 构建，代码放在主仓库的 `Integrations/Windows/` 下，和 macOS 版共享文档与素材。

**当前阶段：界面壳。** 所有窗口和交互都已经做出来，数据使用合成演示数据（与 `docs/SCREENSHOTS.md` 的演示账号一致）。灯效引擎已经接入真实逻辑，并且与 Swift 版逐帧一致。读取 Codex 日志、账号与额度、Hook、CLI 等数据层还没有移植。

## 目录

| 路径 | 内容 |
| --- | --- |
| `src/SignalModel.*` | `AgentSignalLightCore` 灯语的移植，包括信号别名、显示状态、各灯效的亮度与缩放，以及低功耗模式和新西兰模式的节奏 |
| `src/AppController.*` | 偏好设置（INI，键名对应 macOS UserDefaults）、共享动画时钟、语言、主题、托盘弹窗定位、Mica/亚克力背景、开机自启动（`HKCU\…\Run`）、试听提示音 |
| `src/TrayIconRenderer.*` | 托盘图标绘制，提供经典灯牌、极简圆点、单灯三种风格，支持横向和竖向，并适配任务栏深浅色 |
| `qml/Theme.qml` | `DesignSystem.swift`（ASB）的移植，包括字号、间距、圆角、色调和灯色 |
| `qml/*Page.qml`、`SettingsWindow.qml` | 设置窗口：运行、用量、灯效、连接、通用、调试、关于 |
| `qml/TrayPanel.qml`、`SystemMenu.qml` | 托盘的两种展示方式：卡片面板和系统菜单 |
| `qml/FloatingSignal.qml` | 桌面悬浮灯：置顶、拖动、右下角自由缩放、三个角标、右键菜单、点击弹出浮层 |
| `tests/` | `tst_signalmodel` 与由 Swift 源码生成的 golden 数据（`tests/golden/generate.sh`）；`parity_strings.py` 用来对比 Swift 与 QML 的界面文案 |

## 在 Windows 上构建

需要 Windows 10 1809 及以上（Mica 需要 Windows 11 22H2）、Visual Studio 2022（MSVC x64），以及 Qt 6.8 或更新版本的 MSVC 套件（含 Qt Quick Controls 和 Qt SVG）。

> [!IMPORTANT]
> 请把仓库 clone 到**只含英文字符的路径**（例如 `C:\src\Agent-Signal-Bar`）。Qt 的 `rcc` 打不开中文路径下的 `.qrc`，测试也会把 golden 文件路径编译进程序。

在 “x64 Native Tools Command Prompt for VS 2022” 中运行：

```bat
powershell -ExecutionPolicy Bypass -File Integrations\Windows\build.ps1 -QtDir C:\Qt\6.8.3\msvc2022_64
```

脚本会先编译并运行灯效一致性测试，再编译 `AgentSignalBar.exe`，最后用 `windeployqt` 打包到 `%TEMP%\asb-windows-build\AgentSignalBar\`。

## 在 macOS 上开发

```bash
brew install qtbase qtdeclarative qtsvg
Integrations/Windows/dev-macos.sh capture
```

`--capture <目录>` 会按“中文深色、英文深色、中文浅色”三种组合，把每个设置页、两种托盘面板、悬浮灯以及托盘图标样张分别渲染成 PNG，然后退出。它使用临时 INI 文件，不会读写真实设置，也不会写注册表。

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
| 提示音（AVFoundation，可调音量） | `PlaySound` 播放 WAV（新西兰录音已转成 WAV） | ⚠️ 已支持试听；暂不支持音量档位，需要改用 Qt Multimedia 或 WASAPI |
| 多语言（10 种） | 目前只有简体中文和英文 | ❌ 其他语言暂时显示英文；需要移植 `AppLanguage.swift` 的翻译表 |
| Codex 日志监控、Token/费用扫描 | — | ❌ 未移植；需要先在 Windows 上确认 `%USERPROFILE%\.codex`（或 `CODEX_HOME`）的目录结构。“连接”页里显示的 Windows 路径（Codex、Claude、状态文件）都是待确认的占位值 |
| Codex 多账号、额度、限额重置 | — | ❌ 未移植；Keychain 改用 Windows 凭据管理器或 DPAPI |
| Claude 额度与 Hook | — | ❌ 未移植 |
| 浏览器 Cookie 导入（SweetCookieKit） | — | ❌ 不打算直接移植；Windows 上的 Chrome Cookie 使用 App-Bound Encryption，要另行评估 |
| Claude 桌面回复状态（辅助功能） | UI Automation | ❌ 未实现 |
| Sparkle 自动更新 | GitHub Releases 检查，或 WinSparkle | ❌ 未实现 |
| `agent-signal` CLI 与 Hook 脚本 | — | ❌ 未移植（shell 脚本需要 PowerShell 或 `.exe` 版本） |
| DMG 打包 | windeployqt 打包目录 | ⚠️ 安装包（Inno Setup 或 MSIX）与代码签名未做 |

## Windows 实机验收清单

在 Windows 上运行打包目录中的 `AgentSignalBar.exe`，逐项检查：

1. 托盘：图标出现在通知区域（可能先被收进 `^` 溢出区），绿灯按“工作中”节奏慢闪；任务栏切换深色/浅色后，极简圆点的描边颜色随之变化。
2. 单击托盘图标：卡片面板出现在图标上方并贴着任务栏；任务栏移到顶部或侧边后，面板仍然贴着任务栏；点击其他位置时面板关闭。
3. 右键托盘图标：弹出系统菜单；“显示/隐藏悬浮灯”“暂停监控”“关闭声音提醒”能立即生效。
4. 悬浮灯：可以拖动，并且始终在其他窗口之上；拖动右下角箭头可以缩放；右键菜单能切换大小和方向；退出后重新打开，位置保持不变。
5. 设置 → 通用：切换主题和语言后界面立即更新；打开“液态玻璃效果”后，Windows 11 上出现 Mica 背景（Windows 10 上应保持纯色，不报错）。
6. 设置 → 通用 → 开机自启动：开启后注册表 `HKCU\…\Run` 出现 `AgentSignalBar`，关闭后该项被删除。
7. 设置 → 灯效：各灯效下拉框和新西兰模式改变托盘与悬浮灯的节奏；“试听”按钮能播放四种提示音。
8. 设置 → 调试（在“通用”里打开“显示调试设置”）：逐个点击灯光调试按钮，托盘和悬浮灯同步变化。
9. 高 DPI（125% / 150% / 200% 缩放）：托盘图标清晰，窗口文字没有被截断。
10. `AgentSignalBar.exe --capture C:\temp\asb`：生成 PNG 截图，可以和 macOS 截图逐页对照。

## 素材

`resources/sounds/*-signal-nz.wav` 是由 `Sources/AgentSignalLight/Resources/` 中的新西兰录音（`.m4a`）转换成的单声道 22 kHz WAV，供 Windows `PlaySound` 播放；其余提示音直接引用原文件，`resources/AgentSignalBar.ico` 由 `docs/assets/app-icon.png` 生成。这些文件适用 `ASSET_LICENSES.md` 中的素材条款，但该文件目前还没有列出这个新路径。
