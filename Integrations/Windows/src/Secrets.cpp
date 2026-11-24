#include "Secrets.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>

#ifdef Q_OS_WIN
#include <windows.h>
#include <dpapi.h>
#endif

namespace asb::secrets {

namespace {
constexpr char kEntropy[] = "AgentSignalBar.secret.v1";
}

std::optional<QByteArray> protect(const QByteArray &plain) {
#ifdef Q_OS_WIN
    DATA_BLOB in{DWORD(plain.size()), reinterpret_cast<BYTE *>(const_cast<char *>(plain.constData()))};
    DATA_BLOB entropy{DWORD(sizeof kEntropy - 1), reinterpret_cast<BYTE *>(const_cast<char *>(kEntropy))};
    DATA_BLOB out{};
    if (!CryptProtectData(&in, L"Agent Signal Bar", &entropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out))
        return std::nullopt;
    QByteArray result(reinterpret_cast<const char *>(out.pbData), int(out.cbData));
    LocalFree(out.pbData);
    return result;
#else
    return plain; // development builds only
#endif
}

std::optional<QByteArray> unprotect(const QByteArray &cipher) {
#ifdef Q_OS_WIN
    DATA_BLOB in{DWORD(cipher.size()), reinterpret_cast<BYTE *>(const_cast<char *>(cipher.constData()))};
    DATA_BLOB entropy{DWORD(sizeof kEntropy - 1), reinterpret_cast<BYTE *>(const_cast<char *>(kEntropy))};
    DATA_BLOB out{};
    if (!CryptUnprotectData(&in, nullptr, &entropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out))
        return std::nullopt;
    QByteArray result(reinterpret_cast<const char *>(out.pbData), int(out.cbData));
    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);
    return result;
#else
    return cipher;
#endif
}

bool writeProtected(const QString &path, const QByteArray &plain) {
    const auto cipher = protect(plain);
    if (!cipher) return false;
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(*cipher) == cipher->size() && file.commit();
}

std::optional<QByteArray> readProtected(const QString &path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return std::nullopt;
    return unprotect(file.readAll());
}

} // namespace asb::secrets
