// Port of CostUsagePricing.swift and ModelsDevPricing.swift: USD estimates for Codex and Claude
// token usage. These are API list prices, not subscription charges.
//
// Codex: the official OpenAI rates for the newest models win; otherwise the models.dev catalog
// (with the bundled long-context tier when the catalog has none); otherwise the bundled table.
// Claude: dated historical long-context rates for opus/sonnet 4.6, then models.dev, then the
// bundled table. Long-context rates apply per request above the threshold (272K input tokens for
// Codex, 200K input + cache tokens for Claude).
//
// The models.dev catalog (https://models.dev/api.json, USD per 1M tokens) is optional: the app
// fetches it at most once a day and caches it; without it only the bundled models are priced.
// Not ported: Codex priority ("fast") turn pricing, which needs Codex's trace database.
#pragma once

#include <QByteArray>
#include <QHash>
#include <QString>
#include <QStringList>
#include <optional>

namespace asb::usage {

struct ModelsDevPricing {
    double input = 0;
    double output = 0;
    std::optional<double> cacheRead;
    std::optional<double> cacheCreation;
    std::optional<int> threshold; // 200 000 when the model has context_over_200k rates
    std::optional<double> inputAbove;
    std::optional<double> outputAbove;
    std::optional<double> cacheReadAbove;
    std::optional<double> cacheCreationAbove;
};

class ModelsDevCatalog {
public:
    // The api.json document: {provider: {id, name, models: {key: {id, cost, ...}}}} or the same
    // map under "providers". nullopt when it does not parse.
    static std::optional<ModelsDevCatalog> fromJson(const QByteArray &json);
    std::optional<ModelsDevPricing> pricing(const QString &providerID, const QString &modelID) const;
    // Both direct pricing sources (anthropic, openai) have at least one priced model.
    bool isPlausible() const;
    bool isEmpty() const { return m_providers.isEmpty(); }

private:
    struct Model {
        QString id;
        std::optional<ModelsDevPricing> pricing;
    };
    QHash<QString, QHash<QString, Model>> m_providers; // normalized provider id -> key -> model
};

// ModelsDevModelIDNormalizer.candidates: the raw id, provider prefixes stripped, "@date" and
// "@default" aliases, and dated or "-v1:0" suffixes removed.
QStringList modelsDevCandidates(const QString &raw);

QString normalizeCodexModel(const QString &raw);
QString normalizeClaudeModel(const QString &raw);

std::optional<double> codexCostUSD(const QString &model, qint64 input, qint64 cached, qint64 output,
                                   const ModelsDevCatalog *catalog = nullptr);
// `pricingDateMs`: the request time, which picks the historical long-context rates.
std::optional<double> claudeCostUSD(const QString &model, qint64 input, qint64 cacheRead, qint64 cacheCreation,
                                    qint64 cacheCreation1h, qint64 output, std::optional<qint64> pricingDateMs = {},
                                    const ModelsDevCatalog *catalog = nullptr);

// CodexModelPresentation: display name, chart order and colour ("" for no colour).
struct ModelPresentation {
    QString displayName;
    int sortRank = 800;
    QString color;
};
ModelPresentation codexModelPresentation(const QString &raw);
ModelPresentation claudeModelPresentation(const QString &raw);

} // namespace asb::usage
