import QtQuick
import QtQuick.Layouts
import AgentSignal

// 调试 / Debug: logs and the light debugger that drives the tray and floating light.
SettingsPage {
    id: page
    readonly property var tests: [
        { signal: "thinking", label: Theme.t("思考", "Thinking") },
        { signal: "working", label: Theme.t("工作中", "Working") },
        { signal: "done", label: Theme.t("已完成", "Done") },
        { signal: "attention", label: Theme.t("需要查看", "Needs review") },
        { signal: "permission_request", label: Theme.t("等待授权", "Permission") },
        { signal: "blocked", label: Theme.t("阻塞", "Blocked") },
        { signal: "stale", label: Theme.t("状态不可信", "Stale") },
        { signal: "idle", label: Theme.t("空闲", "Idle") }
    ]

    AsbSection {
        title: Theme.t("日志", "Logs")
        AsbRow {
            title: Theme.t("启用文件日志", "Enable file logging")
            subtitle: Theme.t("将日志写入 %LOCALAPPDATA%\\AgentSignalBar\\debug.log 以进行调试。",
                              "Writes logs to %LOCALAPPDATA%\\AgentSignalBar\\debug.log for debugging.")
            // Nothing reads fileLogging or logLevel yet; a switch would promise a log that never appears.
            StatusPill { text: Theme.t("尚未移植", "Not ported"); tone: "neutral" }
        }
    }

    AsbSection {
        title: Theme.t("缓存", "Caches")
        footer: Theme.t("清除缓存的费用扫描结果或浏览器 Cookie 缓存。", "Clear cached cost scans or the browser cookie cache.")
        // Cost scans and cookie import are not ported, so there is nothing to clear yet.
        AsbRow {
            title: Theme.t("清除费用缓存 / Cookie 缓存", "Clear cost / cookie cache")
            StatusPill { text: Theme.t("尚未移植", "Not ported"); tone: "neutral" }
        }
    }

    AsbSection {
        title: Theme.t("灯光调试", "Light Debug")
        AsbRow {
            title: Theme.t("启用灯光调试", "Enable light debug")
            subtitle: Theme.t("临时触发托盘和悬浮信号灯，方便检查红、黄、绿灯效。",
                              "Temporarily drive the tray and floating light to check red, yellow and green effects.")
            AsbSwitch {
                checked: App.lightDebugActive
                onToggled: checked => App.setDebugSignal(checked ? "working" : "")
            }
        }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: page.tests
                AsbButton {
                    required property var modelData
                    text: modelData.label
                    prominent: App.lightDebugActive && App.signalName === modelData.signal
                    onClicked: App.setDebugSignal(modelData.signal)
                }
            }
        }
    }
}
