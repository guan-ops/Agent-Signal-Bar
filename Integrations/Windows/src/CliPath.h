// "Install CLI" (Settings → General): puts the install folder, which holds agent-signal.exe, on
// the user's PATH (HKCU\Environment\Path), so new terminals can run `agent-signal`. macOS copies
// the CLI into /usr/local/bin instead; Windows has no such shared folder, and the exe needs the
// Qt DLLs next to it.
#pragma once

#include <QString>
#include <functional>
#include <optional>

namespace asb::clipath {

using Expand = std::function<QString(const QString &)>;

// True when one entry of the PATH value `value` names `directory`: compared case-insensitively,
// with either slash, without a trailing one, after `expand` (%VAR% expansion; identity if empty).
bool contains(const QString &value, const QString &directory, const Expand &expand = {});
// `value` with `directory` appended (unless present) or with every entry naming it removed.
// Other entries keep their exact spelling; empty entries are dropped.
QString withDirectory(const QString &value, const QString &directory, bool add, const Expand &expand = {});

// %VAR% expansion through the system (ExpandEnvironmentStringsW).
QString expandEnvironment(const QString &value);
// The user PATH; "" when unset, nullopt when it cannot be read.
std::optional<QString> userPath();
// The machine PATH (read only); "" when it cannot be read.
QString systemPath();
// Writes the user PATH (REG_EXPAND_SZ) and tells running programs the environment changed.
bool setUserPath(const QString &value, QString *error);

} // namespace asb::clipath
