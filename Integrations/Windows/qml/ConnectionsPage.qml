import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import AgentSignal

// 连接 / Connect: diagnostics, Codex data directory, optional hooks.
SettingsPage {
    readonly property var codex: App.codexConnection
    readonly property string codexHome: App.liveData && codex.home ? codex.home
        : (App.prefs.codexDataDir.length > 0 ? App.prefs.codexDataDir : "%USERPROFILE%\\.codex")
    readonly property string codexTone: App.liveData ? (codex.tone || "neutral") : "caution"
    readonly property string stateFile: App.claudeHook.stateFile || ""

    // One hook target (App.codexHook or App.claudeHook): its file, state, message and actions.
    component HookSection: AsbSection {
        id: section
        property bool codex: false
        property string fallbackPath
        readonly property var hook: codex ? App.codexHook : App.claudeHook
        readonly property string hookState: hook.state || "unchecked"
        readonly property string hookTone: hook.tone || "neutral"

        AsbRow {
            title: section.hook.settingsPath || section.fallbackPath
            StatusPill {
                text: section.hookState === "configured" ? Theme.t("已配置", "Configured")
                    : section.hookState === "repair" ? Theme.t("需要修复", "Needs repair")
                    : section.hookState === "error" ? Theme.t("无法检查", "Cannot check")
                    : section.hookState === "missing" ? Theme.t("未安装", "Not installed")
                    : Theme.t("未检查", "Not checked")
                tone: section.hookState === "configured" ? "positive"
                    : section.hookState === "repair" ? "caution"
                    : section.hookState === "error" ? "critical" : "neutral"
            }
        }
        AsbText {
            visible: text.length > 0
            text: section.hook.message || ""
            caption: true
            color: section.hookTone === "neutral" ? Theme.secondary : Theme.toneForeground(section.hookTone)
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        AsbText {
            visible: text.length > 0
            text: section.hook.result || ""
            caption: true
            secondary: true
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            Layout.fillWidth: true
        }
        RowLayout {
            spacing: Theme.s
            AsbButton {
                id: hookCheck
                property bool done: false // a check that finds nothing new would otherwise show nothing
                text: done ? Theme.t("已检查", "Checked") : Theme.t("检查", "Check")
                onClicked: {
                    if (section.codex) App.checkCodexHook()
                    else App.checkClaudeHook()
                    done = true
                    hookCheckReset.restart()
                }
                Timer { id: hookCheckReset; interval: 1500; onTriggered: hookCheck.done = false }
            }
            AsbButton {
                text: Theme.t("安装", "Install")
                // The action still needed; Codex hooks are optional, so only a repair stands out.
                prominent: section.hookState === "repair" || (!section.codex && section.hookState === "missing")
                enabled: section.hook.canModify === true
                onClicked: section.codex ? App.installCodexHook() : App.installClaudeHook()
            }
            AsbButton {
                text: Theme.t("卸载", "Uninstall")
                enabled: section.hook.canModify === true
                onClicked: section.codex ? App.uninstallCodexHook() : App.uninstallClaudeHook()
            }
        }
    }

    FolderDialog {
        id: folderDialog
        title: Theme.t("选择包含 sessions 文件夹的 Codex 数据目录", "Select the Codex data directory containing the sessions folder")
        onAccepted: App.prefs.codexDataDir = App.localPath(selectedFolder)
    }

    AsbSection {
        title: Theme.t("诊断与版本", "Diagnostics")
        footer: Theme.t("导出诊断包、查看状态文件和版本", "Export diagnostics, state file, and version")
        AsbRow {
            title: Theme.t("导出诊断", "Export Diagnostics")
            subtitle: Theme.t("状态、Hook 检查、日志和设置打包为 zip，不含聊天内容", "State, hook check, log and settings in a zip, no chat content")
            AsbButton {
                visible: (App.diagnostics.archive || App.diagnostics.folder || "").length > 0
                icon: "folder"
                text: Theme.t("显示", "Show")
                onClicked: App.revealPath(App.diagnostics.archive || App.diagnostics.folder)
            }
            AsbButton {
                text: App.diagnostics.running === true ? Theme.t("导出中…", "Exporting…") : Theme.t("导出…", "Export…")
                enabled: App.liveData && App.diagnostics.running !== true
                onClicked: App.exportDiagnostics()
            }
        }
        AsbText {
            visible: text.length > 0
            text: App.diagnostics.message || ""
            caption: true
            color: (App.diagnostics.tone || "neutral") === "neutral" ? Theme.secondary : Theme.toneForeground(App.diagnostics.tone)
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            Layout.fillWidth: true
        }
        AsbRow {
            title: Theme.t("状态文件", "State File")
            subtitle: stateFile.length > 0 ? stateFile : Theme.t("演示模式不写状态文件", "Demo mode writes no state file")
            AsbButton {
                visible: stateFile.length > 0
                icon: "copy"
                text: Theme.t("复制路径", "Copy Path")
                onClicked: App.copyText(stateFile)
            }
        }
        AsbRow {
            title: Theme.t("版本", "Version")
            subtitle: "Agent Signal Bar for Windows " + App.version
            AsbButton {
                icon: "copy"
                text: Theme.t("复制版本信息", "Copy release info")
                onClicked: App.copyText("Agent Signal Bar for Windows " + App.version + " (" + App.platform + ")")
            }
        }
    }

    AsbSection {
        title: "Codex"
        footer: Theme.t("自动识别 Codex Desktop、CLI、VS Code、IDEA 活动", "Recognises Codex Desktop, CLI, VS Code and IDEA activity automatically")
        AsbRow {
            title: Theme.t("数据目录", "Data directory")
            subtitle: codexHome
            StatusPill {
                text: !App.liveData ? Theme.t("演示数据", "Demo data")
                    : codexTone === "positive" ? Theme.t("已连接", "Connected")
                    : codexTone === "critical" ? Theme.t("无法读取", "Unreadable")
                    : codexTone === "caution" ? Theme.t("未连接", "Not connected")
                    : Theme.t("检查中", "Checking")
                tone: codexTone
            }
        }
        AsbText {
            visible: App.liveData
            text: codex.message || ""
            caption: true
            color: codexTone === "neutral" ? Theme.secondary : Theme.toneForeground(codexTone)
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        // Wraps: in English the three buttons and the pill are wider than the page.
        Flow {
            Layout.fillWidth: true
            spacing: Theme.s
            AsbButton { icon: "folder"; text: Theme.t("选择数据目录…", "Choose Directory…"); onClicked: folderDialog.open() }
            AsbButton { text: Theme.t("使用默认目录", "Use Default"); onClicked: App.prefs.codexDataDir = "" }
            AsbButton {
                id: codexCheck
                property bool done: false
                icon: "check"
                text: done ? Theme.t("已检查", "Checked") : Theme.t("检查连接", "Check Connection")
                onClicked: {
                    App.checkCodexConnection()
                    done = true
                    codexCheckReset.restart()
                }
                Timer { id: codexCheckReset; interval: 1500; onTriggered: codexCheck.done = false }
            }
            StatusPill {
                visible: App.liveData && !App.paused
                text: Theme.t("自动监控", "Auto monitor")
                tone: "positive"
            }
        }
    }

    HookSection {
        codex: true
        title: Theme.t("Codex Hook（可选）", "Codex Hook (Optional)")
        footer: Theme.t("可选增强：用于权限请求、低延迟和兼容旧版本", "Optional enhancement for permission requests, lower latency, and compatibility")
        fallbackPath: "%USERPROFILE%\\.codex\\hooks.json"
    }

    HookSection {
        title: "Claude Code Hook"
        footer: Theme.t("接入思考、工作、授权等待与完成状态", "Brings in thinking, working, permission and done states")
        fallbackPath: "%USERPROFILE%\\.claude\\settings.json"
    }

    AsbSection {
        title: Theme.t("Claude 桌面回复状态（可选）", "Claude Desktop reply state (optional)")
        footer: Theme.t("只读检查当前 Claude 窗口的回复按钮，不保存聊天内容；不判断后台任务完成。",
                        "Read-only checks of response controls in Claude windows; no chat content is saved and background completion is not inferred.")
        AsbRow {
            title: Theme.t("读取 Claude 桌面回复状态", "Read Claude Desktop reply state")
            subtitle: App.claudeUi.message || ""
            PrefSwitch { key: "claudeUIStatusMonitoring" }
        }
    }
}
