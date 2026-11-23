import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import AgentSignal
import "DemoData.js" as Demo

// FloatingSignalWindowController: an always-on-top, draggable, resizable desktop lamp with
// corner badges (running agents, quota, tokens), each opening its panel, as on macOS.
Window {
    id: win
    readonly property bool vertical: App.prefs.floatingLayout !== "horizontal"
    readonly property real visualScale: {
        switch (App.prefs.floatingSize) {
        case "compact": return 1.15
        case "large": return 1.95
        case "custom": return Math.min(maxScale, Math.max(minScale, App.prefs.floatingScale))
        default: return 1.5
        }
    }
    // FloatingSignalScale.minimumVisualScale / maximumVisualScale; the menu steps by 0.18.
    readonly property real minScale: 0.85
    readonly property real maxScale: 2.6
    readonly property alias popoverWindow: panel
    readonly property var infoSessions: App.paused ? [] : (App.liveData ? App.sessions : Demo.sessions(Theme.t))
    function showContextMenu() { contextMenu.popup() }

    // FloatingSignalPanelLayout (macOS): 24 px round badges, a 2 px gap, badges overlapping the
    // lamp by 4 px; the window keeps room for badges on the top, left and right and for the
    // resize handle below the lamp.
    readonly property int badgeSize: 24
    readonly property int controlGap: 2
    readonly property int badgeOverlap: 4
    readonly property int resizeHandleSize: 20
    readonly property int edgeOutset: badgeSize + controlGap
    readonly property int trailingOutset: Math.max(badgeSize, resizeHandleSize) + controlGap
    readonly property int bottomOutset: resizeHandleSize + controlGap

    // infoBadgeOffset: a badge's top-left for each corner (FloatingSignalInfoBadgeCorner values).
    function badgePoint(corner) {
        const leadingX = edgeOutset - badgeSize + badgeOverlap
        if (corner === "top-right") return Qt.point(edgeOutset + lamp.width - badgeOverlap, 0)
        if (corner === "bottom-left") return Qt.point(leadingX, edgeOutset + lamp.height - controlGap)
        return Qt.point(leadingX, 0)
    }

    // Badge corners as on macOS: each badge keeps its own corner (defaults: running agents top
    // right, quota top left, tokens bottom left); a later badge whose corner is taken by an
    // earlier visible one moves to the first free corner.
    readonly property var corners: ["top-left", "top-right", "bottom-left"]
    readonly property bool infoVisible: App.prefs.badgeRunning && infoSessions.length > 0
    // floatingQuotaContent: the lamp's agent's quota when live (Codex once read; Claude always,
    // showing "—" and the reason in its panel until a fresh snapshot), else the demo quota.
    readonly property var quotaData: App.liveData && App.quota[win.tokenProvider] !== undefined ? App.quota[win.tokenProvider] : null
    readonly property bool quotaVisible: App.prefs.badgeQuota && !App.paused
        && (!App.liveData || (win.quotaData !== null && (win.quotaData.ready || win.tokenProvider === "claude")))
    readonly property bool tokenVisible: App.prefs.badgeToken && !App.paused && win.tokenUsage !== null
    // The token badge counts the lamp's agent (isClaudeFloatingUsage): the local scan when live.
    readonly property string tokenProvider: App.liveData ? (App.usage.floatingProvider || "codex") : "codex"
    readonly property var tokenUsage: App.liveData ? (App.usage[tokenProvider] || null) : Demo.usage(Theme.t)
    function firstFreeCorner(preferred, occupied) {
        if (occupied.indexOf(preferred) < 0) return preferred
        for (const c of corners) if (occupied.indexOf(c) < 0) return c
        return preferred
    }
    readonly property string infoCorner: App.prefs.floatingSignalInfoBadgeCorner
    readonly property string quotaCorner: firstFreeCorner(App.prefs.floatingSignalQuotaBadgeCorner,
                                                          infoVisible ? [infoCorner] : [])
    readonly property string tokenCorner: firstFreeCorner(App.prefs.floatingSignalTokenBadgeCorner,
                                                          (infoVisible ? [infoCorner] : []).concat(quotaVisible ? [quotaCorner] : []))
    function resolvedCorner(kind) { return kind === "info" ? infoCorner : kind === "quota" ? quotaCorner : tokenCorner }
    function cornerKey(kind) {
        return kind === "info" ? "floatingSignalInfoBadgeCorner"
             : kind === "quota" ? "floatingSignalQuotaBadgeCorner" : "floatingSignalTokenBadgeCorner"
    }
    function visibleBadges(except) {
        const out = []
        if (infoVisible && except !== "info") out.push("info")
        if (quotaVisible && except !== "quota") out.push("quota")
        if (tokenVisible && except !== "token") out.push("token")
        return out
    }
    // nearestInfoBadgeCorner + moveBadge: a dropped badge snaps to the corner nearest its centre
    // and swaps with a visible badge already there; the visible badges' corners are then saved.
    function dropBadge(kind, fromCorner, centreX, centreY) {
        let target = fromCorner
        let best = Infinity
        for (const c of corners) {
            const p = badgePoint(c)
            const d = Math.pow(p.x + badgeSize / 2 - centreX, 2) + Math.pow(p.y + badgeSize / 2 - centreY, 2)
            if (d < best) {
                best = d
                target = c
            }
        }
        if (target !== fromCorner) {
            const occupying = visibleBadges(kind).find(k => resolvedCorner(k) === target)
            if (occupying) App.prefs[cornerKey(occupying)] = fromCorner
        }
        App.prefs[cornerKey(kind)] = target
        for (const k of visibleBadges("")) {
            if (App.prefs[cornerKey(k)] !== resolvedCorner(k)) App.prefs[cornerKey(k)] = resolvedCorner(k)
        }
    }

    // Opens a badge's panel, or closes it when that panel is already open.
    function togglePanel(mode, corner) {
        if (panel.visible && panel.mode === mode) {
            panel.hide()
            return
        }
        panel.mode = mode
        panel.corner = corner
        panel.present()
    }

    function stepScale(delta) {
        App.prefs.floatingScale = Math.min(maxScale, Math.max(minScale, visualScale + delta))
        App.prefs.floatingSize = "custom"
    }

    title: "Agent Signal Bar Floating Light"
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: "transparent"
    width: edgeOutset + lamp.implicitWidth + trailingOutset
    height: edgeOutset + lamp.implicitHeight + bottomOutset

    function placeDefault() {
        const p = App.floatingPosition(App.prefs.floatingX, App.prefs.floatingY, width, height)
        x = p.x
        y = p.y
    }
    Component.onCompleted: placeDefault()
    onXChanged: saveTimer.restart()
    onYChanged: saveTimer.restart()
    Timer {
        id: saveTimer
        interval: 400
        onTriggered: if (win.visible && App.captureDir.length === 0) {
            App.prefs.floatingX = win.x
            App.prefs.floatingY = win.y
        }
    }

    TrafficSignal {
        id: lamp
        x: win.edgeOutset
        y: win.edgeOutset
        layout: win.vertical ? "vertical" : "horizontal"
        diameter: 16 * win.visualScale
    }

    // The lamp drags the window. A left click also opens the running-agents panel (macOS opens
    // it from the badge only; kept here so the panel is reachable with the badge turned off).
    MouseArea {
        anchors.fill: lamp
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property point pressPos
        property bool dragged: false
        onPressed: mouse => {
            pressPos = Qt.point(mouse.x, mouse.y)
            dragged = false
        }
        onPositionChanged: mouse => {
            if (!dragged && (Math.abs(mouse.x - pressPos.x) > 3 || Math.abs(mouse.y - pressPos.y) > 3)) {
                dragged = true
                panel.hide() // it would stay behind, detached from the lamp
                win.startSystemMove()
            }
        }
        onReleased: mouse => {
            if (dragged) return
            if (mouse.button === Qt.RightButton) {
                panel.hide()
                contextMenu.popup()
            } else {
                win.togglePanel("info", win.infoCorner)
            }
        }
    }

    // asbBadgeBackground: a 24 px circle in the group fill with a hairline and a soft shadow;
    // badgeFontSize shrinks the bold digits as the text grows. A click opens the badge's panel;
    // a drag (FloatingSignalInfoBadgeDragView: 3 px threshold) moves it to another corner.
    component Badge: Item {
        id: badge
        property string kind // info | quota | token
        readonly property string corner: win.resolvedCorner(kind)
        property alias text: label.text
        property color textColor: Theme.text
        property point dragOffset: Qt.point(0, 0)
        property bool dragging: false
        signal clicked()
        readonly property point origin: win.badgePoint(corner)
        x: origin.x + dragOffset.x
        y: origin.y + dragOffset.y
        z: dragging ? 2 : 1
        width: win.badgeSize
        height: win.badgeSize
        Rectangle { // shadow: black 22 %, 1 px down
            anchors.fill: parent
            anchors.topMargin: 1
            anchors.bottomMargin: -1
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.22)
        }
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.groupFill
            border.color: Theme.groupStroke
            border.width: 1
        }
        AsbText {
            id: label
            anchors.centerIn: parent
            font.pixelSize: text.length > 3 ? 7 : text.length > 2 ? 9 : text.length > 1 ? 11 : 13
            font.weight: Font.Bold
            color: badge.textColor
            elide: Text.ElideNone
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: badge.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            property point start
            function reset() {
                badge.dragOffset = Qt.point(0, 0)
                badge.dragging = false
            }
            onPressed: mouse => {
                start = mapToGlobal(mouse.x, mouse.y)
                badge.dragging = false
            }
            onPositionChanged: mouse => {
                if (!pressed) return
                const p = mapToGlobal(mouse.x, mouse.y)
                const dx = p.x - start.x
                const dy = p.y - start.y
                if (!badge.dragging && Math.hypot(dx, dy) < 3) return
                if (!badge.dragging) {
                    badge.dragging = true
                    panel.hide()
                }
                badge.dragOffset = Qt.point(dx, dy)
            }
            onReleased: {
                if (!badge.dragging) {
                    badge.clicked()
                    return
                }
                win.dropBadge(badge.kind, badge.corner, badge.x + win.badgeSize / 2, badge.y + win.badgeSize / 2)
                reset()
            }
            onCanceled: reset()
        }
    }
    Badge {
        readonly property int running: win.infoSessions.length
        visible: win.infoVisible
        kind: "info"
        text: running > 99 ? "99+" : String(running)
        onClicked: win.togglePanel("info", corner)
    }
    // Quota and token badges wait for the usage data layer; live runs hide them rather than
    // show demo numbers next to a live lamp.
    Badge {
        visible: win.quotaVisible
        kind: "quota"
        text: win.quotaData ? win.quotaData.badgeText : "76%"
        textColor: Theme.toneForeground(win.quotaData ? win.quotaData.badgeTone : "positive")
        onClicked: win.togglePanel("quota", corner)
    }
    Badge {
        visible: win.tokenVisible
        kind: "token"
        text: win.tokenUsage ? win.tokenUsage.badgeText : "--"
        textColor: Theme.accent
        onClicked: win.togglePanel("token", corner)
    }

    // resizeHandleTarget: a hotspot over the lamp's bottom-right corner; the handle itself sits
    // just outside that corner and shows while hovered or dragged. Dragging switches to "custom".
    MouseArea {
        id: resizeArea
        x: lamp.x + lamp.width - win.resizeHandleSize
        y: lamp.y + lamp.height - win.resizeHandleSize
        width: win.resizeHandleSize + win.controlGap + win.resizeHandleSize
        height: width
        hoverEnabled: true
        cursorShape: Qt.SizeFDiagCursor
        property real startX
        property real startScale
        onPressed: mouse => {
            startX = mapToGlobal(mouse.x, mouse.y).x
            startScale = win.visualScale
            panel.hide()
        }
        onPositionChanged: mouse => {
            if (!pressed) return
            const dx = mapToGlobal(mouse.x, mouse.y).x - startX
            App.prefs.floatingSize = "custom"
            App.prefs.floatingScale = Math.min(win.maxScale, Math.max(win.minScale, startScale + dx / 60))
        }
        Icon {
            name: "resize"
            size: 12
            x: parent.width - win.resizeHandleSize + (win.resizeHandleSize - size) / 2
            y: parent.height - win.resizeHandleSize + (win.resizeHandleSize - size) / 2
            color: Theme.secondary
            opacity: resizeArea.containsMouse || resizeArea.pressed ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }
        }
    }

    // Styled like the tray menu: the Basic style's white menu showed the dark theme's pale text.
    component LampMenuItem: MenuItem {
        id: item
        implicitWidth: 180
        implicitHeight: 28
        contentItem: AsbText {
            text: item.text
            leftPadding: 4
            color: item.highlighted ? Theme.textOnAccent : Theme.text
            opacity: item.enabled ? 1 : 0.4
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 5
            color: item.highlighted && item.enabled ? Theme.accent : "transparent"
        }
    }
    component LampMenuSeparator: MenuSeparator {
        contentItem: Rectangle { implicitHeight: 1; color: Theme.separator }
    }

    // The macOS context menu, item for item.
    Menu {
        id: contextMenu
        popupType: Popup.Window
        padding: 5
        background: Rectangle {
            implicitWidth: 190
            radius: 8
            color: Theme.panelBg
            border.color: Theme.panelStroke
        }
        LampMenuItem { text: Theme.t("隐藏悬浮灯", "Hide Floating Signal"); onTriggered: App.prefs.floatingEnabled = false }
        LampMenuItem { text: Theme.t("设置...", "Settings..."); onTriggered: App.openSettings("light") }
        LampMenuSeparator {}
        LampMenuItem {
            text: Theme.t("缩小", "Smaller")
            enabled: win.visualScale > win.minScale + 0.01
            onTriggered: win.stepScale(-0.18)
        }
        LampMenuItem {
            text: Theme.t("放大", "Larger")
            enabled: win.visualScale < win.maxScale - 0.01
            onTriggered: win.stepScale(0.18)
        }
        LampMenuSeparator {}
        LampMenuItem {
            text: win.vertical ? Theme.t("切换为横向", "Switch to Horizontal") : Theme.t("切换为竖向", "Switch to Vertical")
            onTriggered: App.prefs.floatingLayout = win.vertical ? "horizontal" : "vertical"
        }
        LampMenuSeparator {}
        LampMenuItem {
            text: App.prefs.soundEnabled ? Theme.t("关闭声音提醒", "Turn Sound Off") : Theme.t("开启声音提醒", "Turn Sound On")
            onTriggered: App.prefs.soundEnabled = !App.prefs.soundEnabled
        }
        LampMenuItem {
            text: Theme.t("试听完成音", "Preview Completion Sound")
            onTriggered: App.previewSound("completion", App.prefs.completionSound)
        }
        LampMenuItem {
            text: Theme.t("试听闪烁音", "Preview Flash Sound")
            onTriggered: App.previewSound("waiting", App.prefs.waitingSound)
        }
    }

    // FloatingSignalInfoPopoverView card: status dot, bold title, "status · time" caption.
    component InfoCard: Item {
        id: card
        property string title
        property string subtitle
        property string signalState // not `state`: Item already has one
        Layout.fillWidth: true
        implicitHeight: Math.max(40, texts.implicitHeight + 14)
        Rectangle {
            x: 9
            anchors.verticalCenter: parent.verticalCenter
            width: 7
            height: 7
            radius: 3.5
            color: Theme.toneLamp(Theme.toneForState(card.signalState))
        }
        ColumnLayout {
            id: texts
            x: 24
            width: parent.width - 24 - 9
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            AsbText { text: card.title; strong: true; textFormat: Text.PlainText; Layout.fillWidth: true }
            AsbText { text: card.subtitle; caption: true; secondary: true; textFormat: Text.PlainText; Layout.fillWidth: true }
        }
    }

    // The badges' panels (FloatingSignal{Info,Quota}PanelAnchor): 250 px wide, anchored above
    // the badge that opened them.
    Window {
        id: panel
        property string mode: "info"   // info | quota | token
        property string corner: "top-right"
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "transparent"
        width: 250
        height: Math.max(44, surface.implicitHeight)

        function place() {
            const b = win.badgePoint(corner)
            const p = App.badgePanelPosition(win.x + b.x, win.y + b.y, win.badgeSize, width, height)
            x = p.x
            y = p.y
        }
        function present() {
            place()
            show()
            requestActivate()
        }
        function toggle() { win.togglePanel("info", win.infoCorner) }

        // The content lays out after the mode changes; keep the bottom edge above the badge.
        onHeightChanged: if (visible) place()
        onActiveChanged: if (!active && visible && App.captureDir.length === 0) hide()
        // Qt counts the panel as active while its parent, the lamp, has focus, and tells only
        // the window that loses focus: when focus moves on from the lamp, close it here.
        Connections {
            target: win
            function onActiveChanged() {
                if (!win.active && panel.visible && App.captureDir.length === 0) panel.hide()
            }
        }

        Rectangle {
            id: surface
            anchors.fill: parent
            implicitHeight: column.implicitHeight + 12
            radius: Theme.radiusPanel
            color: Theme.panelBg
            border.color: Theme.panelStroke
            ColumnLayout {
                id: column
                x: 6
                y: 6
                width: parent.width - 12
                spacing: 7

                // Running agents.
                Repeater {
                    model: panel.mode === "info" ? win.infoSessions : []
                    InfoCard {
                        required property var modelData
                        title: modelData.title
                        subtitle: modelData.time ? modelData.detail + " · " + modelData.time : modelData.detail
                        signalState: modelData.state
                    }
                }
                InfoCard {
                    visible: panel.mode === "info" && win.infoSessions.length === 0
                    title: Theme.t("暂无运行中的 Agent", "No active agent sessions")
                    subtitle: Theme.stateSummary(App.displayState)
                    signalState: App.displayState
                }

                // Quota (FloatingSignalQuotaPopoverView): the limit and its windows; clicking a
                // window makes it the badge's.
                RowLayout {
                    visible: panel.mode === "quota" && win.quotaData !== null
                    Layout.fillWidth: true
                    Layout.leftMargin: 9
                    Layout.rightMargin: 9
                    Layout.topMargin: 3
                    AsbText {
                        text: win.quotaData ? (win.tokenProvider === "claude" ? "Claude" : win.quotaData.limitTitle) : ""
                        strong: true
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    AsbText { text: win.quotaData ? win.quotaData.updated : ""; caption: true; secondary: true }
                }
                AsbText {
                    visible: panel.mode === "quota" && text.length > 0
                    text: win.quotaData ? (win.quotaData.status || "") : ""
                    caption: true
                    color: Theme.toneForeground("caution")
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    Layout.leftMargin: 9
                    Layout.rightMargin: 9
                }
                Repeater {
                    model: panel.mode !== "quota" ? []
                        : win.quotaData ? win.quotaData.windows
                        : Demo.account(Theme.t).quotas.map(q => ({ title: q.title, remaining: q.remaining, reset: q.reset,
                                                                   valueText: q.remaining + "%", selected: false, key: "", id: "" }))
                    Rectangle {
                        id: quotaRow
                        required property var modelData
                        readonly property bool selectable: win.quotaData !== null
                            && (win.tokenProvider === "claude" || (modelData.key || "").length > 0)
                        Layout.fillWidth: true
                        implicitHeight: quotaLine.implicitHeight + 8
                        radius: Theme.radiusControl
                        color: quotaArea.containsMouse && selectable ? Theme.hoverFill : "transparent"
                        QuotaLine {
                            id: quotaLine
                            x: 9
                            y: 4
                            width: parent.width - 18 - (quotaRow.modelData.selected ? 18 : 0)
                            compact: true
                            title: quotaRow.modelData.title
                            valueText: quotaRow.modelData.valueText
                            remainingPercent: quotaRow.modelData.remaining
                            detail: quotaRow.modelData.reset
                        }
                        Icon {
                            visible: quotaRow.modelData.selected === true
                            anchors.right: parent.right
                            anchors.rightMargin: 9
                            anchors.verticalCenter: parent.verticalCenter
                            name: "check"
                            size: 13
                            color: Theme.accent
                        }
                        MouseArea {
                            id: quotaArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: quotaRow.selectable
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (win.tokenProvider === "claude") App.prefs.claudeFloatingQuotaWindow = quotaRow.modelData.id
                                else App.prefs.floatingSignalQuotaBadgeWindow = quotaRow.modelData.key
                            }
                        }
                    }
                }

                // Device tokens (FloatingSignalTokenPopoverView): today and the last 30 days; the
                // chosen row is what the badge counts.
                RowLayout {
                    visible: panel.mode === "token"
                    Layout.fillWidth: true
                    Layout.leftMargin: 9
                    Layout.rightMargin: 9
                    Layout.topMargin: 3
                    AsbText {
                        text: (win.tokenProvider === "claude" ? "Claude" : "Codex") + Theme.t(" · 本机", " · Device")
                        strong: true
                        Layout.fillWidth: true
                    }
                    AsbText {
                        visible: win.tokenUsage !== null && win.tokenUsage.scanning === true
                        text: Theme.t("扫描中…", "Scanning…")
                        caption: true
                        secondary: true
                    }
                }
                TokenChoiceRow {
                    visible: panel.mode === "token"
                    windowKey: "today"
                    usage: win.tokenUsage ? win.tokenUsage.today : null
                }
                Rectangle {
                    visible: panel.mode === "token"
                    Layout.fillWidth: true
                    Layout.leftMargin: 9
                    Layout.rightMargin: 9
                    height: 1
                    color: Theme.separator
                }
                TokenChoiceRow {
                    visible: panel.mode === "token"
                    windowKey: "last-30-days"
                    usage: win.tokenUsage ? win.tokenUsage.month : null
                }
                AsbText {
                    visible: panel.mode === "token" && text.length > 0
                    text: App.liveData ? (App.usage.rateNote || "") : ""
                    caption: true
                    color: Theme.tertiary
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    Layout.leftMargin: 9
                    Layout.rightMargin: 9
                }
            }
        }
    }

    // FloatingUsageChoiceRow: title, cost line and a check on the window the badge shows.
    component TokenChoiceRow: Rectangle {
        id: choice
        property string windowKey
        property var usage
        readonly property bool selected: (App.prefs.floatingSignalTokenBadgeWindow || "today") === windowKey
        Layout.fillWidth: true
        implicitHeight: choiceColumn.implicitHeight + 12
        radius: Theme.radiusControl
        color: choiceArea.containsMouse ? Theme.hoverFill : "transparent"
        ColumnLayout {
            id: choiceColumn
            x: 9
            y: 6
            width: parent.width - 18 - 18
            spacing: 2
            AsbText {
                text: choice.usage ? choice.usage.titleLine : ""
                strong: true
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            AsbText {
                text: choice.usage ? choice.usage.costLine : ""
                caption: true
                secondary: true
                Layout.fillWidth: true
            }
        }
        Icon {
            visible: choice.selected
            anchors.right: parent.right
            anchors.rightMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            name: "check"
            size: 13
            color: Theme.accent
        }
        MouseArea {
            id: choiceArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: App.prefs.floatingSignalTokenBadgeWindow = choice.windowKey
        }
    }
}
