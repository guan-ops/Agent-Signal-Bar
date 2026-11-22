#include "ClaudeHookInstaller.h"

#include "HookAdapters.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSet>
#include <QUuid>
#include <algorithm>
#include <optional>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace asb::hooks {
namespace {

// NativeHookInstaller.shellWords: split without running any shell text; nullopt if unbalanced.
std::optional<QStringList> shellWords(const QString &command) {
    QStringList words;
    QString token;
    bool inWord = false, escape = false;
    QChar quote;
    for (const QChar c : command.trimmed()) {
        if (escape) { token.append(c); escape = false; inWord = true; continue; }
        if (c == '\\' && quote != '\'') { escape = true; continue; }
        if (!quote.isNull()) { if (c == quote) quote = QChar(); else token.append(c); continue; }
        if (c == '\'' || c == '"') { quote = c; inWord = true; continue; }
        if (c.isSpace()) {
            if (inWord) { words.append(token); token.clear(); inWord = false; }
            continue;
        }
        token.append(c);
        inWord = true;
    }
    if (!quote.isNull() || escape) return std::nullopt;
    if (inWord) words.append(token);
    return words;
}

QString firstWord(const QString &command) {
    // Like NativeHookInstaller.owns: only the executable word, so trailing text never hides
    // an owned registration. Backslashes are kept here: Windows paths use them.
    QString token;
    QChar quote;
    for (const QChar c : command.trimmed()) {
        if (!quote.isNull()) { if (c == quote) quote = QChar(); else token.append(c); continue; }
        if (c == '\'' || c == '"') { quote = c; continue; }
        if (c.isSpace()) break;
        token.append(c);
    }
    return token;
}

QString normalizedPath(QString path) {
    path = QDir::cleanPath(QDir::fromNativeSeparators(path.trimmed()));
#ifdef Q_OS_WIN
    path = path.toLower();
#endif
    return path;
}

bool samePath(const QString &a, const QString &b) {
    if (normalizedPath(a) == normalizedPath(b)) return true;
    const QString ca = QFileInfo(a).canonicalFilePath(), cb = QFileInfo(b).canonicalFilePath();
    return !ca.isEmpty() && normalizedPath(ca) == normalizedPath(cb);
}

// With `args` (exec form) the whole command is the program path; otherwise its first word.
bool owns(const QJsonObject &item) {
    const QString command = item.value("command").toString();
    const QString token = item.contains("args") ? command.trimmed() : firstWord(command);
    const QString name = QDir::fromNativeSeparators(token).section('/', -1).toLower();
    if (name == "agent-signal.exe" || name == "agent-signal") return true;
    const QString lower = token.toLower();
    return lower.contains("agent-signal") || lower.contains("agentsignal") || lower.contains("agent signal");
}

bool isCurrent(const QJsonObject &item, const QString &exe) {
    const QString command = item.value("command").toString();
    if (item.contains("args")) {
        // The exact string this installer writes first (it may be an 8.3 short path).
        return item.value("args").toArray() == QJsonArray{"claude-hook"}
            && (command == ClaudeHookInstaller::commandPath(exe) || samePath(command, exe));
    }
    const auto words = shellWords(command);
    return words && words->size() == 2 && words->at(1) == "claude-hook" && samePath(words->first(), exe);
}

QByteArray serialize(const QJsonObject &document) { return QJsonDocument(document).toJson(QJsonDocument::Indented); }

void pruneBackups(const QString &settingsPath) {
    const QFileInfo settings(settingsPath);
    QDir dir = settings.dir();
    const QString prefix = settings.fileName() + ".bak-";
    QFileInfoList backups;
    for (const QFileInfo &info : dir.entryInfoList(QDir::Files | QDir::Hidden | QDir::NoSymLinks)) {
        if (info.fileName().startsWith(prefix)) backups.append(info);
    }
    // A copy keeps the file's modification time; its creation time is when the backup was made.
    const auto madeAt = [](const QFileInfo &info) {
        return info.birthTime().isValid() ? info.birthTime() : info.metadataChangeTime();
    };
    std::sort(backups.begin(), backups.end(), [&](const QFileInfo &a, const QFileInfo &b) { return madeAt(a) > madeAt(b); });
    for (qsizetype i = ClaudeHookInstaller::kRetainedBackups; i < backups.size(); ++i) QFile::remove(backups[i].filePath());
}

} // namespace

ClaudeHookInstaller::ClaudeHookInstaller(QString claudeRoot, QString hookExe)
    : m_root(std::move(claudeRoot)), m_exe(std::move(hookExe)) {}

QString ClaudeHookInstaller::defaultClaudeRoot(const QString &home, const QString &configDirEnv) {
    const QString value = configDirEnv.trimmed();
    if (value.isEmpty()) return QDir::cleanPath(home + "/.claude");
    if (value.startsWith("~/") || value.startsWith("~\\")) return QDir::cleanPath(home + '/' + value.mid(2));
    return QDir::cleanPath(value);
}

QString ClaudeHookInstaller::commandPath(const QString &hookExe) {
    const QFileInfo info(hookExe);
    QString path = info.absoluteFilePath();
#ifdef Q_OS_WIN
    // Only the folder is shortened: GetShortPathNameW would also turn agent-signal.exe into
    // AGENT-~1.EXE, and owns() recognises an entry as ours by that file name.
    const QString dir = info.absolutePath();
    if (dir.contains(' ')) {
        const std::wstring longDir = QDir::toNativeSeparators(dir).toStdWString();
        wchar_t shortDir[MAX_PATH * 2];
        const DWORD length = GetShortPathNameW(longDir.c_str(), shortDir, DWORD(std::size(shortDir)));
        if (length > 0 && length < std::size(shortDir))
            path = QString::fromWCharArray(shortDir, int(length)) + '/' + info.fileName();
    }
#endif
    return QDir::fromNativeSeparators(path);
}

bool ClaudeHookInstaller::isTemporaryLocation(const QString &hookExe) {
    const QString exe = normalizedPath(QFileInfo(hookExe).absoluteFilePath());
    for (const QString &temp : {QDir::tempPath(), QFileInfo(QDir::tempPath()).canonicalFilePath()}) {
        if (temp.isEmpty()) continue;
        const QString root = normalizedPath(temp);
        if (exe.startsWith(root + '/')) return true;
    }
    return false;
}

HookReport ClaudeHookInstaller::check() const { return run(false, false); }
HookReport ClaudeHookInstaller::install() const { return run(true, false); }
HookReport ClaudeHookInstaller::uninstall() const { return run(true, true); }

HookReport ClaudeHookInstaller::run(bool write, bool remove) const {
    HookReport report;
    const QString path = QDir::cleanPath(m_root + "/settings.json");
    report.settingsPath = QDir::toNativeSeparators(path);
    const auto fail = [&](const QString &message) {
        report.error = message;
        return report;
    };

    if (write && !remove) {
        if (!m_allowTemporary && isTemporaryLocation(m_exe))
            return fail(QStringLiteral("Agent Signal Bar 正在临时文件夹中运行，这里安装的 Hook 会在清理后失效。请先把程序放到固定位置"
                                       "（build.ps1 默认安装到 %LOCALAPPDATA%\\Programs\\AgentSignalBar）再安装。"
                                       " / Agent Signal Bar is running from a temporary folder; hooks installed from here break "
                                       "once it is cleaned up. Install it to a permanent folder first."));
        if (!QFileInfo(m_exe).isFile())
            return fail("找不到 agent-signal.exe / agent-signal.exe not found: " + QDir::toNativeSeparators(m_exe));
    }

    const QFileInfo info(path);
    if (info.isSymLink())
        return fail("settings.json 是符号链接，为安全起见不修改；请手动编辑链接目标 / settings.json is a symbolic link "
                    "and is not modified for safety: " + report.settingsPath);
    QByteArray original;
    const bool exists = info.exists();
    if (exists) {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) return fail("无法读取 / Cannot read: " + report.settingsPath);
        original = file.readAll();
    }
    QJsonObject document;
    if (exists && !original.trimmed().isEmpty()) {
        QJsonParseError error;
        const QJsonDocument parsed = QJsonDocument::fromJson(original, &error);
        if (error.error != QJsonParseError::NoError || !parsed.isObject())
            return fail("settings.json 不是有效的 JSON 对象，未修改 / settings.json is not a JSON object; not modified: "
                        + report.settingsPath);
        document = parsed.object();
    }
    if (document.contains("hooks") && !document.value("hooks").isObject())
        return fail("settings.json 里的 hooks 必须是对象 / hooks must be an object: " + report.settingsPath);
    QJsonObject hooks = document.value("hooks").toObject();
    const QByteArray before = QJsonDocument(document).toJson(QJsonDocument::Compact);
    const QStringList &events = claude::installedEvents();

    QSet<QString> present;
    QStringList removed;
    for (const QString &event : hooks.keys()) {
        if (!hooks.value(event).isArray()) return fail("hooks." + event + " 必须是数组 / must be an array");
        const bool wanted = !remove && events.contains(event);
        QJsonArray filtered;
        for (const QJsonValue &value : hooks.value(event).toArray()) {
            const QJsonObject block = value.toObject();
            if (!value.isObject() || !block.value("hooks").isArray()) {
                filtered.append(value);
                continue;
            }
            const QString matcher = block.value("matcher").toString();
            const bool matchesAllTools = matcher.isEmpty() || matcher == "*";
            const QJsonArray items = block.value("hooks").toArray();
            QJsonArray kept;
            for (const QJsonValue &itemValue : items) {
                const QJsonObject item = itemValue.toObject();
                const QString command = item.value("command").toString();
                if (!itemValue.isObject() || !item.value("command").isString() || !owns(item)) {
                    kept.append(itemValue);
                    continue;
                }
                if (wanted && matchesAllTools && !present.contains(event) && isCurrent(item, m_exe)) {
                    present.insert(event);
                    kept.append(itemValue);
                }
            }
            if (kept.size() != items.size()) {
                if (!removed.contains(event)) removed.append(event);
                if (!kept.isEmpty()) {
                    QJsonObject updated = block;
                    updated.insert("hooks", kept);
                    filtered.append(updated);
                }
            } else {
                filtered.append(value);
            }
        }
        if (filtered.isEmpty() && removed.contains(event)) hooks.remove(event);
        else hooks.insert(event, filtered);
    }
    for (const QString &event : events) {
        if (present.contains(event)) continue;
        report.missing.append(event);
        if (remove) continue;
        QJsonArray blocks = hooks.value(event).toArray();
        blocks.append(QJsonObject{
            {"matcher", ""},
            {"hooks", QJsonArray{QJsonObject{{"type", "command"}, {"command", commandPath(m_exe)},
                                             {"args", QJsonArray{"claude-hook"}},
                                             {"timeout", event == "PermissionRequest" ? 10 : 5}}}}});
        hooks.insert(event, blocks);
    }
    for (const QString &event : removed) {
        if (events.contains(event) && !present.contains(event)) report.stale.append(event);
    }
    if (!hooks.isEmpty() || document.contains("hooks")) document.insert("hooks", hooks);
    const bool changed = QJsonDocument(document).toJson(QJsonDocument::Compact) != before;
    report.configured = !remove && !changed;
    if (remove) report.missing.clear();

    if (write && changed) {
        QDir().mkpath(m_root);
        if (exists) {
            report.backup = path + ".bak-" + QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
            if (!QFile::copy(path, report.backup)) return fail("无法创建备份 / Cannot create a backup of " + report.settingsPath);
            report.backup = QDir::toNativeSeparators(report.backup);
        }
        // The file must not have changed since it was read. Close it before QSaveFile replaces
        // it: Windows cannot rename over a file that is still open.
        QByteArray current;
        {
            QFile again(path);
            if (again.open(QIODevice::ReadOnly)) current = again.readAll();
        }
        if ((exists && current != original) || (!exists && QFileInfo::exists(path)))
            return fail("settings.json 刚被其他程序修改，请重试 / settings.json changed concurrently; retry");
        QSaveFile save(path);
        if (!save.open(QIODevice::WriteOnly) || save.write(serialize(document)) < 0 || !save.commit())
            return fail("无法写入 / Cannot write: " + report.settingsPath);
        report.changed = true;
        if (exists) pruneBackups(path);
        if (!remove) {
            report.configured = true;
            report.missing.clear();
            report.stale.clear();
        }
    }
    report.ok = true;
    return report;
}

} // namespace asb::hooks
