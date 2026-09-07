import Foundation

/// Detail totals cover confirmed Codex session files in the last 30 calendar days.
/// They exclude pending live observations and other providers (including Pi).
struct CodexUsageDetails: Equatable, Sendable {
    struct Session: Identifiable, Equatable, Sendable {
        let id: String
        let projectPath: String?
        let lastActivity: Date?
        let inputTokens: Int
        let cachedTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let costUSD: Double?
        let hasUnpricedUsage: Bool
        let models: [String]
    }

    struct Project: Identifiable, Equatable, Sendable {
        var id: String { path ?? "" }
        let path: String?
        let sessionCount: Int
        let totalTokens: Int
        let costUSD: Double?
        let hasUnpricedUsage: Bool
    }

    let sessions: [Session]
    let updatedAt: Date

    var projects: [Project] {
        Dictionary(grouping: sessions, by: { $0.projectPath ?? "" }).map { path, entries in
            let costs = entries.compactMap(\.costUSD)
            return Project(path: path.isEmpty ? nil : path, sessionCount: entries.count,
                           totalTokens: entries.reduce(0) { $0 + $1.totalTokens },
                           costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                           hasUnpricedUsage: entries.contains { $0.hasUnpricedUsage })
        }.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.id < $1.id
        }
    }

    static func build(cache: CostUsageCache, now: Date,
                      modelsDevCatalog: ModelsDevCatalog,
                      projectPath: (String, String?) -> String? = readProjectPath) -> Self {
        let start = Calendar.current.date(byAdding: .day, value: -29,
                                           to: Calendar.current.startOfDay(for: now))!
        let range = CostUsageScanner.CostUsageDayRange(since: start, until: now)
        let excluded = Set((cache.codexScanWarnings ?? []).map(\.sessionID))
        let owners = cache.files.filter { _, usage in
            usage.codexInventoryOnly != true && usage.codexNoncontributingDuplicate != true
                && usage.codexDuplicateQuarantined != true && usage.codexIdentityConflict != true
                && !excluded.contains(usage.sessionId ?? "")
        }
        let groups = Dictionary(grouping: owners.map { (path: $0.key, usage: $0.value) }) {
            $0.usage.sessionId ?? $0.path
        }
        let sessions = groups.compactMap { id, files -> Session? in
            // Never select an arbitrary copy when ownership is ambiguous.
            guard files.count == 1, let file = files.first else { return nil }
            let days = file.usage.days.filter {
                CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0.key,
                                                             since: range.sinceKey, until: range.untilKey)
            }
            guard !days.isEmpty else { return nil }
            var subset = CostUsageCache()
            subset.files = [file.path: file.usage]
            subset.days = days
            let report = CostUsageScanner.buildCodexReportFromCache(cache: subset, range: range,
                                                                    modelsDevCatalog: modelsDevCatalog)
            guard let total = report.summary?.totalTokens, total > 0 else { return nil }
            let cached = days.values.reduce(0) { sum, models in
                sum + models.values.reduce(0) { $0 + ($1.count > 1 ? $1[1] : 0) }
            }
            let modelRows = report.data.flatMap { $0.modelBreakdowns ?? [] }
            let timestamps = (file.usage.tokenEventWatermarks ?? []).compactMap(\.eventTimestamp)
                + [file.usage.lastTokenEventTimestamp].compactMap { $0 }
            let latest = timestamps.filter { $0 >= start && $0 <= now }.max()
            return Session(id: id, projectPath: projectPath(file.path, file.usage.sessionId),
                           lastActivity: latest, inputTokens: report.summary?.totalInputTokens ?? 0,
                           cachedTokens: cached, outputTokens: report.summary?.totalOutputTokens ?? 0,
                           totalTokens: total, costUSD: report.summary?.totalCostUSD,
                           hasUnpricedUsage: modelRows.contains { ($0.totalTokens ?? 0) > 0 && $0.costUSD == nil },
                           models: Array(Set(modelRows.map(\.modelName))).sorted())
        }.sorted {
            if $0.lastActivity != $1.lastActivity { return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            return $0.id < $1.id
        }
        return Self(sessions: sessions, updatedAt: now)
    }

    /// Read only a bounded session header, never prompts or a second full log scan.
    /// An unreadable/mismatched header leaves the project unknown without losing usage.
    static func readProjectPath(_ path: String, _ sessionID: String?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        var header = Data()
        while header.count < 1_048_576 {
            guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 10) {
                header.append(chunk[..<newline])
                break
            }
            header.append(chunk)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              sessionID == nil || payload["id"] as? String == sessionID,
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else { return nil }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }
}
