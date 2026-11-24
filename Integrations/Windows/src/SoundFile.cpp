#include "SoundFile.h"

#include <QtEndian>
#include <algorithm>
#include <cmath>

namespace asb::sound {

double volume(const QString &level) {
    if (level == QLatin1String("soft")) return 0.28;
    if (level == QLatin1String("loud")) return 0.88;
    return 0.55;
}

QByteArray scaledWav(QByteArray wav, double volume) {
    if (wav.size() < 12 || !wav.startsWith("RIFF") || wav.mid(8, 4) != "WAVE") return wav;
    qsizetype pos = 12;
    quint16 format = 0;
    quint16 bits = 0;
    while (pos + 8 <= wav.size()) {
        const QByteArray id = wav.mid(pos, 4);
        const quint32 length = qFromLittleEndian<quint32>(wav.constData() + pos + 4);
        const qsizetype body = pos + 8;
        if (id == "fmt " && length >= 16 && body + 16 <= wav.size()) {
            format = qFromLittleEndian<quint16>(wav.constData() + body);
            bits = qFromLittleEndian<quint16>(wav.constData() + body + 14);
        } else if (id == "data") {
            if (format != 1 || bits != 16) return wav;
            const qsizetype end = std::min<qsizetype>(wav.size(), body + qsizetype(length));
            char *data = wav.data();
            for (qsizetype i = body; i + 1 < end; i += 2) {
                const double sample = qFromLittleEndian<qint16>(data + i) * volume;
                qToLittleEndian<qint16>(qint16(std::clamp(std::lround(sample), -32768L, 32767L)), data + i);
            }
            return wav;
        }
        pos = body + qsizetype(length) + (length & 1);
    }
    return wav;
}

} // namespace asb::sound
