#include "TrayIconRenderer.h"

#include <QPainter>
#include <QPainterPath>
#include <QSettings>
#include <algorithm>

namespace {

QColor lampColor(asb::LampColor color) {
    switch (color) {
    case asb::LampColor::Green: return QColor::fromRgbF(0.16f, 0.78f, 0.34f);
    case asb::LampColor::Yellow: return QColor::fromRgbF(0.97f, 0.72f, 0.16f);
    case asb::LampColor::Red: return QColor::fromRgbF(0.94f, 0.20f, 0.18f);
    }
    return Qt::gray;
}

QColor withAlpha(QColor color, double alpha) {
    color.setAlphaF(static_cast<float>(std::clamp(alpha, 0.0, 1.0)));
    return color;
}

void drawLamp(QPainter &p, const QPointF &center, double diameter, asb::LampColor color, const TrayIconSpec &spec,
              const QColor &foreground) {
    using namespace asb;
    const bool minimal = spec.style == QLatin1String("macOS");
    const DisplayState state = displayState(spec.signal);
    const QColor secondary = foreground;
    const double r = diameter / 2;

    // Base disc (TrafficSignalLamp.inactiveFill / baseStrokeColor).
    QColor base;
    QColor stroke;
    if (state == DisplayState::Paused) base = withAlpha(secondary, minimal ? 0.72 : 0.36);
    else if (state == DisplayState::Stale) base = withAlpha(secondary, minimal ? 0.50 : 0.28);
    else base = minimal ? QColor(Qt::transparent) : withAlpha(secondary, 0.22);
    if (state == DisplayState::Paused || state == DisplayState::Stale) stroke = minimal ? withAlpha(foreground, 0.92) : withAlpha(secondary, 0.14);
    else if (minimal) stroke = withAlpha(foreground, 0.92);
    else if (spec.style == QLatin1String("singleLamp")) stroke = withAlpha(secondary, 0.35);
    else stroke = withAlpha(secondary, 0.10);

    const double strokeWidth = std::max(0.8, diameter * 0.09);
    p.setPen(QPen(stroke, strokeWidth));
    p.setBrush(base);
    p.drawEllipse(center, r - strokeWidth / 2, r - strokeWidth / 2);

    const double value = intensity(color, spec.signal, spec.tick, false, spec.customization);
    if (value <= 0) return;
    const double s = visualLampScale(scale(color, spec.signal, spec.tick, false, spec.customization), value,
                                     minimal ? VisualStyle::MacOS : VisualStyle::TrafficLight,
                                     BreathingStrength::Pronounced);
    const double lit = r * s;
    // Soft glow (shadow radius 1.5–1.8 pt in the menu bar renderer).
    p.setPen(Qt::NoPen);
    p.setBrush(withAlpha(lampColor(color), value * 0.35));
    p.drawEllipse(center, lit + diameter * 0.12, lit + diameter * 0.12);
    const QColor fill = withAlpha(lampColor(color), value);
    p.setPen(QPen(minimal ? fill : QColor(255, 255, 255, 51), strokeWidth));
    p.setBrush(fill);
    p.drawEllipse(center, lit - strokeWidth / 2, lit - strokeWidth / 2);
    if (value > 0.7 && !minimal && diameter >= 7) {
        const double hd = std::max(diameter * 0.34, 1.5) * s;
        const QPointF origin = center - QPointF(lit, lit) + QPointF(diameter * 0.18, diameter * 0.18) * s;
        p.setPen(Qt::NoPen);
        p.setBrush(QColor(255, 255, 255, 97));
        p.drawEllipse(QRectF(origin, QSizeF(hd, hd)));
    }
}

} // namespace

QImage TrayIconRenderer::render(const TrayIconSpec &spec, int size) {
    QImage image(size, size, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    QPainter p(&image);
    p.setRenderHint(QPainter::Antialiasing);

    const QColor foreground = spec.lightTaskbar ? QColor(0, 0, 0, 220) : QColor(255, 255, 255, 235);
    const double S = size;

    if (spec.style == QLatin1String("singleLamp")) {
        const auto color = asb::dominantColor(spec.signal, spec.tick, false, spec.customization);
        drawLamp(p, QPointF(S / 2, S / 2), S * 0.62, color.value_or(asb::LampColor::Green), spec, foreground);
        return image;
    }

    const bool vertical = spec.layout == QLatin1String("vertical");
    const bool classic = spec.style == QLatin1String("trafficLight");
    // Lamps ordered red, yellow, green (left→right / top→bottom), as on macOS.
    const asb::LampColor order[3] = {asb::LampColor::Red, asb::LampColor::Yellow, asb::LampColor::Green};
    const double diameter = classic ? S * (vertical ? 0.27 : 0.25) : S * 0.27;
    const double spacing = classic ? S * 0.06 : S * 0.08;
    const double run = diameter * 3 + spacing * 2;

    if (classic) {
        // Housing: black 0.88 rounded rectangle with a 12 % white hairline.
        const double pad = S * 0.07;
        QRectF housing = vertical ? QRectF(0, 0, diameter + pad * 2, run + pad * 2)
                                  : QRectF(0, 0, run + pad * 2, diameter + pad * 2);
        housing.moveCenter(QPointF(S / 2, S / 2));
        p.setPen(QPen(QColor(255, 255, 255, 31), std::max(1.0, S / 32)));
        p.setBrush(QColor(0, 0, 0, 224));
        const double radius = std::min(housing.width(), housing.height()) * 0.3;
        p.drawRoundedRect(housing, radius, radius);
    }

    for (int i = 0; i < 3; ++i) {
        const double offset = -run / 2 + diameter / 2 + i * (diameter + spacing);
        const QPointF center = vertical ? QPointF(S / 2, S / 2 + offset) : QPointF(S / 2 + offset, S / 2);
        drawLamp(p, center, diameter, order[i], spec, foreground);
    }
    return image;
}

QIcon TrayIconRenderer::icon(const TrayIconSpec &spec) {
    QIcon icon;
    for (int size : {16, 20, 24, 32, 40, 48, 64}) icon.addPixmap(QPixmap::fromImage(render(spec, size)));
    return icon;
}

bool TrayIconRenderer::taskbarUsesLightTheme() {
#ifdef Q_OS_WIN
    QSettings personalize("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                          QSettings::NativeFormat);
    return personalize.value("SystemUsesLightTheme", 0).toInt() == 1;
#else
    return false;
#endif
}
