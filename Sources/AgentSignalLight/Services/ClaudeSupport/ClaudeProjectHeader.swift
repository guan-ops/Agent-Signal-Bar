import Foundation

enum ClaudeProjectHeader {
    /// Bounded metadata read; never decode the project directory name into a speculative path.
    static func read(_ path: String, _ sessionID: String?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536) else { return nil }
        for line in data.split(separator: 10) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  sessionID == nil || (object["sessionId"] as? String ?? object["session_id"] as? String) == sessionID,
                  let cwd = object["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else { continue }
            return URL(fileURLWithPath: cwd).standardizedFileURL.path
        }
        return nil
    }
}
