#include "I18n.h"

#include <QFile>
#include <QHash>
#include <QJsonDocument>
#include <QJsonObject>

namespace asb::i18n {
namespace {

QString g_language = QStringLiteral("en");
QString g_tablePath = QStringLiteral(":/translations.json");
bool g_loaded = false;
QHash<QString, QHash<QString, QString>> g_tables; // code -> English -> translation

const QHash<QString, QHash<QString, QString>> &tables() {
    if (!g_loaded) {
        g_loaded = true;
        QFile file(g_tablePath);
        if (file.open(QIODevice::ReadOnly)) {
            const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
            for (auto it = root.constBegin(); it != root.constEnd(); ++it) {
                QHash<QString, QString> &table = g_tables[it.key()];
                const QJsonObject entries = it.value().toObject();
                for (auto e = entries.constBegin(); e != entries.constEnd(); ++e) table.insert(e.key(), e.value().toString());
            }
        }
    }
    return g_tables;
}

} // namespace

QString systemLanguage(const QStringList &uiLanguages) {
    for (const QString &identifier : uiLanguages) {
        const QString n = QString(identifier).replace('_', '-').toLower();
        if (n.startsWith("zh-hant") || n.startsWith("zh-tw") || n.startsWith("zh-hk") || n.startsWith("zh-mo"))
            return QStringLiteral("zh-Hant");
        if (n.startsWith("zh")) return QStringLiteral("zh-Hans");
        for (const char *code : {"ja", "ko", "es", "fr", "de", "pt", "en"}) {
            if (n.startsWith(QLatin1String(code))) return QString::fromLatin1(code);
        }
    }
    return QStringLiteral("en");
}

QString resolve(const QString &preference, const QStringList &uiLanguages) {
    static const QStringList supported = {"zh-Hans", "zh-Hant", "en", "ja", "ko", "es", "fr", "de", "pt"};
    if (preference == "system" || preference.isEmpty()) return systemLanguage(uiLanguages);
    return supported.contains(preference) ? preference : QStringLiteral("en");
}

void setLanguage(const QString &code) { g_language = code; }
QString language() { return g_language; }

QString translate(const QString &english) {
    if (g_language == "en" || g_language == "zh-Hans") return english;
    const auto table = tables().constFind(g_language);
    if (table == tables().constEnd()) return english;
    return table->value(english, english);
}

QString text(const QString &zhHans, const QString &english) {
    return g_language == "zh-Hans" ? zhHans : translate(english);
}

QVariantMap table(const QString &code) {
    QVariantMap map;
    const auto table = tables().constFind(code);
    if (table == tables().constEnd()) return map;
    for (auto it = table->cbegin(); it != table->cend(); ++it) map.insert(it.key(), it.value());
    return map;
}

void loadTable(const QString &path) {
    g_tablePath = path;
    g_loaded = false;
    g_tables.clear();
}

bool usesChineseNumbers() { return g_language == "zh-Hans" || g_language == "zh-Hant"; }

QLocale locale() {
    if (g_language == "zh-Hans") return QLocale(QLocale::Chinese, QLocale::SimplifiedChineseScript, QLocale::China);
    if (g_language == "zh-Hant") return QLocale(QLocale::Chinese, QLocale::TraditionalChineseScript, QLocale::Taiwan);
    return QLocale(g_language);
}

} // namespace asb::i18n
