// Per-user encrypted files (DPAPI, CryptProtectData with the user's key): the Windows stand-in for
// the macOS Keychain items that hold saved Codex accounts and pasted cookies. Only the same
// Windows user on the same machine can read them back. Files are replaced atomically.
#pragma once

#include <QByteArray>
#include <QString>
#include <optional>

namespace asb::secrets {

std::optional<QByteArray> protect(const QByteArray &plain);
std::optional<QByteArray> unprotect(const QByteArray &cipher);
bool writeProtected(const QString &path, const QByteArray &plain);
std::optional<QByteArray> readProtected(const QString &path);

} // namespace asb::secrets
