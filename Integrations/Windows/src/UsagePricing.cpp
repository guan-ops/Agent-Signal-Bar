#include "UsagePricing.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <algorithm>

namespace asb::usage {
namespace {

struct CodexPricing {
    double input;
    double output;
    std::optional<double> cacheRead;
    std::optional<int> threshold;
    std::optional<double> inputAbove;
    std::optional<double> outputAbove;
    std::optional<double> cacheReadAbove;
    std::optional<double> priorityInput;
    std::optional<double> priorityOutput;
    std::optional<double> priorityCacheRead;
    std::optional<double> priorityLongContextMultiplier;
};

struct ClaudePricing {
    double input;
    double output;
    double cacheCreation;
    double cacheRead;
    std::optional<int> threshold;
    std::optional<double> inputAbove;
    std::optional<double> outputAbove;
    std::optional<double> cacheCreationAbove;
    std::optional<double> cacheReadAbove;
};

constexpr std::nullopt_t none = std::nullopt;

// Long-context Codex models: threshold 272K, the above-threshold and priority rates.
CodexPricing tiered(double in, double out, double cache, double inAbove, double outAbove, double cacheAbove,
                    double pIn, double pOut, double pCache, std::optional<double> multiplier) {
    return {in, out, cache, 272'000, inAbove, outAbove, cacheAbove, pIn, pOut, pCache, multiplier};
}
CodexPricing flat(double in, double out, std::optional<double> cache) {
    return {in, out, cache, none, none, none, none, none, none, none, none};
}

// Verified 2026-09-23 (https://developers.openai.com/api/docs/pricing), as on macOS.
const QHash<QString, CodexPricing> &codexTable() {
    static const QHash<QString, CodexPricing> table = {
        {"gpt-6-astra", tiered(1e-5, 5e-5, 1e-6, 2e-5, 7.5e-5, 2e-6, 2e-5, 1e-4, 2e-6, 2)},
        {"gpt-6.1-sol", tiered(2e-6, 1e-5, 1e-7, 4e-6, 1.5e-5, 2e-7, 4e-6, 2e-5, 2e-7, 2)},
        {"gpt-6-sol", tiered(2e-6, 1e-5, 2e-7, 4e-6, 1.5e-5, 4e-7, 4e-6, 2e-5, 4e-7, 2)},
        {"gpt-6-luna", tiered(1e-7, 5e-7, 1e-8, 2e-7, 7.5e-7, 2e-8, 2e-7, 1e-6, 2e-8, 2)},
        {"gpt-5", flat(1.25e-6, 1e-5, 1.25e-7)},
        {"gpt-5-codex", flat(1.25e-6, 1e-5, 1.25e-7)},
        {"gpt-5-mini", flat(2.5e-7, 2e-6, 2.5e-8)},
        {"gpt-5-nano", flat(5e-8, 4e-7, 5e-9)},
        {"gpt-5-pro", flat(1.5e-5, 1.2e-4, none)},
        {"gpt-5.1", flat(1.25e-6, 1e-5, 1.25e-7)},
        {"gpt-5.1-codex", flat(1.25e-6, 1e-5, 1.25e-7)},
        {"gpt-5.1-codex-max", flat(1.25e-6, 1e-5, 1.25e-7)},
        {"gpt-5.1-codex-mini", flat(2.5e-7, 2e-6, 2.5e-8)},
        {"gpt-5.2", flat(1.75e-6, 1.4e-5, 1.75e-7)},
        {"gpt-5.2-codex", flat(1.75e-6, 1.4e-5, 1.75e-7)},
        {"gpt-5.2-pro", flat(2.1e-5, 1.68e-4, none)},
        {"gpt-5.3-codex", flat(1.75e-6, 1.4e-5, 1.75e-7)},
        {"gpt-5.4", tiered(2.5e-6, 1.5e-5, 2.5e-7, 5e-6, 2.25e-5, 5e-7, 5e-6, 3e-5, 5e-7, none)},
        {"gpt-5.4-mini", {7.5e-7, 4.5e-6, 7.5e-8, none, none, none, none, 1.5e-6, 9e-6, 1.5e-7, none}},
        {"gpt-5.4-nano", flat(2e-7, 1.25e-6, 2e-8)},
        {"gpt-5.4-pro", flat(3e-5, 1.8e-4, none)},
        {"gpt-5.5", tiered(5e-6, 3e-5, 5e-7, 1e-5, 4.5e-5, 1e-6, 1.25e-5, 7.5e-5, 1.25e-6, none)},
        {"gpt-5.5-pro", flat(3e-5, 1.8e-4, none)},
        {"gpt-5.6-sol", tiered(4e-6, 2e-5, 4e-7, 8e-6, 3e-5, 8e-7, 8e-6, 4e-5, 8e-7, 2)},
        {"gpt-5.6-terra", tiered(2e-6, 1.2e-5, 2e-7, 4e-6, 1.8e-5, 4e-7, 4e-6, 2.4e-5, 4e-7, 2)},
        {"gpt-5.6-luna", tiered(2e-7, 1.2e-6, 2e-8, 4e-7, 1.8e-6, 4e-8, 4e-7, 2.4e-6, 4e-8, 2)},
    };
    return table;
}

const QSet<QString> &codexOfficialModels() {
    static const QSet<QString> models = {"gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
                                         "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"};
    return models;
}

ClaudePricing claudeFlat(double in, double out, double create, double read) {
    return {in, out, create, read, none, none, none, none, none};
}
ClaudePricing claudeLong(double in, double out, double create, double read, double inA, double outA, double createA,
                         double readA) {
    return {in, out, create, read, 200'000, inA, outA, createA, readA};
}

const QHash<QString, ClaudePricing> &claudeTable() {
    static const QHash<QString, ClaudePricing> table = {
        {"claude-fable-5", claudeFlat(1e-5, 5e-5, 1.25e-5, 1e-6)},
        {"claude-haiku-4-5-20251001", claudeFlat(1e-6, 5e-6, 1.25e-6, 1e-7)},
        {"claude-haiku-4-5", claudeFlat(1e-6, 5e-6, 1.25e-6, 1e-7)},
        {"claude-opus-4-5-20251101", claudeFlat(5e-6, 2.5e-5, 6.25e-6, 5e-7)},
        {"claude-opus-4-5", claudeFlat(5e-6, 2.5e-5, 6.25e-6, 5e-7)},
        {"claude-opus-4-6-20260205", claudeFlat(5e-6, 2.5e-5, 6.25e-6, 5e-7)},
        {"claude-opus-4-6", claudeFlat(5e-6, 2.5e-5, 6.25e-6, 5e-7)},
        {"claude-opus-4-7", claudeFlat(5e-6, 2.5e-5, 6.25e-6, 5e-7)},
        {"claude-opus-4-8", claudeFlat(5e-6, 2.5e-5, 6.25e-6, 5e-7)},
        {"claude-sonnet-4-5", claudeLong(3e-6, 1.5e-5, 3.75e-6, 3e-7, 6e-6, 2.25e-5, 7.5e-6, 6e-7)},
        {"claude-sonnet-4-6", claudeFlat(3e-6, 1.5e-5, 3.75e-6, 3e-7)},
        {"claude-sonnet-4-5-20250929", claudeLong(3e-6, 1.5e-5, 3.75e-6, 3e-7, 6e-6, 2.25e-5, 7.5e-6, 6e-7)},
        {"claude-opus-4-20250514", claudeFlat(1.5e-5, 7.5e-5, 1.875e-5, 1.5e-6)},
        {"claude-opus-4-1", claudeFlat(1.5e-5, 7.5e-5, 1.875e-5, 1.5e-6)},
        {"claude-sonnet-4-20250514", claudeLong(3e-6, 1.5e-5, 3.75e-6, 3e-7, 6e-6, 2.25e-5, 7.5e-6, 6e-7)},
    };
    return table;
}

// Before 2026-03-13 (claudeFullContextStandardPricingCutoff) these had long-context rates.
constexpr qint64 kClaudeFullContextCutoffMs = 1'773'360'000'000;
const QHash<QString, ClaudePricing> &claudeHistoricalLongContext() {
    static const QHash<QString, ClaudePricing> table = {
        {"claude-opus-4-6", claudeLong(5e-6, 2.5e-5, 6.25e-6, 5e-7, 1e-5, 3.75e-5, 1.25e-5, 1e-6)},
        {"claude-sonnet-4-6", claudeLong(3e-6, 1.5e-5, 3.75e-6, 3e-7, 6e-6, 2.25e-5, 7.5e-6, 6e-7)},
    };
    return table;
}

double codexCost(const CodexPricing &p, qint64 inputTokens, qint64 cachedTokens, qint64 outputTokens) {
    const qint64 input = std::max<qint64>(0, inputTokens);
    const qint64 cached = std::min(std::max<qint64>(0, cachedTokens), input);
    const qint64 nonCached = std::max<qint64>(0, input - cached);
    const double cachedRate = p.cacheRead.value_or(p.input);
    const bool longContext = p.threshold && input > *p.threshold;
    const double inputRate = longContext ? p.inputAbove.value_or(p.input) : p.input;
    const double cachedInputRate = longContext ? p.cacheReadAbove.value_or(cachedRate) : cachedRate;
    const double outputRate = longContext ? p.outputAbove.value_or(p.output) : p.output;
    return double(nonCached) * inputRate + double(cached) * cachedInputRate
        + double(std::max<qint64>(0, outputTokens)) * outputRate;
}

double claudeCost(const ClaudePricing &p, qint64 inputTokens, qint64 cacheReadTokens, qint64 cacheCreationTokens,
                  qint64 cacheCreation1hTokens, qint64 outputTokens) {
    const qint64 input = std::max<qint64>(0, inputTokens);
    const qint64 cacheRead = std::max<qint64>(0, cacheReadTokens);
    const qint64 creation = std::max<qint64>(0, cacheCreationTokens);
    const qint64 creation1h = std::min(std::max<qint64>(0, cacheCreation1hTokens), creation);
    const qint64 creation5m = creation - creation1h;
    const bool longContext = p.threshold && input + cacheRead + creation > *p.threshold;
    const double inputRate = longContext ? p.inputAbove.value_or(p.input) : p.input;
    const double readRate = longContext ? p.cacheReadAbove.value_or(p.cacheRead) : p.cacheRead;
    const double createRate = longContext ? p.cacheCreationAbove.value_or(p.cacheCreation) : p.cacheCreation;
    const double outputRate = longContext ? p.outputAbove.value_or(p.output) : p.output;
    return double(input) * inputRate + double(cacheRead) * readRate + double(creation5m) * createRate
        + double(creation1h) * inputRate * 2 + double(std::max<qint64>(0, outputTokens)) * outputRate;
}

QString normalizedProvider(const QString &raw) { return raw.trimmed().toLower(); }

std::optional<double> number(const QJsonObject &object, const char *key) {
    const QJsonValue value = object.value(QLatin1String(key));
    if (!value.isDouble()) return std::nullopt;
    return value.toDouble();
}

std::optional<ModelsDevPricing> modelPricing(const QJsonObject &model) {
    const QJsonObject cost = model.value("cost").toObject();
    const auto input = number(cost, "input");
    const auto output = number(cost, "output");
    if (!input || !output) return std::nullopt;
    constexpr double unit = 1'000'000.0; // models.dev publishes USD per 1M tokens
    const auto per = [](std::optional<double> v) { return v ? std::optional<double>(*v / unit) : std::nullopt; };
    ModelsDevPricing p;
    p.input = *input / unit;
    p.output = *output / unit;
    p.cacheRead = per(number(cost, "cache_read"));
    p.cacheCreation = per(number(cost, "cache_write"));
    if (cost.value("context_over_200k").isObject()) {
        const QJsonObject over = cost.value("context_over_200k").toObject();
        p.threshold = 200'000;
        p.inputAbove = per(number(over, "input"));
        p.outputAbove = per(number(over, "output"));
        p.cacheReadAbove = per(number(over, "cache_read"));
        p.cacheCreationAbove = per(number(over, "cache_write"));
    }
    return p;
}

std::optional<ModelsDevPricing> catalogLookup(const ModelsDevCatalog *catalog, const char *provider, const QString &model) {
    return catalog ? catalog->pricing(QString::fromLatin1(provider), model) : std::nullopt;
}

} // namespace

// --- models.dev ------------------------------------------------------------------------------

std::optional<ModelsDevCatalog> ModelsDevCatalog::fromJson(const QByteArray &json) {
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return std::nullopt;
    QJsonObject root = document.object();
    if (root.value("providers").isObject()) root = root.value("providers").toObject();
    ModelsDevCatalog catalog;
    for (auto it = root.constBegin(); it != root.constEnd(); ++it) {
        if (!it.value().isObject()) continue;
        const QJsonObject provider = it.value().toObject();
        if (!provider.value("models").isObject()) continue;
        const QString id = normalizedProvider(provider.value("id").toString(it.key()));
        QHash<QString, Model> &models = catalog.m_providers[id];
        const QJsonObject list = provider.value("models").toObject();
        for (auto m = list.constBegin(); m != list.constEnd(); ++m) {
            if (!m.value().isObject()) continue;
            const QJsonObject model = m.value().toObject();
            const QString modelID = model.value("id").toString();
            if (modelID.isEmpty()) continue; // `id` is required by the Swift decoder
            models.insert(m.key(), Model{modelID, modelPricing(model)});
        }
    }
    return catalog;
}

std::optional<ModelsDevPricing> ModelsDevCatalog::pricing(const QString &providerID, const QString &modelID) const {
    const auto provider = m_providers.constFind(normalizedProvider(providerID));
    if (provider == m_providers.constEnd()) return std::nullopt;
    for (const QString &candidate : modelsDevCandidates(modelID)) {
        const auto exact = provider->constFind(candidate);
        if (exact != provider->constEnd() && exact->pricing) return exact->pricing;
        for (const Model &model : *provider) {
            if (model.id.trimmed() == candidate && model.pricing) return model.pricing;
        }
    }
    return std::nullopt;
}

bool ModelsDevCatalog::isPlausible() const {
    for (const char *id : {"anthropic", "openai"}) {
        const auto provider = m_providers.constFind(QString::fromLatin1(id));
        if (provider == m_providers.constEnd()) return false;
        if (std::none_of(provider->cbegin(), provider->cend(), [](const Model &m) { return m.pricing.has_value(); }))
            return false;
    }
    return true;
}

QStringList modelsDevCandidates(const QString &raw) {
    static const QRegularExpression eightDigits("^\\d{8}$");
    static const QRegularExpression dashedDate("-\\d{4}-\\d{2}-\\d{2}$");
    static const QRegularExpression compactDate("-\\d{8}$");
    static const QRegularExpression version("-v\\d+:\\d+$");
    QStringList candidates;
    const auto append = [&](const QString &value) {
        const QString normalized = value.trimmed();
        if (!normalized.isEmpty() && !candidates.contains(normalized)) candidates.append(normalized);
    };
    const QString trimmed = raw.trimmed();
    append(trimmed);
    if (trimmed.startsWith("openai/")) append(trimmed.mid(7));
    if (trimmed.startsWith("anthropic.")) append(trimmed.mid(10));
    if (trimmed.contains("claude-")) {
        const qsizetype dot = trimmed.lastIndexOf('.');
        if (dot >= 0 && trimmed.mid(dot + 1).startsWith("claude-")) append(trimmed.mid(dot + 1));
    }
    for (qsizetype i = 0; i < candidates.size(); ++i) {
        const QString candidate = candidates.at(i);
        const qsizetype at = candidate.indexOf('@');
        if (at >= 0) {
            const QString base = candidate.left(at);
            const QString suffix = candidate.mid(at + 1);
            if (eightDigits.match(suffix).hasMatch()) append(base + '-' + suffix);
            append(base);
        } else if (candidate.startsWith("claude-")) {
            append(candidate + "@default");
        }
        if (const auto m = dashedDate.match(candidate); m.hasMatch()) append(candidate.left(m.capturedStart()));
        if (const auto m = compactDate.match(candidate); m.hasMatch()) append(candidate.left(m.capturedStart()));
        if (const auto m = version.match(candidate); m.hasMatch()) append(candidate.left(m.capturedStart()));
    }
    return candidates;
}

// --- Model names -----------------------------------------------------------------------------

QString normalizeCodexModel(const QString &raw) {
    static const QRegularExpression dated("-\\d{4}-\\d{2}-\\d{2}$");
    QString trimmed = raw.trimmed();
    if (trimmed.startsWith("openai/")) trimmed = trimmed.mid(7);
    if (codexTable().contains(trimmed)) return trimmed;
    if (const auto m = dated.match(trimmed); m.hasMatch()) {
        const QString base = trimmed.left(m.capturedStart());
        if (codexTable().contains(base)) return base;
    }
    return trimmed;
}

QString normalizeClaudeModel(const QString &raw) {
    static const QRegularExpression version("-v\\d+:\\d+$");
    static const QRegularExpression compactDate("-\\d{8}$");
    QString trimmed = raw.trimmed();
    if (trimmed.startsWith("anthropic.")) trimmed = trimmed.mid(10);
    if (trimmed.contains("claude-")) {
        const qsizetype dot = trimmed.lastIndexOf('.');
        if (dot >= 0 && trimmed.mid(dot + 1).startsWith("claude-")) trimmed = trimmed.mid(dot + 1);
    }
    if (const auto m = version.match(trimmed); m.hasMatch()) trimmed = trimmed.left(m.capturedStart());
    if (const auto m = compactDate.match(trimmed); m.hasMatch()) {
        const QString base = trimmed.left(m.capturedStart());
        if (claudeTable().contains(base)) return base;
    }
    return trimmed;
}

// --- Costs -----------------------------------------------------------------------------------

std::optional<double> codexCostUSD(const QString &model, qint64 input, qint64 cached, qint64 output,
                                   const ModelsDevCatalog *catalog) {
    const QString key = normalizeCodexModel(model);
    const auto bundled = codexTable().constFind(key);
    const bool hasBundled = bundled != codexTable().constEnd();
    if (codexOfficialModels().contains(key) && hasBundled) return codexCost(*bundled, input, cached, output);
    if (const auto lookup = catalogLookup(catalog, "openai", model)) {
        // The bundled context tier fills in only when the catalog has no tier at all.
        const CodexPricing *fallback = !lookup->threshold && hasBundled ? &*bundled : nullptr;
        CodexPricing p{lookup->input, lookup->output, lookup->cacheRead,
                       hasBundled && bundled->threshold ? bundled->threshold : lookup->threshold,
                       lookup->inputAbove ? lookup->inputAbove : (fallback ? fallback->inputAbove : none),
                       lookup->outputAbove ? lookup->outputAbove : (fallback ? fallback->outputAbove : none),
                       lookup->cacheReadAbove ? lookup->cacheReadAbove : (fallback ? fallback->cacheReadAbove : none),
                       none, none, none, none};
        return codexCost(p, input, cached, output);
    }
    if (!hasBundled) return std::nullopt;
    return codexCost(*bundled, input, cached, output);
}

std::optional<double> claudeCostUSD(const QString &model, qint64 input, qint64 cacheRead, qint64 cacheCreation,
                                    qint64 cacheCreation1h, qint64 output, std::optional<qint64> pricingDateMs,
                                    const ModelsDevCatalog *catalog) {
    const QString key = normalizeClaudeModel(model);
    const auto historical = claudeHistoricalLongContext().constFind(key);
    const auto current = claudeTable().constFind(key);
    if (pricingDateMs && historical != claudeHistoricalLongContext().constEnd() && current != claudeTable().constEnd()) {
        const ClaudePricing &p = *pricingDateMs < kClaudeFullContextCutoffMs ? *historical : *current;
        return claudeCost(p, input, cacheRead, cacheCreation, cacheCreation1h, output);
    }
    if (const auto lookup = catalogLookup(catalog, "anthropic", model)) {
        const ClaudePricing p{lookup->input, lookup->output, lookup->cacheCreation.value_or(lookup->input),
                              lookup->cacheRead.value_or(lookup->input), lookup->threshold, lookup->inputAbove,
                              lookup->outputAbove, lookup->cacheCreationAbove, lookup->cacheReadAbove};
        return claudeCost(p, input, cacheRead, cacheCreation, cacheCreation1h, output);
    }
    if (current == claudeTable().constEnd()) return std::nullopt;
    return claudeCost(*current, input, cacheRead, cacheCreation, cacheCreation1h, output);
}

// --- Presentation ----------------------------------------------------------------------------

ModelPresentation codexModelPresentation(const QString &raw) {
    const QString model = normalizeCodexModel(raw.toLower());
    static const QHash<QString, ModelPresentation> named = {
        {"gpt-6.1-sol", {"GPT-6.1 Sol", -1, "#EE7430"}}, {"gpt-6-astra", {"GPT-6 Astra", 0, "#6F52F0"}},
        {"gpt-6-sol", {"GPT-6 Sol", 1, "#E85028"}},      {"gpt-6-luna", {"GPT-6 Luna", 2, "#F8D068"}},
        {"gpt-5.6-sol", {"GPT-5.6 Sol", 10, "#D56F9B"}}, {"gpt-5.6-terra", {"GPT-5.6 Terra", 11, "#6BAB73"}},
        {"gpt-5.6-luna", {"GPT-5.6 Luna", 12, "#4CB8B0"}}, {"gpt-5.5", {"GPT-5.5", 20, "#919BB0"}}};
    if (const auto it = named.constFind(model); it != named.constEnd()) return *it;
    static const QList<std::tuple<QString, int, QString>> families = {
        {"gpt-5.5", 20, "#919BB0"}, {"gpt-5.4", 30, "#C3AA55"}, {"gpt-5.3", 40, "#CE8071"},
        {"gpt-5.2", 50, "#7C97C4"}, {"gpt-5.1", 60, "#91A66A"}, {"gpt-5", 70, "#8B889F"}};
    for (const auto &[family, rank, color] : families) {
        if (model == family || model.startsWith(family + '-')) return {raw, rank, color};
    }
    if (model == "codex-auto-review") return {raw, 80, "#B69684"};
    return {raw, model == "__other__" ? 900 : 800, QString()};
}

ModelPresentation claudeModelPresentation(const QString &raw) {
    // UsageTokenHistoryChart: purple / indigo / teal for opus / sonnet / haiku (system colours).
    const QString name = raw.toLower();
    if (name.contains("opus")) return {raw, 0, "#AF52DE"};
    if (name.contains("sonnet")) return {raw, 1, "#5856D6"};
    if (name.contains("haiku")) return {raw, 2, "#30B0C7"};
    return {raw, 99, QString()};
}

} // namespace asb::usage
