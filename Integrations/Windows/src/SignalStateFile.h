// status.json shared by the app and agent-signal.exe (the Claude Code hook). Every read and
// write happens under <file>.lock. A missing file is an empty document; a file that exists
// but cannot be opened (a transient Windows sharing violation, say) fails the operation and
// is never overwritten. A file that opens but does not decode becomes {aggregate: stale},
// as on macOS.
#pragma once

#include "SignalStore.h"

#include <functional>
#include <optional>

namespace asb {

class SignalStateFile {
public:
    explicit SignalStateFile(QString path);

    // AGENT_SIGNAL_LIGHT_STATE_FILE, else AGENT_SIGNAL_LIGHT_STATE_DIR / SIGNAL_LIGHT_STATE_DIR +
    // status.json, else %LOCALAPPDATA%\Agent Signal Bar\SignalState\status.json on Windows.
    // Other systems (development builds) use "Agent Signal Bar (Windows port)" so they never
    // touch the macOS app's own state file.
    static QString defaultPath();
    // True when one of the environment variables above chose the location.
    static bool hasExplicitLocation();

    const QString &path() const { return m_path; }

    // Loads the store, lets `change` modify it, and writes it back if the document changed.
    // nullopt when the lock or the file could not be had in time (nothing is written then).
    std::optional<SignalSnapshot> update(const std::function<void(SignalStore &)> &change, qint64 now,
                                         int lockTimeoutMs);
    // SignalStateStore.readSnapshot: prunes expired sessions and persists that.
    std::optional<SignalSnapshot> readSnapshot(qint64 now, int lockTimeoutMs);

private:
    QString m_path;
};

} // namespace asb
