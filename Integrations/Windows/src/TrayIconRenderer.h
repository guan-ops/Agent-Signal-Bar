#pragma once

#include "SignalModel.h"

#include <QIcon>
#include <QImage>
#include <QString>

// Draws the notification-area icon with TrafficSignalView's lamp rules (colors, inactive
// fills, highlight, glow, breathing scale). The geometry is new: Windows tray icons are
// square, so SignalIconGeometry's wide menu-bar metrics are not reused.
struct TrayIconSpec {
    QString signal = QStringLiteral("idle");
    int tick = 0;
    QString style = QStringLiteral("trafficLight"); // trafficLight | macOS | singleLamp
    QString layout = QStringLiteral("horizontal");  // horizontal | vertical
    bool lightTaskbar = false;
    asb::EffectCustomization customization;

    bool operator==(const TrayIconSpec &) const = default;
};

class TrayIconRenderer {
public:
    static QImage render(const TrayIconSpec &spec, int size);
    static QIcon icon(const TrayIconSpec &spec);
    // Windows 10/11 taskbar theme (SystemUsesLightTheme); false elsewhere.
    static bool taskbarUsesLightTheme();
};
