#include "DebugLog.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLoggingCategory>
#include <QMutex>
#include <QScopeGuard>
#include <QStandardPaths>

namespace asb::debuglog {
namespace {

constexpr qint64 kMaxBytes = 2 * 1024 * 1024;

// Recursive, and writeLine() sets t_writing: a warning raised by QFile while writing must
// neither deadlock nor write itself.
QRecursiveMutex &mutex() {
    static QRecursiveMutex m;
    return m;
}

thread_local bool t_writing = false;
bool g_enabled = false;
int g_minimumRank = 1; // see rank()
QtMessageHandler g_previous = nullptr;
bool g_installed = false;

// QtMsgType is not ordered by severity (QtInfoMsg is 4).
int rank(QtMsgType type) {
    switch (type) {
    case QtDebugMsg: return 0;
    case QtInfoMsg: return 1;
    case QtWarningMsg: return 2;
    case QtCriticalMsg: return 3;
    case QtFatalMsg: return 4;
    }
    return 2;
}

void writeLine(const QString &message) {
    // Caller holds the mutex.
    t_writing = true;
    const auto done = qScopeGuard([] { t_writing = false; });
    const QString file = path();
    QDir().mkpath(QFileInfo(file).absolutePath());
    if (QFileInfo(file).size() > kMaxBytes) {
        QFile::remove(file + ".1");
        QFile::rename(file, file + ".1");
    }
    QFile out(file);
    if (!out.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) return;
    if (out.size() == 0) out.write("Agent Signal Bar debug log\n");
    const QString line = '[' + QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") + "] " + message + '\n';
    out.write(line.toUtf8());
}

void handler(QtMsgType type, const QMessageLogContext &context, const QString &message) {
    if (g_previous) g_previous(type, context, message);
    if (t_writing) return;
    QMutexLocker lock(&mutex());
    if (!g_enabled || rank(type) < g_minimumRank) return;
    static const char *const names[] = {"debug", "warning", "critical", "fatal", "info"};
    const QString category = context.category && qstrcmp(context.category, "default") != 0
        ? QString::fromLatin1(context.category) + ": " : QString();
    writeLine(QString::fromLatin1(names[type]) + ' ' + category + message);
}

} // namespace

QString path() {
    // %LOCALAPPDATA% (GenericDataLocation on Windows), not the per-app folder Qt would pick.
    return QDir::cleanPath(QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
                           + "/AgentSignalBar/debug.log");
}

void configure(bool enabled, const QString &level) {
    {
        QMutexLocker lock(&mutex());
        g_enabled = enabled;
        g_minimumRank = level == "error" ? 2 : level == "verbose" ? 0 : 1;
        if (!g_installed) {
            g_previous = qInstallMessageHandler(handler);
            g_installed = true;
        }
    }
    QLoggingCategory::setFilterRules(enabled && level == "verbose" ? QStringLiteral("asb.*.debug=true\nasb.*.info=true")
                                                                   : QString());
}

bool enabled() {
    QMutexLocker lock(&mutex());
    return g_enabled;
}

void append(const QString &message) {
    QMutexLocker lock(&mutex());
    if (g_enabled) writeLine(message);
}

QString readAll() {
    QMutexLocker lock(&mutex());
    QFile in(path());
    if (!in.open(QIODevice::ReadOnly | QIODevice::Text)) return QString();
    return QString::fromUtf8(in.readAll());
}

void ensureExists() {
    QMutexLocker lock(&mutex());
    const QString file = path();
    if (QFileInfo::exists(file)) return;
    QDir().mkpath(QFileInfo(file).absolutePath());
    QFile out(file);
    if (out.open(QIODevice::WriteOnly | QIODevice::Text)) out.write("Agent Signal Bar debug log\n");
}

} // namespace asb::debuglog
