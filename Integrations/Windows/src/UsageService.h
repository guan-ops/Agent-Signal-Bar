// Background local-usage scans (MenuBarStatusModel's token activity refresh and
// ClaudeSupportModel.scanHistory) and the two public price feeds behind the estimates:
// - every 60 s while agents are active, every 5 min otherwise (doubled in low-power mode);
//   paused monitoring keeps the last confirmed result, as on macOS;
// - models.dev (https://models.dev/api.json): fetched at most once a day, cached in
//   %LOCALAPPDATA%\AgentSignalBar\Cache\models-dev.json, for models the bundled tables lack;
// - exchange rates (https://open.er-api.com/v6/latest/USD, CostCurrencyStore): only while a
//   currency other than USD is selected, refreshed when the feed says the next update is due.
// Both requests are anonymous GETs: no account, token history or path leaves the machine.
#pragma once

#include "UsageScanner.h"

#include <QHash>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <memory>

class QNetworkAccessManager;

class UsageService : public QObject {
    Q_OBJECT
public:
    explicit UsageService(QObject *parent = nullptr);
    ~UsageService() override;

    // `network`: allow the two price feeds (off for capture runs). `claudeRoots` runs before every
    // scan, on the scanning thread.
    void start(const QStringList &codexRoots, std::function<QStringList()> claudeRoots, const QString &cacheDir,
               bool network);
    void setCodexRoots(const QStringList &roots);
    void setPaused(bool paused);
    void setLowPower(bool lowPower) { m_lowPower = lowPower; }
    void setCurrency(const QString &code);
    // New agent events: the next scan comes on the short cadence.
    void noteActivity() { m_activity = true; }
    void requestScan();

    const asb::usage::Report &codex() const { return m_codex; }
    const asb::usage::Report &claude() const { return m_claude; }
    bool scanning() const { return m_scanning; }
    bool hasResult() const { return m_completedAtMs > 0; }
    qint64 completedAtMs() const { return m_completedAtMs; }
    bool hasCatalog() const { return m_catalog != nullptr; }
    // USD -> `code`; {1, "USD"} without a valid rate.
    std::pair<double, QString> rate(const QString &code) const;
    qint64 ratesUpdatedAtMs() const { return m_ratesUpdatedAtMs; }

    // For tests: CurrencyRateSnapshot.decode.
    static bool parseRates(const QByteArray &json, qint64 nowMs, QHash<QString, double> *rates, qint64 *updatedAtMs,
                           qint64 *nextUpdateAtMs);

signals:
    void changed();

private:
    void tick();
    void startScan();
    void loadCatalog();
    void fetchCatalog();
    void loadRates();
    void fetchRates();

    std::shared_ptr<asb::usage::CodexScanner> m_codexScanner;
    std::shared_ptr<asb::usage::ClaudeScanner> m_claudeScanner;
    std::shared_ptr<const asb::usage::ModelsDevCatalog> m_catalog;
    asb::usage::Report m_codex;
    asb::usage::Report m_claude;
    QTimer m_timer;
    QNetworkAccessManager *m_network = nullptr;
    QString m_cacheDir;
    QString m_currency = QStringLiteral("USD");
    QHash<QString, double> m_rates;
    qint64 m_ratesUpdatedAtMs = 0;
    qint64 m_ratesNextUpdateMs = 0;
    qint64 m_lastRatesAttemptMs = 0;
    qint64 m_lastCatalogAttemptMs = 0;
    qint64 m_catalogFetchedAtMs = 0;
    qint64 m_lastScanMs = 0;
    qint64 m_completedAtMs = 0;
    bool m_started = false;
    bool m_scanning = false;
    bool m_rescanPending = false;
    bool m_paused = false;
    bool m_lowPower = false;
    bool m_activity = false;
};
