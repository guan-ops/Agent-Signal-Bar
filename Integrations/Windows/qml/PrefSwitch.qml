import QtQuick
import AgentSignal

// A switch bound to one App.prefs key.
AsbSwitch {
    property string key
    checked: App.prefs[key] === true
    onToggled: checked => App.prefs[key] = checked
}
