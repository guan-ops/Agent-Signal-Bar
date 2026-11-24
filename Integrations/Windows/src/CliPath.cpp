#include "CliPath.h"

#include <QDir>
#include <QStringList>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace asb::clipath {
namespace {

QString normalized(const QString &entry, const Expand &expand) {
    QString value = entry.trimmed();
    if (value.size() >= 2 && value.startsWith('"') && value.endsWith('"')) value = value.mid(1, value.size() - 2);
    if (expand) value = expand(value);
    value = QDir::fromNativeSeparators(value);
    while (value.size() > 1 && value.endsWith('/') && !value.endsWith(":/")) value.chop(1);
    return value.toLower();
}

#ifdef Q_OS_WIN
std::optional<QString> readValue(HKEY root, const wchar_t *subkey) {
    DWORD bytes = 0;
    const DWORD flags = RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND;
    LSTATUS status = RegGetValueW(root, subkey, L"Path", flags, nullptr, nullptr, &bytes);
    if (status == ERROR_FILE_NOT_FOUND) return QString();
    if (status != ERROR_SUCCESS) return std::nullopt;
    std::wstring buffer(bytes / sizeof(wchar_t) + 1, L'\0');
    status = RegGetValueW(root, subkey, L"Path", flags, nullptr, buffer.data(), &bytes);
    if (status != ERROR_SUCCESS) return std::nullopt;
    return QString::fromWCharArray(buffer.c_str());
}
#endif

} // namespace

bool contains(const QString &value, const QString &directory, const Expand &expand) {
    const QString wanted = normalized(directory, expand);
    if (wanted.isEmpty()) return false;
    for (const QString &entry : value.split(';', Qt::SkipEmptyParts)) {
        if (normalized(entry, expand) == wanted) return true;
    }
    return false;
}

QString withDirectory(const QString &value, const QString &directory, bool add, const Expand &expand) {
    const QString wanted = normalized(directory, expand);
    QStringList entries;
    bool present = false;
    for (const QString &entry : value.split(';', Qt::SkipEmptyParts)) {
        if (entry.trimmed().isEmpty()) continue;
        if (normalized(entry, expand) == wanted) {
            present = true;
            if (!add) continue;
        }
        entries.append(entry);
    }
    if (add && !present) entries.append(QDir::toNativeSeparators(directory));
    return entries.join(';');
}

QString expandEnvironment(const QString &value) {
#ifdef Q_OS_WIN
    const std::wstring input = value.toStdWString();
    const DWORD needed = ExpandEnvironmentStringsW(input.c_str(), nullptr, 0);
    if (needed == 0) return value;
    std::wstring output(needed, L'\0');
    if (ExpandEnvironmentStringsW(input.c_str(), output.data(), needed) == 0) return value;
    return QString::fromWCharArray(output.c_str());
#else
    return value;
#endif
}

std::optional<QString> userPath() {
#ifdef Q_OS_WIN
    return readValue(HKEY_CURRENT_USER, L"Environment");
#else
    return std::nullopt;
#endif
}

QString systemPath() {
#ifdef Q_OS_WIN
    return readValue(HKEY_LOCAL_MACHINE, L"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment").value_or(QString());
#else
    return QString();
#endif
}

bool setUserPath(const QString &value, QString *error) {
#ifdef Q_OS_WIN
    const std::wstring data = value.toStdWString();
    const LSTATUS status = RegSetKeyValueW(HKEY_CURRENT_USER, L"Environment", L"Path", REG_EXPAND_SZ, data.c_str(),
                                           DWORD((data.size() + 1) * sizeof(wchar_t)));
    if (status != ERROR_SUCCESS) {
        if (error) *error = QStringLiteral("RegSetKeyValueW failed (%1)").arg(status);
        return false;
    }
    // Explorer re-reads the environment, so terminals started from it get the new PATH.
    SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, LPARAM(L"Environment"), SMTO_ABORTIFHUNG, 2000, nullptr);
    return true;
#else
    if (error) *error = QStringLiteral("Only supported on Windows");
    Q_UNUSED(value);
    return false;
#endif
}

} // namespace asb::clipath
