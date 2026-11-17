import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

final class CodexDesktopOriginatorTests: XCTestCase {
    func testDesktopOriginatorOverridesSharedVSCodeSource() throws {
        for originator in ["codex_work_desktop", "codex_desktop", "Codex Desktop"] {
            let line = String(data: try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["source": "vscode", "originator": originator]]), encoding: .utf8)!
            XCTAssertEqual(CodexDesktopSessionParser.agentName(fromSessionMetaLine: line), "codex-desktop")
        }
        XCTAssertEqual(CodexDesktopSessionParser.agentName(fromSessionMetaLine:
            #"{"type":"session_meta","payload":{"source":"vscode","originator":"codex_vscode"}}"#), "codex-vscode")
    }
    @MainActor
    func testCorrectedRuntimeHidesOldAliasButPreservesRealVSCodeSession() {
        let id = UUID().uuidString
        let now = Date()
        let stale = SessionStatus(sessionID: "codex-vscode:\(id)", signal: .working,
            updatedAt: now.addingTimeInterval(-1), agent: "codex-vscode", lastEvent: "DesktopMessage")
        let corrected = SessionStatus(sessionID: "codex-desktop:\(id)", signal: .working,
            updatedAt: now, agent: "codex-desktop", lastEvent: "DesktopMessage")
        let real = SessionStatus(sessionID: "codex-vscode:\(UUID())", signal: .working,
            updatedAt: now, agent: "codex-vscode", lastEvent: "DesktopMessage")
        XCTAssertEqual(Set(MenuBarStatusModel.removingSupersededCodexRuntimeAliases([stale, corrected, real]).map(\.sessionID)), [corrected.sessionID, real.sessionID])
    }
}
