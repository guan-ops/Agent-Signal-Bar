import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import AgentSignal

// The update window (Sparkle's standard user driver): checking, up to date, a new version with
// its release notes, download progress, ready to install, errors. `askPermission` turns it
// into "Check for updates automatically?", shown once on the second launch.
Window {
    id: win
    property bool askPermission: false
    property bool permissionInstall: false
    readonly property var u: App.update
    readonly property string stage: u.stage || "idle"
    readonly property bool showNotes: !askPermission && stage === "available"

    title: askPermission ? Theme.t("自动检查更新", "Automatic Updates") : Theme.t("软件更新", "Software Update")
    width: showNotes ? 600 : 460
    // Compact stages (prompt, progress) are shorter than the notes view; never ask for less than the minimum.
    height: showNotes ? 470 : Math.max(minimumHeight, content.implicitHeight + 40)
    minimumWidth: 420
    minimumHeight: 120
    color: Theme.windowBg
    flags: Qt.Dialog

    function present(permission) {
        askPermission = permission === true
        if (askPermission) permissionInstall = false
        if (visibility === Window.Minimized) showNormal()
        else show()
        raise()
        requestActivate()
    }
    onVisibleChanged: if (visible) App.applyBackdrop(win, "window")
    // Closing the window is "Remind Me Later"; a download carries on in the background.
    onClosing: if (!askPermission && (stage === "available" || stage === "upToDate" || stage === "failed")) App.remindUpdateLater()

    Shortcut { sequence: "Esc"; onActivated: win.close() }

    Rectangle { anchors.fill: parent; color: Theme.windowBg }

    component Bar: Rectangle {
        property real value: -1 // -1: indeterminate
        Layout.fillWidth: true
        implicitHeight: 6
        radius: 3
        color: Theme.track
        clip: true
        Rectangle {
            id: fill
            property real slide: 0
            readonly property bool indeterminate: parent.value < 0
            height: parent.height
            radius: 3
            color: Theme.accent
            width: indeterminate ? parent.width * 0.3 : parent.width * parent.value
            // A determinate bar starts at the left even if the sweep stopped halfway.
            x: indeterminate ? slide : 0
            NumberAnimation on slide {
                running: fill.indeterminate && win.visible
                loops: Animation.Infinite
                from: -fill.width
                to: fill.parent.width
                duration: 1200
                easing.type: Easing.InOutQuad
            }
        }
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: 20
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            TrafficSignal {
                layout: "vertical"
                allLightsOn: true
                diameter: 13
                padX: 6
                padY: 6
                Layout.alignment: Qt.AlignTop
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                AsbText {
                    Layout.fillWidth: true
                    font.pixelSize: Theme.titleSize
                    strong: true
                    wrapMode: Text.WordWrap
                    text: win.askPermission ? Theme.t("自动检查更新？", "Check for updates automatically?")
                        : win.stage === "checking" ? Theme.t("正在检查更新…", "Checking for updates…")
                        : win.stage === "upToDate" ? Theme.t("已是最新版本！", "You’re up to date!")
                        : win.stage === "available" ? Theme.t("Agent Signal Bar 有新版本可用！", "A new version of Agent Signal Bar is available!")
                        : win.stage === "downloading" ? Theme.t("正在下载更新…", "Downloading update…")
                        : win.stage === "verifying" ? Theme.t("正在准备安装…", "Preparing to install…")
                        : win.stage === "ready" ? Theme.t("准备安装", "Ready to Install")
                        : win.stage === "installing" ? Theme.t("正在安装更新…", "Installing update…")
                        : win.stage === "failed" ? Theme.t("更新出错！", "Update Error!")
                        : Theme.t("软件更新", "Software Update")
                }
                AsbText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    elide: Text.ElideNone
                    textFormat: Text.PlainText
                    visible: text.length > 0
                    text: win.askPermission
                        ? Theme.t("要让 Agent Signal Bar 自动检查更新吗？你也可以随时在 设置 → 关于 中手动检查。",
                                  "Should Agent Signal Bar automatically check for updates? You can always check manually in Settings → About.")
                        : win.stage === "upToDate" ? Theme.t("Agent Signal Bar " + App.version + " 是目前的最新版本。",
                                                             "Agent Signal Bar " + App.version + " is currently the newest version available.")
                        : win.stage === "available" ? Theme.t("Agent Signal Bar " + (win.u.latest || "") + " 现已推出，你的版本是 " + App.version + "。要现在下载吗？",
                                                              "Agent Signal Bar " + (win.u.latest || "") + " is now available—you have " + App.version + ". Would you like to download it now?")
                        : win.stage === "downloading" ? (win.u.progressText || "")
                        : win.stage === "ready" ? Theme.t("版本 " + (win.u.latest || "") + " 已下载并验证签名。安装后会重新启动 Agent Signal Bar。",
                                                          "Version " + (win.u.latest || "") + " is downloaded and its signature verified. Agent Signal Bar relaunches after installing.")
                        : win.stage === "installing" ? Theme.t("Agent Signal Bar 会退出，安装完成后重新启动。", "Agent Signal Bar quits now and relaunches when the installer is done.")
                        : win.stage === "failed" ? (win.u.error || "")
                        : (win.u.message || "")
                }
            }
        }

        Bar {
            visible: !win.askPermission && ["checking", "downloading", "verifying", "installing"].indexOf(win.stage) >= 0
            value: win.stage === "downloading" ? (win.u.progress !== undefined ? win.u.progress : -1) : -1
        }

        // Release notes: Markdown from generate_appcast, or HTML / plain text.
        AsbText {
            visible: win.showNotes
            text: Theme.t("更新说明：", "Release Notes:")
            strong: true
        }
        Rectangle {
            visible: win.showNotes
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.radiusGroup
            color: Theme.groupFill
            border.color: Theme.groupStroke
            Flickable {
                id: notes
                anchors.fill: parent
                anchors.margins: 12
                clip: true
                contentHeight: notesText.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                Text {
                    id: notesText
                    width: notes.width
                    wrapMode: Text.WordWrap
                    font.family: Theme.font
                    font.pixelSize: Theme.bodySize
                    color: Theme.text
                    linkColor: Theme.accent
                    textFormat: win.u.notesFormat === "markdown" ? Text.MarkdownText
                        : win.u.notesFormat === "plain-text" ? Text.PlainText : Text.RichText
                    text: (win.u.notes || "").length > 0 ? win.u.notes : Theme.t("这个版本没有附带更新说明。", "This version has no release notes.")
                    onLinkActivated: link => App.openUrl(link)
                }
            }
        }
        AsbText {
            visible: win.showNotes && (win.u.notesLink || "").length > 0
            text: "<a href=\"" + (win.u.notesLink || "") + "\">" + Theme.t("在 GitHub 上查看完整更新说明", "View full release notes on GitHub") + "</a>"
            textFormat: Text.StyledText
            linkColor: Theme.accent
            onLinkActivated: link => App.openUrl(link)
        }

        // Sparkle's "Automatically download and install updates" (in the alert and the permission prompt).
        RowLayout {
            visible: win.askPermission || (win.showNotes && App.prefs["SUEnableAutomaticChecks"] === true && win.u.informational !== true)
            spacing: 8
            AsbSwitch {
                checked: win.askPermission ? win.permissionInstall : App.prefs["SUAutomaticallyUpdate"] === true
                onToggled: checked => {
                    if (win.askPermission) win.permissionInstall = checked
                    else App.prefs["SUAutomaticallyUpdate"] = checked
                }
            }
            AsbText {
                text: win.askPermission ? Theme.t("自动下载并安装更新", "Automatically download and install updates")
                                        : Theme.t("以后自动下载并安装更新", "Automatically download and install updates in the future")
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            // Left: the secondary action of the stage.
            AsbButton {
                visible: !win.askPermission && win.stage === "available" && win.u.critical !== true
                text: Theme.t("跳过这个版本", "Skip This Version")
                onClicked: { App.skipUpdate(); win.close() }
            }
            AsbButton {
                visible: !win.askPermission && win.stage === "failed"
                text: Theme.t("打开下载页面", "Open Download Page")
                onClicked: { App.openUrl(win.u.releasesPage); win.close() }
            }
            Item { Layout.fillWidth: true }

            // Permission prompt.
            AsbButton {
                visible: win.askPermission
                text: Theme.t("不检查", "Don’t Check")
                onClicked: { App.answerUpdatePermission(false, false); win.close() }
            }
            AsbButton {
                visible: win.askPermission
                prominent: true
                text: Theme.t("自动检查", "Check Automatically")
                onClicked: { App.answerUpdatePermission(true, win.permissionInstall); win.close() }
            }

            // Update flow.
            AsbButton {
                visible: !win.askPermission && (win.stage === "checking" || win.stage === "downloading")
                text: Theme.t("取消", "Cancel")
                onClicked: { App.cancelUpdate(); win.close() }
            }
            AsbButton {
                visible: !win.askPermission && win.stage === "available"
                text: Theme.t("以后提醒我", "Remind Me Later")
                onClicked: win.close()
            }
            AsbButton {
                visible: !win.askPermission && win.stage === "available"
                prominent: true
                text: win.u.informational === true ? Theme.t("了解更多…", "Learn More…") : Theme.t("安装更新", "Install Update")
                onClicked: {
                    if (win.u.informational === true) { App.openUrl(win.u.link); win.close() }
                    else App.downloadUpdate()
                }
            }
            AsbButton {
                visible: !win.askPermission && win.stage === "ready"
                text: Theme.t("退出时安装", "Install on Quit")
                onClicked: win.close()
            }
            AsbButton {
                visible: !win.askPermission && win.stage === "ready"
                prominent: true
                text: Theme.t("安装并重新启动", "Install and Relaunch")
                onClicked: App.installUpdate()
            }
            AsbButton {
                visible: !win.askPermission && win.stage === "idle"
                prominent: true
                text: Theme.t("检查更新", "Check for Updates")
                onClicked: App.checkForUpdates()
            }
            AsbButton {
                visible: !win.askPermission && ["upToDate", "failed", "idle", "verifying"].indexOf(win.stage) >= 0
                prominent: win.stage === "upToDate" || win.stage === "failed"
                text: Theme.t("好", "OK")
                onClicked: win.close()
            }
        }
    }
}
