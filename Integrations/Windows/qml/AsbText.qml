import QtQuick

// Text with the ASB defaults: body size, primary color, app font.
Text {
    property bool strong: false
    property bool secondary: false
    property bool caption: false
    font.family: Theme.font
    font.variableAxes: Theme.fontAxes
    font.pixelSize: caption ? Theme.captionSize : Theme.bodySize
    font.weight: strong ? Font.DemiBold : Font.Normal
    color: secondary ? Theme.secondary : Theme.text
    elide: Text.ElideRight
    renderType: Text.NativeRendering
}
