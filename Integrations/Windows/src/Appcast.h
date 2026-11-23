#pragma once

#include <QByteArray>
#include <QList>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <optional>

// Sparkle appcasts (the RSS feed that generate_appcast writes and macOS reads from GitHub
// Releases). The Windows feed uses the same format; its enclosures carry sparkle:os="windows".
namespace asb::appcast {

struct Item {
    QString title;
    QString version;      // sparkle:version, compared with the running build (CFBundleVersion)
    QString shortVersion; // sparkle:shortVersionString, shown to people
    QString channel;      // sparkle:channel; empty for the default (stable) channel
    QString minimumSystemVersion;
    QString maximumSystemVersion;
    QString pubDate;
    QString notes;        // <description>
    QString notesFormat;  // "markdown", "plain-text" or "html" (Sparkle's default)
    QUrl releaseNotesLink;
    QUrl fullReleaseNotesLink;
    QUrl link;            // <link>: the page an informational update opens
    bool critical = false;
    bool informational = false;
    // The enclosure.
    QUrl url;
    qint64 length = -1;
    QString os;
    QByteArray edSignature; // decoded from base64; empty when missing or malformed

    QString displayVersion() const { return shortVersion.isEmpty() ? version : shortVersion; }
};

// Every <item> of the feed. On malformed XML the result is empty and `error` says why.
QList<Item> parse(const QByteArray &xml, QString *error = nullptr);

// SUStandardVersionComparator: < 0 when a is older than b, 0 when equal, > 0 when newer.
// Numbers compare numerically, a trailing string marks a pre-release ("1.0b1" < "1.0"), and
// trailing ".0" parts do not count.
int compareVersions(const QString &a, const QString &b);

struct Criteria {
    QString currentVersion;          // the running build number
    QString osVersion;               // "10.0.26100"
    QStringList channels = {QString()}; // allowed sparkle:channel values ("" = stable)
    QString skippedVersion;          // SUSkippedVersion; ignored for user-initiated checks
    bool userInitiated = false;
};

// The newest item for this system that is newer than the running build, or nothing.
// Only Windows enclosures with a URL and an EdDSA signature count (informational items need
// neither), so a feed meant for macOS can never install a disk image here.
std::optional<Item> bestUpdate(const QList<Item> &items, const Criteria &criteria);

// Whether the item is for Windows at all (sparkle:os="windows" or "windows-x64").
bool isWindowsItem(const Item &item);

} // namespace asb::appcast
