import QtQuick
import QtQuick.Layouts
import AgentSignal

// 连接 / Connect: diagnostics, Codex data directory, optional hooks.
SettingsPage {
    readonly property string stateFile: "%LOCALAPPDATA%\\AgentSignalBar\\state.json"
    readonly property string codexHome: App.prefs.codexDataDir.length > 0 ? App.prefs.codexDataDir : "%USERPROFILE%\\.codex"

    AsbSection {
        title: Theme.t("诊断与版本", "Diagnostics & Version")
        footer: Theme.t("导出诊断包、查看状态文件和版本", "Export a diagnostics bundle, see the state file and the version")
        AsbRow {
            title: Theme.t("导出诊断", "Export diagnostics")
            AsbButton { icon: "download"; text: Theme.t("导出诊断", "Export") }
        }
        AsbRow {
            title: Theme.t("状态文件", "State file")
            subtitle: stateFile
            AsbButton { icon: "copy"; text: Theme.t("复制路径", "Copy Path"); onClicked: App.copyText(stateFile) }
        }
        AsbRow {
            title: Theme.t("版本", "Version")
            subtitle: "Agent Signal Bar for Windows " + App.version
            AsbButton {
                icon: "copy"
                text: Theme.t("复制版本信息", "Copy Version Info")
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
            StatusPill { text: Theme.t("演示数据", "Demo data"); tone: "caution" }
        }
        RowLayout {
            spacing: Theme.s
            AsbButton { icon: "folder"; text: Theme.t("选择数据目录…", "Choose Directory…") }
            AsbButton { text: Theme.t("使用默认目录", "Use Default"); onClicked: App.prefs.codexDataDir = "" }
            AsbButton { icon: "check"; text: Theme.t("检查连接", "Check Connection") }
            StatusPill { text: Theme.t("自动监控", "Auto monitoring"); tone: "positive" }
        }
    }

    AsbSection {
        title: Theme.t("Codex Hook（可选）", "Codex Hook (optional)")
        footer: Theme.t("可选增强：用于权限请求、低延迟和兼容旧版本", "Optional: permission requests, lower latency and older versions")
        AsbRow {
            title: "%USERPROFILE%\\.codex\\hooks.json"
            StatusPill { text: Theme.t("未安装", "Not installed"); tone: "neutral" }
        }
        RowLayout {
            spacing: Theme.s
            AsbButton { text: Theme.t("检查", "Check") }
            AsbButton { text: Theme.t("安装", "Install"); prominent: true }
            AsbButton { text: Theme.t("卸载", "Uninstall") }
        }
    }

    AsbSection {
        title: "Claude Code Hook"
        footer: Theme.t("接入思考、工作、授权等待与完成状态", "Brings in thinking, working, permission and done states")
        AsbRow {
            title: "%USERPROFILE%\\.claude\\settings.json"
            StatusPill { text: Theme.t("未安装", "Not installed"); tone: "neutral" }
        }
        RowLayout {
            spacing: Theme.s
            AsbButton { text: Theme.t("检查", "Check") }
            AsbButton { text: Theme.t("安装", "Install"); prominent: true }
            AsbButton { text: Theme.t("卸载", "Uninstall") }
        }
    }

    AsbSection {
        title: Theme.t("Claude 桌面回复状态（可选）", "Claude Desktop reply state (optional)")
        footer: Theme.t("macOS 版通过辅助功能读取；Windows 版需要改用 UI Automation，尚未实现。",
                        "macOS reads this through Accessibility; Windows needs UI Automation, which is not implemented yet.")
        AsbRow {
            title: Theme.t("读取 Claude 桌面回复状态", "Read Claude Desktop reply state")
            StatusPill { text: Theme.t("暂不支持", "Not available"); tone: "neutral" }
        }
    }
}
