import Darwin
import Foundation

enum BoundedProcessTermination {
    /// Bound both waits: a child that ignores SIGTERM must not prevent the
    /// caller from finishing its timeout/error handling.
    static func terminate(_ process: Process, gracePeriod: TimeInterval = 0.5) {
        guard process.isRunning else { return }
        process.terminate()
        waitForExit(process, duration: gracePeriod)
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        waitForExit(process, duration: 1)
    }

    private static func waitForExit(_ process: Process, duration: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, duration)
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
