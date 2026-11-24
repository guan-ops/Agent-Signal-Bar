// agent-signal.exe: port of AgentSignalCLIMain.swift. It links QtCore only, because agent hooks
// start it on every tool call.
//
//   agent-signal list | status [--json] | reset [--json]
//   agent-signal <signal> | set <signal> | session <signal>   [--session id] [--agent name] [--event e]
//   agent-signal codex-hook [event] | claude-hook [event] | agent-hook [event]   (payload on stdin)
//   agent-signal install-hooks [--target all|codex|claude] [--install|--dry-run] [--remove]
//
// Run with no arguments and a piped stdin, it acts as claude-hook: a Claude Code version that
// ignores the hook's "args" field still lands here.
//
// Differences from macOS: the hook commands never block an agent, so they always exit 0 (bad
// input is reported on stderr only), print nothing on stdout, wait at most 1.5 s for the state
// lock and drop the event when the lock is busy. install-hooks registers this exe itself (macOS
// registers the app's wrapper scripts), so it has no --resources option.
#include "../src/ClaudeHookInstaller.h"
#include "../src/HookAdapters.h"
#include "../src/SignalModel.h"
#include "../src/SignalStateFile.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcessEnvironment>
#include <QSettings>
#include <QTimeZone>
#include <cstdio>
#include <functional>
#include <optional>
#include <vector>

#ifdef Q_OS_WIN
#include <io.h>
#include <windows.h>
#define ASB_ISATTY _isatty
#define ASB_FILENO _fileno
#else
#include <unistd.h>
#define ASB_ISATTY isatty
#define ASB_FILENO fileno
#endif

namespace {

constexpr int kHookLockTimeoutMs = 1500;
constexpr int kCommandLockTimeoutMs = 3000;

struct CliError {
    QString message;
};

struct Parsed {
    QStringList positionals;
    std::optional<QString> sessionID;
    std::optional<QString> agent;
    std::optional<QString> event;
    bool printsJSON = false;
};

// UTF-8 when redirected; WriteConsoleW on a console, whose code page (often 936) would garble
// UTF-8 bytes.
void writeText(FILE *stream, const QString &text) {
#ifdef Q_OS_WIN
    const HANDLE handle = GetStdHandle(stream == stderr ? STD_ERROR_HANDLE : STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    if (handle && handle != INVALID_HANDLE_VALUE && GetConsoleMode(handle, &mode)) {
        const std::wstring wide = text.toStdWString();
        DWORD written = 0;
        WriteConsoleW(handle, wide.c_str(), DWORD(wide.size()), &written, nullptr);
        return;
    }
#endif
    const QByteArray utf8 = text.toUtf8();
    std::fwrite(utf8.constData(), 1, size_t(utf8.size()), stream);
    std::fflush(stream);
}

void print(const QString &line) { writeText(stdout, line + '\n'); }
void printError(const QString &line) { writeText(stderr, line + '\n'); }

QString commandName() {
    const QString name = QFileInfo(QCoreApplication::applicationFilePath()).completeBaseName();
    return name.isEmpty() ? QStringLiteral("agent-signal") : name;
}

asb::hooks::Environment environment() {
    asb::hooks::Environment env;
    const QProcessEnvironment system = QProcessEnvironment::systemEnvironment();
    for (const QString &key : system.keys()) env.insert(key, system.value(key));
    return env;
}

QString optionValue(const QStringList &arguments, qsizetype index, const QString &option) {
    if (index + 1 >= arguments.size() || arguments.at(index + 1).startsWith('-'))
        throw CliError{"Missing value for " + option + "."};
    return arguments.at(index + 1);
}

Parsed parse(const QStringList &arguments) {
    Parsed parsed;
    for (qsizetype index = 0; index < arguments.size(); ++index) {
        const QString &value = arguments.at(index);
        if (value == "--session" || value == "-s") parsed.sessionID = optionValue(arguments, index++, value);
        else if (value == "--agent" || value == "--source") parsed.agent = optionValue(arguments, index++, value);
        else if (value == "--event" || value == "--label") parsed.event = optionValue(arguments, index++, value);
        else if (value == "--json" || value == "-j") parsed.printsJSON = true;
        else if (value.startsWith('-')) throw CliError{"Unknown option: " + value};
        else parsed.positionals.append(value);
    }
    return parsed;
}

void requirePositionals(const Parsed &parsed, qsizetype count) {
    if (parsed.positionals.size() < count) throw CliError{QStringLiteral("Missing argument.")};
    if (parsed.positionals.size() > count) throw CliError{"Unexpected argument: " + parsed.positionals.at(count)};
}

void requireAtMostOnePositional(const Parsed &parsed) {
    if (parsed.positionals.size() > 1) throw CliError{"Unexpected argument: " + parsed.positionals.at(1)};
}

QString isoDate(qint64 ms) {
    // JSONEncoder .iso8601: UTC, whole seconds.
    return QDateTime::fromMSecsSinceEpoch(ms, QTimeZone::UTC).toString(Qt::ISODate);
}

QJsonObject statusJSON(const asb::SignalSnapshot &snapshot, const QString &stateFile) {
    const asb::DisplayState state = asb::displayState(snapshot.aggregate);
    QJsonArray sessions;
    for (const asb::SessionStatus &s : snapshot.sessions) {
        QJsonObject item{{"session_id", s.sessionID}, {"signal", s.signal}, {"updated_at", isoDate(s.updatedAt)}};
        if (!s.agent.isEmpty()) item.insert("agent", s.agent);
        if (!s.lastEvent.isEmpty()) item.insert("last_event", s.lastEvent);
        sessions.append(item);
    }
    QJsonArray events;
    for (const asb::SignalEvent &e : snapshot.recentEvents) {
        QJsonObject item{{"id", e.id}, {"session_id", e.sessionID}, {"signal", e.signal},
                         {"updated_at", isoDate(e.updatedAt)}};
        if (!e.agent.isEmpty()) item.insert("agent", e.agent);
        if (!e.event.isEmpty()) item.insert("event", e.event);
        events.append(item);
    }
    QJsonObject output{{"schema_version", 1},
                       {"aggregate", snapshot.aggregate},
                       {"display_state", asb::displayStateKey(state)},
                       {"lamp_state", asb::displayStateKey(state)},
                       {"priority", asb::priority(state)},
                       {"display_name", asb::signalDisplayName(snapshot.aggregate)},
                       {"summary", asb::signalSummary(snapshot.aggregate)},
                       {"action", asb::humanAction(state)},
                       {"state_file", QDir::toNativeSeparators(stateFile)},
                       {"sessions", sessions},
                       {"recent_events", events}};
    if (snapshot.updatedAt) output.insert("updated_at", isoDate(*snapshot.updatedAt));
    return output;
}

void printStatus(const asb::SignalSnapshot &snapshot, const QString &stateFile, bool asJSON) {
    if (asJSON) {
        writeText(stdout, QString::fromUtf8(QJsonDocument(statusJSON(snapshot, stateFile)).toJson(QJsonDocument::Indented)));
        return;
    }
    print("aggregate: " + snapshot.aggregate + " (" + asb::signalDisplayName(snapshot.aggregate) + ")");
    print("action: " + asb::humanAction(asb::displayState(snapshot.aggregate)));
    print("state_file: " + QDir::toNativeSeparators(stateFile));
    if (snapshot.updatedAt)
        print("updated_at: " + QDateTime::fromMSecsSinceEpoch(*snapshot.updatedAt).toString("yyyy-MM-dd HH:mm:ss"));
    const auto details = [](const QString &agent, const QString &event) {
        return (agent.isEmpty() ? QString() : " agent=" + agent) + (event.isEmpty() ? QString() : " event=" + event);
    };
    if (snapshot.sessions.isEmpty()) {
        print("sessions: none");
    } else {
        print("sessions:");
        for (const asb::SessionStatus &s : snapshot.sessions)
            print("- " + s.sessionID + ": " + s.signal + details(s.agent, s.lastEvent));
    }
    if (!snapshot.recentEvents.isEmpty()) {
        print("recent_events:");
        for (const asb::SignalEvent &e : snapshot.recentEvents.mid(0, 10))
            print("- " + e.sessionID + ": " + e.signal + details(e.agent, e.event));
    }
}

asb::SignalSnapshot change(const std::function<void(asb::SignalStore &)> &apply, QString *stateFile) {
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    asb::SignalStateFile file(asb::SignalStateFile::defaultPath());
    *stateFile = file.path();
    const auto snapshot = file.update(apply, now, kCommandLockTimeoutMs);
    if (!snapshot) throw CliError{"Cannot update the state file (busy or not writable): " + QDir::toNativeSeparators(file.path())};
    return *snapshot;
}

// `<signal>`, `set <signal>`: a session when --session is given, else the manual signal.
int setSignal(const QString &signal, const Parsed &parsed, const std::optional<QString> &defaultSession) {
    const std::optional<QString> sessionID = parsed.sessionID ? parsed.sessionID : defaultSession;
    QString stateFile;
    const asb::SignalSnapshot snapshot = change(
        [&](asb::SignalStore &store) {
            const qint64 now = QDateTime::currentMSecsSinceEpoch();
            if (sessionID)
                store.applySessionSignal(signal, *sessionID, parsed.agent.value_or(QString()),
                                         parsed.event.value_or(QString()), now, now);
            else
                store.setManualSignal(signal, now);
        },
        &stateFile);
    printStatus(snapshot, stateFile, parsed.printsJSON);
    return 0;
}

QString requiredSignal(const Parsed &parsed, const QString &message) {
    const auto signal = parsed.positionals.isEmpty() ? std::nullopt : asb::normalizedSignal(parsed.positionals.first());
    if (!signal) throw CliError{message};
    requirePositionals(parsed, 1);
    return *signal;
}

// The hook commands: never fail the agent's hook.
enum class HookKind { Codex, Claude, Generic };

int hook(HookKind kind, const QStringList &arguments) {
    try {
        const Parsed parsed = parse(arguments);
        requireAtMostOnePositional(parsed);
        QFile input;
        if (!input.open(stdin, QIODevice::ReadOnly)) throw CliError{QStringLiteral("cannot read stdin")};
        QJsonParseError error;
        const QJsonDocument document = QJsonDocument::fromJson(input.readAll(), &error);
        if (error.error != QJsonParseError::NoError || !document.isObject())
            throw CliError{QStringLiteral("hook payload must be a JSON object")};
        const QJsonObject payload = document.object();
        const asb::hooks::Environment env = environment();
        namespace h = asb::hooks;

        std::optional<QString> event;
        if (!parsed.positionals.isEmpty()) event = parsed.positionals.first();
        QString signal, sessionID, agent, label;
        switch (kind) {
        case HookKind::Codex:
            if (!event) event = h::codex::eventName(payload);
            signal = h::codex::chooseSignal(event, payload);
            agent = parsed.agent.value_or(h::codex::agentName(payload, env));
            sessionID = parsed.sessionID.value_or(h::codex::sourceScopedSessionKey(h::codex::sessionKey(payload, env), agent));
            label = parsed.event ? *parsed.event : event.value_or(QString());
            break;
        case HookKind::Claude:
            if (!event) event = h::claude::eventName(payload);
            signal = h::claude::chooseSignal(event, payload);
            agent = parsed.agent.value_or(h::claude::agentName(env));
            sessionID = parsed.sessionID.value_or(h::claude::sessionKey(payload, env));
            label = parsed.event ? *parsed.event : h::claude::displayEventName(event, payload).value_or(QString());
            break;
        case HookKind::Generic:
            if (!event) event = h::generic::eventName(payload);
            signal = h::generic::chooseSignal(event, payload);
            agent = parsed.agent.value_or(h::generic::agentName(payload, env));
            sessionID = parsed.sessionID.value_or(h::generic::sessionKey(payload, env, agent));
            label = parsed.event ? *parsed.event : event.value_or(QString());
            break;
        }

        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        asb::SignalStateFile file(asb::SignalStateFile::defaultPath());
        const auto result = file.update(
            [&](asb::SignalStore &store) { store.applySessionSignal(signal, sessionID, agent, label, now, now); }, now,
            kHookLockTimeoutMs);
        if (!result) printError(commandName() + ": state file busy, event dropped");
    } catch (const CliError &error) {
        printError(commandName() + ": " + error.message);
    }
    return 0;
}

// CodexDataPaths.primaryRoot: --codex-home, else CODEX_HOME, else <home>/.codex.
QString codexHome(const QString &home, const std::optional<QString> &selected, const QString &environmentValue) {
    for (const QString &candidate : {selected.value_or(QString()), environmentValue}) {
        QString value = candidate.trimmed();
        if (value.isEmpty()) continue;
        if (value == "~") value = home;
        else if (value.startsWith("~/") || value.startsWith("~\\")) value = home + '/' + value.mid(2);
        return QDir::cleanPath(QFileInfo(value).absoluteFilePath());
    }
    return QDir::cleanPath(home + "/.codex");
}

QString describe(const QString &name, const asb::hooks::HookReport &report, bool installed, const QString &exe) {
    QStringList lines{
        QStringLiteral("[%1] %2: %3").arg(installed ? QStringLiteral("installed") : QStringLiteral("dry-run"), name,
                                          report.wouldChange ? QStringLiteral("updated") : QStringLiteral("already configured")),
        "  file: " + report.settingsPath,
        "  command: " + QDir::toNativeSeparators(asb::hooks::ClaudeHookInstaller::commandPath(exe))};
    if (!report.added.isEmpty()) lines.append("  add events: " + report.added.join(", "));
    if (!report.removed.isEmpty()) lines.append("  remove events: " + report.removed.join(", "));
    if (!report.backup.isEmpty()) lines.append("  backup: " + report.backup);
    return lines.join('\n');
}

// Puts a file back as it was before install-hooks wrote it (NativeHookInstaller's rollback).
bool restore(const asb::hooks::HookReport &report) {
    const QString path = QDir::fromNativeSeparators(report.settingsPath);
    if (!QFile::remove(path) && QFileInfo::exists(path)) return false;
    return report.backup.isEmpty() || QFile::copy(QDir::fromNativeSeparators(report.backup), path);
}

int installHooks(const QStringList &arguments) {
    QString target = QStringLiteral("all");
    std::optional<QString> home, selectedCodexHome;
    bool install = false, remove = false;
    for (qsizetype index = 0; index < arguments.size(); ++index) {
        const QString &key = arguments.at(index);
        if (key == "--install") install = true;
        else if (key == "--remove") remove = true;
        else if (key == "--dry-run") install = false;
        else if (key == "--target") target = optionValue(arguments, index++, key);
        else if (key == "--home") home = optionValue(arguments, index++, key);
        else if (key == "--codex-home") selectedCodexHome = optionValue(arguments, index++, key);
        else throw CliError{"Unknown installer option: " + key};
    }
    if (target != "all" && target != "codex" && target != "claude") throw CliError{"Unknown hook target: " + target};

    using asb::hooks::ClaudeHookInstaller;
    const QString exe = QCoreApplication::applicationFilePath();
    // Hooks must name a path that still exists later; removal works from anywhere.
    if (!remove && ClaudeHookInstaller::isTemporaryLocation(exe))
        throw CliError{QStringLiteral("agent-signal.exe 正在临时文件夹中运行，这里安装的 Hook 会在清理后失效。请先把程序放到固定位置再安装。"
                                      " / agent-signal.exe is running from a temporary folder; hooks installed from here "
                                      "break once it is cleaned up. Install it to a permanent folder first.")};
    // A fixture home ignores the environment, as on macOS.
    const QString userHome = home ? QDir::cleanPath(QFileInfo(*home).absoluteFilePath()) : QDir::homePath();
    const QString claudeEnv = home ? QString() : qEnvironmentVariable("CLAUDE_CONFIG_DIR");
    const QString codexEnv = home ? QString() : qEnvironmentVariable("CODEX_HOME");
    const QString primaryCodexHome = codexHome(userHome, selectedCodexHome, codexEnv);

    struct Spec {
        QString name;
        ClaudeHookInstaller installer;
        bool optional = false; // skipped, not fatal, when its file cannot be read
    };
    std::vector<Spec> specs;
    if (target != "claude")
        specs.push_back({QStringLiteral("Codex User"),
                         ClaudeHookInstaller(primaryCodexHome, exe, ClaudeHookInstaller::Target::Codex)});
    // Removal (the uninstaller runs it without --codex-home) also cleans the Codex data folder
    // chosen in the app's Connections page: the app installs its Codex hooks there, and the
    // hooks would otherwise keep calling the removed agent-signal.exe.
    if (remove && target != "claude" && !home && !selectedCodexHome) {
        const QSettings prefs(QSettings::IniFormat, QSettings::UserScope, "AgentSignalBar", "AgentSignalBar");
        const QString saved = prefs.value("codexDataDir").toString().trimmed();
        const QString savedHome = saved.isEmpty() ? QString() : codexHome(userHome, saved, QString());
        if (!savedHome.isEmpty() && savedHome.compare(primaryCodexHome, Qt::CaseInsensitive) != 0
            && QFileInfo(savedHome).isDir())
            specs.push_back({QStringLiteral("Codex (Agent Signal Bar folder)"),
                             ClaudeHookInstaller(savedHome, exe, ClaudeHookInstaller::Target::Codex), true});
    }
    if (target != "codex")
        specs.push_back({QStringLiteral("Claude Code"),
                      ClaudeHookInstaller(ClaudeHookInstaller::defaultClaudeRoot(userHome, claudeEnv), exe)});

    // Plan everything first: one unreadable file writes nothing (an optional one is left out).
    QStringList messages;
    std::vector<const Spec *> planned;
    for (const Spec &spec : specs) {
        const asb::hooks::HookReport plan = spec.installer.preview(remove);
        if (!plan.ok) {
            if (!spec.optional) throw CliError{spec.name + ": " + plan.error};
            messages.append(QStringLiteral("[skipped] %1: %2").arg(spec.name, plan.error));
            continue;
        }
        planned.push_back(&spec);
        messages.append(describe(spec.name, plan, false, exe));
    }
    if (!install) {
        print(messages.join('\n'));
        return 0;
    }
    messages.clear();
    QList<asb::hooks::HookReport> applied;
    for (const Spec *plannedSpec : planned) {
        const Spec &spec = *plannedSpec;
        const asb::hooks::HookReport report = remove ? spec.installer.uninstall() : spec.installer.install();
        if (!report.ok) {
            QStringList rollbackErrors;
            for (auto it = applied.crbegin(); it != applied.crend(); ++it) {
                if (it->changed && !restore(*it)) rollbackErrors.append(it->settingsPath);
            }
            QString message = spec.name + ": " + report.error;
            if (!rollbackErrors.isEmpty()) message += "\nRollback needs attention: " + rollbackErrors.join("; ");
            throw CliError{message};
        }
        applied.append(report);
        messages.append(describe(spec.name, report, true, exe));
    }
    print(messages.join('\n'));
    return 0;
}

void printUsage() {
    const QString c = commandName();
    print(c + "\n\n"
          "Usage:\n"
          "  " + c + " list\n"
          "  " + c + " status [--json]\n"
          "  " + c + " <signal> [--session <id>] [--agent <name>] [--event <event>] [--json]\n"
          "  " + c + " set <signal> [--json]\n"
          "  " + c + " session <signal> --session <id> [--json]\n"
          "  " + c + " install-hooks [--target all|codex|claude] [--install|--dry-run] [--remove]\n"
          "        [--home <dir>] [--codex-home <dir>]\n"
          "        (--remove also cleans the Codex folder chosen in the app, unless --home or --codex-home)\n"
          "  " + c + " codex-hook [event]\n"
          "  " + c + " claude-hook [event]\n"
          "  " + c + " agent-hook [event] [--agent <name>] [--session <id>]\n"
          "  " + c + " reset [--json]\n\n"
          "Examples:\n"
          "  " + c + " idle\n"
          "  " + c + " working --session codex-main --agent codex --event PreToolUse\n"
          "  echo {\"event\":\"AgentStarted\",\"agent\":\"local-script\",\"session_id\":\"local-script-main\"} | " + c + " agent-hook\n"
          "  " + c + " status --json\n"
          "  " + c + " permission --session codex-main --event PermissionRequest\n\n"
          "Signals:\n"
          "  idle, thinking, working, tool_done, subagent_start, subagent_stop,\n"
          "  attention, notification, done, permission, permission_request,\n"
          "  blocked, failure, error, exception, max_tokens, stale,\n"
          "  session_start, session_end, turn_end, off, pause, paused");
}

int run(QStringList arguments) {
    const QString command = arguments.takeFirst();
    if (command == "codex-hook") return hook(HookKind::Codex, arguments);
    if (command == "claude-hook") return hook(HookKind::Claude, arguments);
    if (command == "agent-hook" || command == "generic-hook" || command == "hook") return hook(HookKind::Generic, arguments);
    try {
        if (command == "help" || command == "--help" || command == "-h") {
            printUsage();
        } else if (command == "install-hooks") {
            return installHooks(arguments);
        } else if (command == "list") {
            for (const QString &signal : asb::allSignals()) {
                const asb::DisplayState state = asb::displayState(signal);
                print(signal + '\t' + asb::displayStateKey(state) + '\t' + asb::signalDisplayName(signal) + '\t'
                      + asb::humanAction(state));
            }
        } else if (command == "status") {
            const Parsed parsed = parse(arguments);
            requirePositionals(parsed, 0);
            asb::SignalStateFile file(asb::SignalStateFile::defaultPath());
            const auto snapshot = file.readSnapshot(QDateTime::currentMSecsSinceEpoch(), kCommandLockTimeoutMs);
            if (!snapshot) throw CliError{"Cannot read the state file: " + QDir::toNativeSeparators(file.path())};
            printStatus(*snapshot, file.path(), parsed.printsJSON);
        } else if (command == "reset" || command == "clear-all") {
            const Parsed parsed = parse(arguments);
            requirePositionals(parsed, 0);
            QString stateFile;
            const asb::SignalSnapshot snapshot = change(
                [](asb::SignalStore &store) { store.setManualSignal("idle", QDateTime::currentMSecsSinceEpoch()); },
                &stateFile);
            printStatus(snapshot, stateFile, parsed.printsJSON);
        } else if (command == "set" || command == "play") {
            const Parsed parsed = parse(arguments);
            return setSignal(requiredSignal(parsed, QStringLiteral("Missing or unknown signal.")), parsed, std::nullopt);
        } else if (command == "session") {
            const Parsed parsed = parse(arguments);
            return setSignal(requiredSignal(parsed, QStringLiteral("Missing or unknown session signal.")), parsed,
                             QStringLiteral("global"));
        } else if (const auto signal = asb::normalizedSignal(command)) {
            const Parsed parsed = parse(arguments);
            requirePositionals(parsed, 0);
            return setSignal(*signal, parsed, std::nullopt);
        } else {
            throw CliError{"Unknown command: " + command};
        }
        return 0;
    } catch (const CliError &error) {
        printError(commandName() + ": " + error.message);
        return 1;
    }
}

} // namespace

int main(int argc, char *argv[]) {
    QCoreApplication app(argc, argv);
    const QStringList arguments = app.arguments().mid(1);
    if (arguments.isEmpty()) {
        if (!ASB_ISATTY(ASB_FILENO(stdin))) return hook(HookKind::Claude, {});
        printUsage();
        return 0;
    }
    return run(arguments);
}
