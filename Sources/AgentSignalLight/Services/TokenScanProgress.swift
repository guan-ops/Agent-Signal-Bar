import Foundation

struct TokenScanProgress: Equatable, Sendable {
    enum Phase: Sendable { case discovering, scanning, validating, complete }
    let phase: Phase
    var completedFiles: Int = 0
    var totalFiles: Int = 0

    var fraction: Double? {
        if phase == .complete { return 1 }
        guard totalFiles > 0 else { return nil }
        return min(1, max(0, Double(completedFiles) / Double(totalFiles)))
    }
}

/// File callbacks can be frequent on a warm cache. Keep the main queue bounded.
final class TokenScanProgressDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var last = TokenScanProgress(phase: .discovering)
    private var lastTime = -Double.infinity
    private let receive: @Sendable (TokenScanProgress) -> Void
    init(receive: @escaping @Sendable (TokenScanProgress) -> Void) { self.receive = receive }
    func send(_ value: TokenScanProgress) {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard value.phase != last.phase || value.completedFiles == value.totalFiles
                || now - lastTime >= 0.2 else { return }
        last = value
        lastTime = now
        receive(value)
    }
}
