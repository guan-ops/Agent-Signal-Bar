import QtQuick
import QtQuick.Controls.Basic
import AgentSignal

// A masked single-line field for pasted cookies (the macOS SecureField): the text is never shown
// and is cleared after it is handed to the app.
TextField {
    id: root
    echoMode: TextInput.Password
    passwordCharacter: "•"
    implicitHeight: 26
    font.pixelSize: Theme.bodySize
    font.family: App.uiFont
    font.variableAxes: Theme.fontAxes
    color: Theme.text
    placeholderTextColor: Theme.tertiary
    selectByMouse: true
    leftPadding: 8
    rightPadding: 8
    background: Rectangle {
        radius: Theme.radiusControl
        color: Theme.controlBg
        border.color: root.activeFocus ? Theme.accent : Theme.controlStroke
    }
}
