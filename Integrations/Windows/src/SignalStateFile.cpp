#include "SignalStateFile.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QLockFile>
#include <QSaveFile>
#include <QStandardPaths>
#include <QThread>

namespace asb {
namespace {

QString nonEmptyEnv(const char *name) { return qEnvironmentVariable(name).trimmed(); }

QString expandTilde(const QString &path) {
    if (path == "~") return QDir::homePath();
    if (path.startsWith("~/") || path.startsWith("~\\")) return QDir::homePath() + '/' + path.mid(2);
    return path;
}

enum class ReadResult { Ok, Missing, Failed };

// Retries briefly: on Windows another process (an indexer, an antivirus scan) can hold the
// file for a moment.
ReadResult readFile(const QString &path, QByteArray &data) {
    for (int attempt = 0; attempt < 5; ++attempt) {
        if (!QFileInfo::exists(path)) return ReadResult::Missing;
        QFile file(path);
        if (file.open(QIODevice::ReadOnly)) {
            data = file.readAll();
            if (file.error() == QFileDevice::NoError) return ReadResult::Ok;
        }
        QThread::msleep(20);
    }
    return ReadResult::Failed;
}

bool writeFile(const QString &path, const QByteArray &data) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    for (int attempt = 0; attempt < 5; ++attempt) {
        QSaveFile file(path);
        if (file.open(QIODevice::WriteOnly) && file.write(data) == data.size() && file.commit()) return true;
        QThread::msleep(20);
    }
    return false;
}

} // namespace

SignalStateFile::SignalStateFile(QString path) : m_path(std::move(path)) {}

QString SignalStateFile::defaultPath() {
    const QString explicitFile = nonEmptyEnv("AGENT_SIGNAL_LIGHT_STATE_FILE");
    if (!explicitFile.isEmpty()) return QDir::cleanPath(expandTilde(explicitFile));
    QString dir = nonEmptyEnv("AGENT_SIGNAL_LIGHT_STATE_DIR");
    if (dir.isEmpty()) dir = nonEmptyEnv("SIGNAL_LIGHT_STATE_DIR");
    if (!dir.isEmpty()) return QDir::cleanPath(expandTilde(dir) + "/status.json");
#ifdef Q_OS_WIN
    const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation); // %LOCALAPPDATA%
    return QDir::cleanPath(base + "/Agent Signal Bar/SignalState/status.json");
#else
    const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    return QDir::cleanPath(base + "/Agent Signal Bar (Windows port)/SignalState/status.json");
#endif
}

bool SignalStateFile::hasExplicitLocation() {
    return !nonEmptyEnv("AGENT_SIGNAL_LIGHT_STATE_FILE").isEmpty() || !nonEmptyEnv("AGENT_SIGNAL_LIGHT_STATE_DIR").isEmpty()
        || !nonEmptyEnv("SIGNAL_LIGHT_STATE_DIR").isEmpty();
}

std::optional<SignalSnapshot> SignalStateFile::update(const std::function<void(SignalStore &)> &change, qint64 now,
                                                      int lockTimeoutMs) {
    QDir().mkpath(QFileInfo(m_path).absolutePath());
    QLockFile lock(m_path + ".lock");
    lock.setStaleLockTime(10'000);
    if (!lock.tryLock(lockTimeoutMs)) return std::nullopt;

    QByteArray original;
    const ReadResult read = readFile(m_path, original);
    if (read == ReadResult::Failed) return std::nullopt;

    SignalStore store;
    if (read == ReadResult::Ok) {
        QJsonParseError error;
        const QJsonDocument document = QJsonDocument::fromJson(original, &error);
        if (error.error == QJsonParseError::NoError && document.isObject()) store.loadJson(document.object(), now);
        else store = SignalStore::staleDocument(now);
    }
    const QJsonObject before = store.toJson();
    change(store);
    const QJsonObject after = store.toJson();
    if (after != before) {
        if (!writeFile(m_path, QJsonDocument(after).toJson(QJsonDocument::Indented))) return std::nullopt;
    }
    return store.readSnapshot(now);
}

std::optional<SignalSnapshot> SignalStateFile::readSnapshot(qint64 now, int lockTimeoutMs) {
    std::optional<SignalSnapshot> snapshot;
    const auto result = update([&](SignalStore &store) { snapshot = store.readSnapshot(now); }, now, lockTimeoutMs);
    if (!result) return std::nullopt;
    return snapshot;
}

} // namespace asb
