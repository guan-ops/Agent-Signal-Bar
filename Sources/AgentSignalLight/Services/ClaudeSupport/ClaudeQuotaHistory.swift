import Foundation
import UserNotifications

struct ClaudeQuotaSample: Codable, Equatable, Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let usedPercent: Double
    let resetsAt: Date?
}

struct ClaudeQuotaForecast: Equatable, Sendable {
    let exhaustionAt: Date
    let resetsAt: Date
    let sampleCount: Int
    var willLastToReset: Bool { exhaustionAt >= resetsAt }
}

struct ClaudeQuotaNotice: Equatable, Sendable {
    enum Kind: String, Sendable { case low, restored, reset, predicted }
    let kind: Kind
    let windowID: String
    let title: String
    let remainingPercent: Double
    let owner: String
    let date: Date
}

/// Account/source-scoped observed quota history. Never stores credentials, emails, grant IDs or conversations.
/// Threshold crossings, confirmed reset notices and predictive warnings follow CodexBar's presentation contract.
@MainActor
final class ClaudeQuotaHistory {
    struct Preferences {
        var low = false
        var reset = false
        var predicted = false
        var threshold = 20
    }
    private struct Document: Codable {
        var version = 1
        var series: [String: [String: [ClaudeQuotaSample]]] = [:]
        var aliases: [String: String] = [:]
        var predictedCycles: [String: Date] = [:]
        var emitted: [String: Date]? = nil
    }
    private var document = Document()
    private let fileURL: URL?
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 8_388_608,
           let decoded = try? JSONDecoder().decode(Document.self, from: data), decoded.version == 1 {
            document = decoded
        }
    }
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSignalLight/claude-quota-history.json")
    }
    func samples(snapshot: ClaudeUsageSnapshot, windowID: String) -> [ClaudeQuotaSample] {
        document.series[owner(snapshot)]?[windowID] ?? []
    }
    func clear() { document = Document(); persist() }

    func record(_ snapshot: ClaudeUsageSnapshot, preferences: Preferences, now: Date = Date()) -> [ClaudeQuotaNotice] {
        guard snapshot.isFresh(at: now), !snapshot.credentialID.hasPrefix("cli-unverified-") else { return [] }
        let provisional = ClaudeValue.key(snapshot.source + "|" + snapshot.credentialID)
        if let verified = snapshot.accountKey {
            if let old = document.aliases[provisional], old != verified {
                // A conflicting owner never inherits the old bucket.
                document.series.removeValue(forKey: provisional)
            } else if let pending = document.series.removeValue(forKey: provisional), provisional != verified {
                for (window, rows) in pending {
                    let merged = (document.series[verified]?[window] ?? []) + rows.filter { $0.date < snapshot.updatedAt }
                    document.series[verified, default: [:]][window] = unique(merged)
                }
            }
            document.aliases[provisional] = verified
        }
        let key = owner(snapshot)
        var events: [ClaudeQuotaNotice] = []
        for window in snapshot.historyWindows where window.usedPercent.isFinite && (0...100).contains(window.usedPercent) {
            var rows = document.series[key]?[window.id] ?? []
            guard rows.last.map({ $0.date < snapshot.updatedAt }) ?? true else { continue }
            let previous = rows.last
            let sample = ClaudeQuotaSample(date: snapshot.updatedAt, usedPercent: window.usedPercent, resetsAt: window.resetsAt)
            let remaining = 100 - window.usedPercent
            func notice(_ kind: ClaudeQuotaNotice.Kind) -> ClaudeQuotaNotice {
                .init(kind: kind, windowID: window.id, title: window.title, remainingPercent: remaining, owner: key, date: snapshot.updatedAt)
            }
            if let previous {
                let recovered = previous.usedPercent >= 100 && window.usedPercent < 100
                let reset = previous.resetsAt.flatMap { old in window.resetsAt.map { $0 > old.addingTimeInterval(300) } } == true
                    && window.usedPercent <= previous.usedPercent - 5
                if preferences.reset && (recovered || reset) { events.append(notice(recovered ? .restored : .reset)) }
                let thresholds = Set([max(1, min(90, preferences.threshold)), 10]).sorted()
                if preferences.low, window.resetsAt.map({ $0 > now }) ?? true,
                   thresholds.contains(where: { 100 - previous.usedPercent > Double($0) && remaining <= Double($0) }) {
                    events.append(notice(.low))
                }
            }
            if let last = rows.last, floor(last.date.timeIntervalSince1970 / 300) == floor(sample.date.timeIntervalSince1970 / 300) { rows.removeLast() }
            rows.append(sample)
            rows = Array(rows.filter { $0.date >= now.addingTimeInterval(-56 * 86400) }.suffix(17520))
            document.series[key, default: [:]][window.id] = rows
            let cycleKey = key + ":" + window.id
            if let forecast = Self.forecast(rows, now: now) {
                if forecast.willLastToReset { document.predictedCycles.removeValue(forKey: cycleKey) }
                else if preferences.predicted, document.predictedCycles[cycleKey].map({ abs($0.timeIntervalSince(forecast.resetsAt)) > 300 }) ?? true {
                    document.predictedCycles[cycleKey] = forecast.resetsAt
                    events.append(notice(.predicted))
                }
            }
        }
        if document.series.count > 32 {
            let keep = Set(document.series.keys.sorted {
                latestDate(document.series[$0]) > latestDate(document.series[$1])
            }.prefix(32))
            document.series = document.series.filter { keep.contains($0.key) }
        }
        if document.aliases.count > 128 {
            let valid = document.aliases.filter { document.series[$0.value] != nil }.sorted { $0.key < $1.key }
            document.aliases = Dictionary(uniqueKeysWithValues: valid.suffix(128).map { ($0.key, $0.value) })
        }
        let dates = document.series.values.flatMap { $0.values.flatMap { $0.map(\.date) } }.sorted(by: >)
        if dates.count > 40_000 {
            let cutoff = dates[39_999]
            for key in document.series.keys {
                document.series[key] = document.series[key]?.mapValues { $0.filter { $0.date >= cutoff } }
            }
        }
        document.predictedCycles = document.predictedCycles.filter { now.timeIntervalSince($0.value) < 56 * 86400 }
        var emitted = document.emitted ?? [:]
        events = events.filter { event in
            let id = ClaudeValue.key("\(snapshot.source)|\(snapshot.credentialID)|\(event.windowID)|\(event.kind)|\(event.date.timeIntervalSince1970)")
            guard emitted[id] == nil else { return false }
            emitted[id] = now
            return true
        }
        document.emitted = emitted.filter { now.timeIntervalSince($0.value) < 86400 }
        persist()
        return events
    }

    func forecast(snapshot: ClaudeUsageSnapshot, windowID: String, now: Date = Date()) -> ClaudeQuotaForecast? {
        Self.forecast(samples(snapshot: snapshot, windowID: windowID), now: now)
    }
    nonisolated static func forecast(_ rows: [ClaudeQuotaSample], now: Date) -> ClaudeQuotaForecast? {
        guard let last = rows.last, now.timeIntervalSince(last.date) < 900, last.usedPercent > 0, last.usedPercent < 100,
              let reset = last.resetsAt, reset > now else { return nil }
        let samples = Array(rows.filter { $0.resetsAt.map { abs($0.timeIntervalSince(reset)) <= 300 } == true && $0.date >= last.date.addingTimeInterval(-6 * 3600) }.suffix(24))
        guard samples.count >= 3, let first = samples.first,
              last.date.timeIntervalSince(first.date) >= 300, last.usedPercent - first.usedPercent >= 1 else { return nil }
        for pair in zip(samples, samples.dropFirst()) where pair.1.usedPercent < pair.0.usedPercent { return nil }
        let x = samples.map { $0.date.timeIntervalSince(first.date) }, y = samples.map(\.usedPercent)
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        let variance = x.reduce(0) { $0 + pow($1 - mx, 2) }
        guard variance > 0 else { return nil }
        let slope = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / variance
        guard slope.isFinite, slope > 0 else { return nil }
        let seconds = (100 - last.usedPercent) / slope
        guard seconds.isFinite, seconds > 0, seconds < 90 * 86400 else { return nil }
        return .init(exhaustionAt: last.date.addingTimeInterval(seconds), resetsAt: reset, sampleCount: samples.count)
    }
    private func owner(_ snapshot: ClaudeUsageSnapshot) -> String {
        let provisional = ClaudeValue.key(snapshot.source + "|" + snapshot.credentialID)
        return snapshot.accountKey ?? document.aliases[provisional] ?? provisional
    }
    private func unique(_ rows: [ClaudeQuotaSample]) -> [ClaudeQuotaSample] {
        var byDate: [Date: ClaudeQuotaSample] = [:]
        for row in rows { byDate[row.date] = row }
        return byDate.values.sorted { $0.date < $1.date }
    }
    private func latestDate(_ windows: [String: [ClaudeQuotaSample]]?) -> Date {
        windows?.values.compactMap { $0.last?.date }.max() ?? .distantPast
    }
    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(document) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum ClaudeQuotaNotifications {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func deliver(_ event: ClaudeQuotaNotice, english: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            let parts = event.title.components(separatedBy: " / ")
            let window = parts.count == 2 ? parts[english ? 1 : 0] : event.title
            content.title = "Claude · " + window
            switch event.kind {
            case .low: content.body = english ? "Quota remaining: \(Int(event.remainingPercent))%." : "剩余额度 \(Int(event.remainingPercent))%。"
            case .restored, .reset: content.body = english ? "Quota has recovered. You can continue working." : "已确认额度恢复，可以继续使用。"
            case .predicted: content.body = english ? "At the observed pace, quota may run out before the reset." : "按已观察到的消耗速度，额度可能在重置前用尽。"
            }
            content.sound = .default
            let id = ClaudeValue.key("\(event.owner)|\(event.windowID)|\(event.kind)|\(event.date.timeIntervalSince1970)")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "claude-quota-" + id, content: content, trigger: nil))
        }
    }
}
