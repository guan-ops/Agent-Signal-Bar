#include "Diagnostics.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QStandardPaths>
#include <QSysInfo>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace asb::diagnostics {
namespace {

constexpr int kCommandTimeoutMs = 20000;

bool writeFile(const QString &path, const QByteArray &data) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    return file.open(QIODevice::WriteOnly | QIODevice::Truncate) && file.write(data) == data.size();
}

// run_capture: "$ command args", a blank line, stdout and stderr, then "[exit_code] N".
void capture(const QString &path, const QString &program, const QStringList &arguments, const QString &stateFile) {
    QByteArray text = "$ " + QDir::toNativeSeparators(program).toUtf8();
    for (const QString &argument : arguments) text += ' ' + argument.toUtf8();
    text += "\n\n";
    if (!QFileInfo(program).isFile()) {
        text += "not found\n";
        writeFile(path, text);
        return;
    }
    QProcess process;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    if (!stateFile.isEmpty()) env.insert("AGENT_SIGNAL_LIGHT_STATE_FILE", QDir::toNativeSeparators(stateFile));
    process.setProcessEnvironment(env);
    process.setProcessChannelMode(QProcess::MergedChannels);
    process.start(program, arguments);
    if (!process.waitForFinished(kCommandTimeoutMs)) {
        process.kill();
        process.waitForFinished(2000);
        text += process.readAll() + "\n[timed out]\n";
    } else {
        text += process.readAll();
        text += "\n[exit_code] " + QByteArray::number(process.exitCode()) + '\n';
    }
    writeFile(path, text);
}

void copyIfExists(const QString &source, const QString &target) {
    if (source.isEmpty() || !QFileInfo(source).isFile()) return;
    QDir().mkpath(QFileInfo(target).absolutePath());
    QFile::remove(target);
    QFile::copy(source, target);
}

QString tarExecutable() {
#ifdef Q_OS_WIN
    wchar_t system[MAX_PATH];
    const UINT length = GetSystemDirectoryW(system, MAX_PATH);
    if (length > 0 && length < MAX_PATH) {
        const QString path = QString::fromWCharArray(system, int(length)) + "\\tar.exe";
        if (QFileInfo(path).isFile()) return path;
    }
#endif
    return QStandardPaths::findExecutable("tar");
}

int runQuiet(const QString &program, const QStringList &arguments) {
    QProcess process;
    process.start(program, arguments);
    if (!process.waitForFinished(kCommandTimeoutMs)) {
        process.kill();
        process.waitForFinished(2000);
        return -1;
    }
    return process.exitStatus() == QProcess::NormalExit ? process.exitCode() : -1;
}

} // namespace

Result exportBundle(const Request &request) {
    Result result;
    const QString runID = "agent-signal-diagnostics-" + QDateTime::currentDateTime().toString("yyyyMMdd-HHmmss");
    const QString root = QDir::cleanPath(request.outputRoot);
    const QString work = root + '/' + runID;
    const QString archive = root + '/' + runID + ".zip";
    if (!QDir().mkpath(work + "/commands") || !QDir().mkpath(work + "/files") || !QDir().mkpath(work + "/config")) {
        result.error = QStringLiteral("无法创建诊断目录 / Cannot create the diagnostics folder: ") + QDir::toNativeSeparators(work);
        return result;
    }

    writeFile(work + "/commands/system.txt", (request.systemLines.join('\n') + '\n').toUtf8());
    capture(work + "/commands/agent-signal-status.txt", request.cliExe, {"status"}, request.stateFile);
    capture(work + "/commands/agent-signal-status-json.txt", request.cliExe, {"status", "--json"}, request.stateFile);
    capture(work + "/commands/install-hooks-dry-run.txt", request.cliExe, {"install-hooks", "--target", "all", "--dry-run"},
            request.stateFile);
    copyIfExists(request.stateFile, work + "/files/status.json");
    copyIfExists(request.logFile, work + "/files/debug.log");
    copyIfExists(request.logFile + ".1", work + "/files/debug.log.1");
    copyIfExists(request.settingsFile, work + "/config/settings.ini");

    QJsonArray files;
    QDirIterator it(work, QDir::Files, QDirIterator::Subdirectories);
    QStringList relative;
    while (it.hasNext()) relative.append(QDir(work).relativeFilePath(it.next()));
    relative.sort();
    for (const QString &file : relative) files.append(file);
    const QJsonObject manifest{
        {"schema_version", 1},
        {"generated_at", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)},
        {"mode", "quick"},
        {"app_dir", QDir::toNativeSeparators(QFileInfo(request.cliExe).absolutePath())},
        {"state_file", QDir::toNativeSeparators(request.stateFile)},
        {"archive", QDir::toNativeSeparators(archive)},
        {"platform", QSysInfo::prettyProductName() + " (" + QSysInfo::currentCpuArchitecture() + ")"},
        {"files", files},
        {"privacy_note", "This package includes status.json, debug.log, the app's settings.ini and local path metadata "
                         "such as app_dir, state_file and archive. It avoids dumping the full environment and does not "
                         "copy Codex or Claude hook config files; use install-hooks-dry-run.txt for hook diagnostics."}};
    writeFile(work + "/manifest.json", QJsonDocument(manifest).toJson(QJsonDocument::Indented));

    result.ok = true;
    result.folder = QDir::toNativeSeparators(work);
    // bsdtar picks the zip format from the .zip suffix (-a). An archive that does not list back
    // is removed: the folder alone is still a complete export.
    const QString tar = tarExecutable();
    QFile::remove(archive);
    if (!tar.isEmpty() && runQuiet(tar, {"-a", "-c", "-f", archive, "-C", root, runID}) == 0
        && QFileInfo(archive).size() > 0 && runQuiet(tar, {"-t", "-f", archive}) == 0) {
        result.archive = QDir::toNativeSeparators(archive);
    } else {
        QFile::remove(archive);
    }
    return result;
}

} // namespace asb::diagnostics
