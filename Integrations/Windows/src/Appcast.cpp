#include "Appcast.h"

#include <QXmlStreamReader>

#include <algorithm>

namespace asb::appcast {
namespace {

const QString kSparkleNs = QStringLiteral("http://www.andymatuschak.org/xml-namespaces/sparkle");

enum class Part { Number, Separator, String };

Part partType(QChar c) {
    if (c.isDigit()) return Part::Number;
    if (c == '.') return Part::Separator;
    return Part::String;
}

// "1.10b2" -> 1 . 10 b 2: runs of digits or other text; every period is its own part.
QStringList split(const QString &version) {
    QStringList parts;
    QString current;
    std::optional<Part> type;
    for (QChar c : version.trimmed()) {
        if (c.isSpace()) continue;
        const Part next = partType(c);
        if (!type || next != *type || next == Part::Separator) {
            if (!current.isEmpty()) parts.append(current);
            current.clear();
        }
        current += c;
        type = next;
    }
    if (!current.isEmpty()) parts.append(current);
    return parts;
}

QString text(QXmlStreamReader &xml) {
    return xml.readElementText(QXmlStreamReader::IncludeChildElements).trimmed();
}

QString sparkleAttribute(const QXmlStreamAttributes &attributes, const QString &name) {
    QString value = attributes.value(kSparkleNs, name).toString();
    if (value.isEmpty()) value = attributes.value(QStringLiteral("sparkle:") + name).toString();
    return value.trimmed();
}

bool isSparkle(const QXmlStreamReader &xml, QLatin1String name) {
    return xml.name() == name && xml.namespaceUri() == kSparkleNs;
}

} // namespace

int compareVersions(const QString &a, const QString &b) {
    const QStringList left = split(a);
    const QStringList right = split(b);
    const qsizetype n = std::min(left.size(), right.size());
    for (qsizetype i = 0; i < n; ++i) {
        const Part ta = partType(left[i].front());
        const Part tb = partType(right[i].front());
        if (ta == tb) {
            if (ta == Part::Number) {
                // Compare as digit strings: build numbers can exceed 64 bits in odd feeds.
                QString x = left[i], y = right[i];
                while (x.size() > 1 && x.front() == '0') x.remove(0, 1);
                while (y.size() > 1 && y.front() == '0') y.remove(0, 1);
                if (x.size() != y.size()) return x.size() < y.size() ? -1 : 1;
                if (const int c = x.compare(y); c != 0) return c < 0 ? -1 : 1;
            } else if (ta == Part::String) {
                if (const int c = left[i].compare(right[i]); c != 0) return c < 0 ? -1 : 1;
            }
            continue;
        }
        // A number or period beats a string; a number beats a period.
        if (ta != Part::String && tb == Part::String) return 1;
        if (ta == Part::String && tb != Part::String) return -1;
        return ta == Part::Number ? 1 : -1;
    }
    if (left.size() == right.size()) return 0;
    const QStringList &longer = left.size() > right.size() ? left : right;
    // Trailing ".0" parts do not change the version: 1.2 == 1.2.0.
    if (std::all_of(longer.begin() + n, longer.end(), [](const QString &part) {
            return part == QLatin1String(".") || std::all_of(part.begin(), part.end(), [](QChar c) { return c == '0'; });
        }))
        return 0;
    // One has more parts: extra text marks a pre-release (shorter wins), extra numbers a newer one.
    const bool leftLonger = left.size() > right.size();
    const Part extra = partType((leftLonger ? left : right).at(n).front());
    if (extra == Part::String) return leftLonger ? -1 : 1;
    return leftLonger ? 1 : -1;
}

QList<Item> parse(const QByteArray &data, QString *error) {
    QList<Item> items;
    QXmlStreamReader xml(data);
    std::optional<Item> item;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            const auto name = xml.name();
            if (name == QLatin1String("item") && xml.namespaceUri().isEmpty()) {
                item = Item();
            } else if (!item) {
                continue;
            } else if (name == QLatin1String("title") && xml.namespaceUri().isEmpty()) {
                item->title = text(xml);
            } else if (name == QLatin1String("pubDate")) {
                item->pubDate = text(xml);
            } else if (name == QLatin1String("link") && xml.namespaceUri().isEmpty()) {
                item->link = QUrl(text(xml));
            } else if (name == QLatin1String("description") && xml.namespaceUri().isEmpty()) {
                const QString format = sparkleAttribute(xml.attributes(), QStringLiteral("format"));
                item->notesFormat = format.isEmpty() ? QStringLiteral("html") : format.toLower();
                item->notes = text(xml);
            } else if (isSparkle(xml, QLatin1String("version"))) {
                item->version = text(xml);
            } else if (isSparkle(xml, QLatin1String("shortVersionString"))) {
                item->shortVersion = text(xml);
            } else if (isSparkle(xml, QLatin1String("channel"))) {
                item->channel = text(xml);
            } else if (isSparkle(xml, QLatin1String("minimumSystemVersion"))) {
                item->minimumSystemVersion = text(xml);
            } else if (isSparkle(xml, QLatin1String("maximumSystemVersion"))) {
                item->maximumSystemVersion = text(xml);
            } else if (isSparkle(xml, QLatin1String("releaseNotesLink"))) {
                item->releaseNotesLink = QUrl(text(xml));
            } else if (isSparkle(xml, QLatin1String("fullReleaseNotesLink"))) {
                item->fullReleaseNotesLink = QUrl(text(xml));
            } else if (isSparkle(xml, QLatin1String("criticalUpdate"))) {
                item->critical = true;
                xml.skipCurrentElement();
            } else if (isSparkle(xml, QLatin1String("informationalUpdate"))) {
                item->informational = true;
                xml.skipCurrentElement();
            } else if (name == QLatin1String("enclosure")) {
                const QXmlStreamAttributes attributes = xml.attributes();
                item->url = QUrl(attributes.value(QStringLiteral("url")).toString().trimmed());
                bool ok = false;
                const qint64 length = attributes.value(QStringLiteral("length")).toLongLong(&ok);
                item->length = ok ? length : -1;
                item->os = sparkleAttribute(attributes, QStringLiteral("os")).toLower();
                const QByteArray signature = sparkleAttribute(attributes, QStringLiteral("edSignature")).toLatin1();
                const auto decoded = QByteArray::fromBase64Encoding(signature, QByteArray::AbortOnBase64DecodingErrors);
                item->edSignature = decoded ? *decoded : QByteArray();
                // Older feeds put the versions on the enclosure.
                if (item->version.isEmpty()) item->version = sparkleAttribute(attributes, QStringLiteral("version"));
                if (item->shortVersion.isEmpty())
                    item->shortVersion = sparkleAttribute(attributes, QStringLiteral("shortVersionString"));
            }
        } else if (xml.isEndElement() && xml.name() == QLatin1String("item") && item) {
            items.append(*item);
            item.reset();
        }
    }
    if (xml.hasError()) {
        if (error) *error = xml.errorString();
        return {};
    }
    if (error) error->clear();
    return items;
}

bool isWindowsItem(const Item &item) {
    return item.os == QLatin1String("windows") || item.os == QLatin1String("windows-x64");
}

std::optional<Item> bestUpdate(const QList<Item> &items, const Criteria &criteria) {
    std::optional<Item> best;
    for (const Item &item : items) {
        if (item.version.isEmpty() || !criteria.channels.contains(item.channel)) continue;
        if (item.informational) {
            if (!item.os.isEmpty() && !isWindowsItem(item)) continue;
        } else if (!isWindowsItem(item) || !item.url.isValid()
                   || !QStringList{"https", "http", "file"}.contains(item.url.scheme())
                   || item.edSignature.size() != 64) {
            continue;
        }
        if (!item.minimumSystemVersion.isEmpty() && compareVersions(criteria.osVersion, item.minimumSystemVersion) < 0)
            continue;
        if (!item.maximumSystemVersion.isEmpty() && compareVersions(criteria.osVersion, item.maximumSystemVersion) > 0)
            continue;
        if (!best || compareVersions(item.version, best->version) > 0) best = item;
    }
    if (!best || compareVersions(best->version, criteria.currentVersion) <= 0) return std::nullopt;
    // A skipped version stays hidden from scheduled checks until a newer one appears.
    if (!criteria.userInitiated && !criteria.skippedVersion.isEmpty()
        && compareVersions(best->version, criteria.skippedVersion) <= 0)
        return std::nullopt;
    return best;
}

} // namespace asb::appcast
