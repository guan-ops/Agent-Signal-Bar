// Alert sound helpers. PlaySound has no volume control, so the bundled WAV files (16-bit mono
// PCM) are scaled in memory before they are played.
#pragma once

#include <QByteArray>
#include <QString>

namespace asb::sound {

// FloatingSignalSoundLevel.volume: soft 0.28, standard 0.55, loud 0.88.
double volume(const QString &level);

// The WAV with its 16-bit PCM samples multiplied by `volume` (clamped); any other format, or
// data that is not a RIFF/WAVE file, comes back unchanged.
QByteArray scaledWav(QByteArray wav, double volume);

} // namespace asb::sound
