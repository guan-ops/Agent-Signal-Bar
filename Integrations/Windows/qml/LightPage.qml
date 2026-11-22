import QtQuick
import QtQuick.Layouts
import AgentSignal

// 灯效 / Light: where the light shows, how it looks, effects, rhythm and sound.
SettingsPage {
    readonly property var activeEffects: [
        { value: "green_breathing", label: Theme.t("绿灯呼吸", "Green breathe") },
        { value: "green_steady", label: Theme.t("绿灯常亮", "Green steady") },
        { value: "green_slow_flash", label: Theme.t("绿灯慢闪", "Green slow") },
        { value: "green_fast_flash", label: Theme.t("绿灯快闪", "Green fast") },
        { value: "traffic_cycle", label: Theme.t("红黄绿依次亮灯", "R/Y/G sequence") }
    ]
    // AppLocalization.displayName(for:color:): the lamp color is part of the name.
    function alertEffects(zh, en) {
        return [
            { value: "pulse", label: Theme.t(zh + "慢闪", en + " slow") },
            { value: "steady", label: Theme.t(zh + "常亮", en + " steady") },
            { value: "slow_flash", label: Theme.t(zh + "慢闪", en + " slow") },
            { value: "fast_flash", label: Theme.t(zh + "快闪", en + " fast") },
            { value: "breathing", label: Theme.t(zh + "呼吸", en + " breathe") },
            { value: "traffic_cycle", label: Theme.t("红黄绿依次亮灯", "R/Y/G sequence") }
        ]
    }
    readonly property var completedEffects: [
        { value: "green_pulse", label: Theme.t("绿灯慢闪", "Green slow") },
        { value: "green_steady", label: Theme.t("绿灯常亮", "Green steady") },
        { value: "yellow_pulse", label: Theme.t("黄灯慢闪", "Yellow slow") },
        { value: "yellow_steady", label: Theme.t("黄灯常亮", "Yellow steady") },
        { value: "all_steady", label: Theme.t("三灯全亮", "All steady") },
        { value: "all_pulse", label: Theme.t("三灯同步闪", "All flash") }
    ]
    readonly property var completionSounds: [
        { value: "off", label: Theme.t("关闭", "Off") },
        { value: "new_zealand", label: Theme.t("新西兰", "New Zealand") },
        { value: "ai_aurora", label: Theme.t("清亮", "Bright") },
        { value: "ai_glow", label: Theme.t("柔和", "Soft") }
    ]
    readonly property var waitingSounds: [
        { value: "off", label: Theme.t("关闭", "Off") },
        { value: "new_zealand", label: Theme.t("新西兰", "New Zealand") },
        { value: "ai_tick", label: Theme.t("短促", "Tick") },
        { value: "ai_orbit", label: Theme.t("圆润", "Round") }
    ]
    readonly property var layouts: [
        { value: "horizontal", label: Theme.t("横向", "Horizontal") },
        { value: "vertical", label: Theme.t("竖向", "Vertical") }
    ]

    AsbSection {
        title: Theme.t("信号灯", "Signals")
        AsbRow {
            title: Theme.t("显示托盘信号", "Show tray signal")
            PrefSwitch { key: "statusBarEnabled" }
        }
        AsbRow {
            title: Theme.t("显示悬浮信号灯", "Show floating signal")
            subtitle: Theme.t("在桌面上显示可拖动、可缩放的悬浮信号灯", "A draggable, resizable signal light on the desktop")
            PrefSwitch { key: "floatingEnabled" }
        }
    }

    AsbSection {
        title: Theme.t("托盘", "Tray")
        footer: Theme.t("在 Windows 设置 → 个性化 → 任务栏 → 其他系统托盘图标中打开 Agent Signal Bar，信号灯会常驻任务栏。",
                        "Turn on Agent Signal Bar in Settings → Personalization → Taskbar → Other system tray icons to keep the light on the taskbar.")
        AsbRow {
            title: Theme.t("托盘展示方式", "Tray presentation")
            Dropdown {
                key: "menuMode"
                options: [
                    { value: "detailed", label: Theme.t("卡片面板", "Card Panel") },
                    { value: "simple", label: Theme.t("系统菜单", "System Menu") }
                ]
            }
        }
        AsbRow {
            title: Theme.t("托盘风格", "Tray style")
            Segmented {
                key: "statusStyle"
                segmentWidth: 72
                options: [
                    { value: "trafficLight", label: Theme.t("经典灯牌", "Classic") },
                    { value: "macOS", label: Theme.t("极简圆点", "Dots") },
                    { value: "singleLamp", label: Theme.t("单灯", "Single") }
                ]
            }
        }
        AsbRow {
            visible: App.prefs.statusStyle !== "singleLamp"
            title: Theme.t("托盘方向", "Tray layout")
            Segmented { key: "statusLayout"; options: layouts }
        }
    }

    AsbSection {
        title: Theme.t("悬浮灯", "Floating Signal")
        footer: Theme.t("尺寸预设同时适用于横向和竖向；拖动灯牌右下角箭头可自由微调。",
                        "Presets apply to both layouts; drag the arrow at the lamp's bottom-right corner to fine-tune.")
        AsbRow {
            title: Theme.t("悬浮灯方向", "Floating layout")
            Segmented { key: "floatingLayout"; options: layouts }
        }
        AsbRow {
            title: Theme.t("悬浮灯大小", "Floating size")
            subtitle: Theme.t("选择横向和竖向共用的尺寸预设。", "One preset for both layouts.")
            Segmented {
                key: "floatingSize"
                segmentWidth: 52
                options: [
                    { value: "compact", label: Theme.t("小", "Small") },
                    { value: "standard", label: Theme.t("默认", "Default") },
                    { value: "large", label: Theme.t("大", "Large") },
                    { value: "custom", label: Theme.t("自定义", "Custom") }
                ]
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        AsbText { text: Theme.t("角标", "Badges"); caption: true; strong: true; secondary: true }
        AsbRow {
            title: Theme.t("运行数量角标", "Running count")
            subtitle: Theme.t("显示当前运行中的 Agent 数量，并可点击查看运行中的 Agent。", "Shows how many agents are running; click to see them.")
            PrefSwitch { key: "badgeRunning" }
        }
        AsbRow {
            title: Theme.t("额度角标", "Quota")
            subtitle: Theme.t("显示 Agent 剩余额度百分比；所选周期暂不可用时显示 --，点击可切换到当前可用周期。",
                              "Shows the agent's remaining quota; -- when the chosen window is unavailable. Click to switch window.")
            PrefSwitch { key: "badgeQuota" }
        }
        AsbRow {
            title: Theme.t("Token 角标", "Tokens")
            subtitle: Theme.t("显示今日或近 30 天 Token 使用量，并自动切换 K/M/B 单位。", "Shows today's or 30-day token use with K/M/B units.")
            PrefSwitch { key: "badgeToken" }
        }
    }

    AsbSection {
        title: Theme.t("灯效", "Effects")
        AsbText { text: Theme.t("灯效自定义", "Customize effects"); caption: true; strong: true; secondary: true }
        AsbRow { title: Theme.t("思考灯效", "Thinking"); Dropdown { key: "thinkingEffect"; options: activeEffects; pickerWidth: 150 } }
        AsbRow { title: Theme.t("工作灯效", "Working"); Dropdown { key: "workingEffect"; options: activeEffects; pickerWidth: 150 } }
        AsbRow { title: Theme.t("需确认灯效", "Needs review"); Dropdown { key: "needsReviewEffect"; options: alertEffects("黄灯", "Yellow"); pickerWidth: 150 } }
        AsbRow { title: Theme.t("授权灯效", "Permission"); Dropdown { key: "permissionEffect"; options: alertEffects("红灯", "Red"); pickerWidth: 150 } }
        AsbRow { title: Theme.t("阻塞灯效", "Blocked"); Dropdown { key: "blockedEffect"; options: alertEffects("红灯", "Red"); pickerWidth: 150 } }
        AsbRow { title: Theme.t("完成灯效", "Done"); Dropdown { key: "doneEffect"; options: completedEffects; pickerWidth: 150 } }
    }

    AsbSection {
        title: Theme.t("灯光节奏", "Rhythm")
        AsbRow {
            title: Theme.t("新西兰原版模式", "New Zealand original mode")
            subtitle: Theme.t("按新西兰行人红绿灯节奏慢闪，并将完成音和闪烁音切换为新西兰。",
                              "Use the original New Zealand pedestrian crossing cadence and switch completion and blink sounds to New Zealand.")
            PrefSwitch { key: "newZealandMode" }
        }
    }

    AsbSection {
        title: Theme.t("声音", "Sound")
        // README: PlaySound previews only; automatic alerts and volume levels are not ported.
        footer: Theme.t("Windows 版目前只能试听：任务完成或等待授权时还不会自动播放，音量档位也尚未移植。",
                        "Windows can only preview the sounds so far: they do not play on completion or permission requests yet, and volume levels are not ported.")
        AsbRow { title: Theme.t("声音提醒", "Sound alerts"); PrefSwitch { key: "soundEnabled" } }
        AsbRow {
            title: Theme.t("完成提示音", "Completion sound")
            RowLayout {
                spacing: 6
                Dropdown { key: "completionSound"; options: completionSounds }
                AsbButton {
                    icon: "speaker"
                    text: Theme.t("试听", "Preview")
                    onClicked: App.previewSound("completion", App.prefs.completionSound)
                }
            }
        }
        AsbRow {
            title: Theme.t("绿灯闪烁音", "Green blink sound")
            RowLayout {
                spacing: 6
                Dropdown { key: "waitingSound"; options: waitingSounds }
                AsbButton {
                    icon: "speaker"
                    text: Theme.t("试听", "Preview")
                    onClicked: App.previewSound("waiting", App.prefs.waitingSound)
                }
            }
        }
        AsbRow {
            title: Theme.t("声音音量", "Volume")
            Segmented {
                key: "soundLevel"
                segmentWidth: 44
                options: [
                    { value: "soft", label: Theme.t("轻", "Soft") },
                    { value: "standard", label: Theme.t("标准", "Standard") },
                    { value: "loud", label: Theme.t("响", "Loud") }
                ]
            }
        }
    }
}
