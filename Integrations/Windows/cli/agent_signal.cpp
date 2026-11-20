// agent-signal.exe: the command Claude Code hooks run (port of AgentSignalCLIMain's
// claude-hook and status commands). It links QtCore only, because it starts on every tool
// call.
//
//   agent-signal claude-hook [event]   read the hook payload from stdin, update status.json
//   agent-signal status [--json]       print the current state
//
// Run with no arguments and a piped stdin, it acts as claude-hook: a Claude Code version
// that ignores the hook's "args" field still lands here.
//
// The hook path never blocks Claude Code: it always exits 0, writes nothing to stdout, waits
// at most 1.5 s for the state lock and drops the event when the lock is busy.
#include "../src/HookAdapters.h"
#include "../src/SignalModel.h"
#include "../src/SignalStateFile.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcessEnvironment>
#include <QTextStream>
#include <cstdio>

#ifdef Q_OS_WIN
#include <io.h>
#define ASB_ISATTY _isatty
#define ASB_FILENO _fileno
#else
#include <unistd.h>
#define ASB_ISATTY isatty
#define ASB_FILENO fileno
#endif

namespace {

constexpr int kHookLockTimeoutMs = 1500;

asb::hooks::Environment environment() {
    asb::hooks::Environment env;
    const QProcessEnvironment system = QProcessEnvironment::systemEnvironment();
    for (const QString &key : system.keys()) env.insert(key, system.value(key));
    return env;
}

int claudeHook(const QStringList &args) {
    QFile input;
    if (!input.open(stdin, QIODevice::ReadOnly)) return 0;
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(input.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) {
        std::fputs("agent-signal: hook payload must be a JSON object\n", stderr);
        return 0;
    }
    const QJsonObject payload = document.object();
    const asb::hooks::Environment env = environment();
    std::optional<QString> event;
    if (!args.isEmpty()) event = args.first();
    else event = asb::hooks::claude::eventName(payload);

    const QString signal = asb::hooks::claude::chooseSignal(event, payload);
    const QString sessionID = asb::hooks::claude::sessionKey(payload, env);
    const QString agent = asb::hooks::claude::agentName(env);
    const QString label = asb::hooks::claude::displayEventName(event, payload).value_or(QString());
    const qint64 now = QDateTime::currentMSecsSinceEpoch();

    asb::SignalStateFile file(asb::SignalStateFile::defaultPath());
    const auto result = file.update(
        [&](asb::SignalStore &store) { store.applySessionSignal(signal, sessionID, agent, label, now, now); }, now,
        kHookLockTimeoutMs);
    if (!result) std::fputs("agent-signal: state file busy, event dropped\n", stderr);
    return 0;
}

int status(const QStringList &args) {
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    asb::SignalStateFile file(asb::SignalStateFile::defaultPath());
    const auto snapshot = file.readSnapshot(now, 3000);
    QTextStream out(stdout);
    if (!snapshot) {
        std::fputs("agent-signal: cannot read the state file\n", stderr);
        return 1;
    }
    if (args.contains("--json")) {
        QJsonArray sessions;
        for (const asb::SessionStatus &s : snapshot->sessions)
            sessions.append(QJsonObject{{"session_id", s.sessionID}, {"signal", s.signal}, {"agent", s.agent},
                                        {"last_event", s.lastEvent},
                                        {"updated_at", QDateTime::fromMSecsSinceEpoch(s.updatedAt).toString(Qt::ISODate)}});
        out << QJsonDocument(QJsonObject{{"aggregate", snapshot->aggregate}, {"sessions", sessions},
                                         {"state_file", file.path()}})
                   .toJson(QJsonDocument::Indented);
        return 0;
    }
    out << "aggregate: " << snapshot->aggregate << " ("
        << asb::displayStateKey(asb::displayState(snapshot->aggregate)) << ")\n";
    out << "state file: " << file.path() << "\n";
    for (const asb::SessionStatus &s : snapshot->sessions)
        out << "  " << s.sessionID << "  " << s.signal << "  " << s.agent << "  " << s.lastEvent << "  "
            << QDateTime::fromMSecsSinceEpoch(s.updatedAt).toString("HH:mm:ss") << "\n";
    return 0;
}

void usage() {
    QTextStream(stdout) << "Usage:\n"
                           "  agent-signal claude-hook [event]   (reads the Claude Code hook payload from stdin)\n"
                           "  agent-signal status [--json]\n";
}

} // namespace

int main(int argc, char *argv[]) {
    QCoreApplication app(argc, argv);
    QStringList args = app.arguments().mid(1);
    if (args.isEmpty()) {
        if (!ASB_ISATTY(ASB_FILENO(stdin))) return claudeHook({});
        usage();
        return 0;
    }
    const QString command = args.takeFirst();
    if (command == "claude-hook") return claudeHook(args);
    if (command == "status") return status(args);
    if (command == "help" || command == "--help" || command == "-h") {
        usage();
        return 0;
    }
    std::fprintf(stderr, "agent-signal: unknown command: %s\n", qPrintable(command));
    return 1;
}
