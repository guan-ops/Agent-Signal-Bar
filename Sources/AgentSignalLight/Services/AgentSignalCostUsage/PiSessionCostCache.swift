import Foundation

enum PiSessionCostCacheIO {
    // v4 adds a strict scan-through cursor. v3 may have cached same-day
    // entries that occurred after the requested cutoff, so it must be rebuilt.
    private static let artifactVersion = 4

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("AgentSignalBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("pi-sessions-v\(Self.artifactVersion).json", isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil) -> PiSessionCostCache {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PiSessionCostCache.self, from: data),
              decoded.version == Self.artifactVersion,
              decoded.dayContext == CostUsageDayContext.current
        else {
            return PiSessionCostCache(version: Self.artifactVersion)
        }
        return decoded
    }

    static func save(cache: PiSessionCostCache, cacheRoot: URL? = nil) throws {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        let data = try JSONEncoder().encode(cache)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

struct PiSessionCostCache: Codable {
    var version: Int
    var dayContext: CostUsageDayContext? = .current
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var daysByProvider: [String: [String: [String: PiPackedUsage]]] = [:]
    var files: [String: PiSessionFileUsage] = [:]

    init(version: Int = 4) {
        self.version = version
    }
}

struct PiSessionFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var parsedBytes: Int64
    var lastModelContext: PiModelContext?
    var contributions: [String: [String: [String: PiPackedUsage]]]
}

struct PiModelContext: Codable, Equatable {
    var providerRawValue: String
    var modelName: String
}

struct PiPackedUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var costNanos: Int64 = 0
    var costSampleCount: Int = 0
    var usageSampleCount: Int?

    var isZero: Bool {
        self.inputTokens == 0
            && self.cacheReadTokens == 0
            && self.cacheWriteTokens == 0
            && self.outputTokens == 0
            && self.totalTokens == 0
            && self.costNanos == 0
            && self.costSampleCount == 0
            && (self.usageSampleCount ?? 0) == 0
    }
}
