import Foundation
import XCTest
@testable import AgentSignalLight
import AgentSignalLightCore

final class SessionIdentityTests: XCTestCase {
    func testPayloadOwnIDWinsOverParentAndRootAliases() {
        assertSessionID(
            #"{"type":"session_meta","id":"root-id","session_id":"root-alias","sessionId":"root-camel","payload":{"id":"child-id","session_id":"parent-id","sessionId":"parent-camel","forked_from_id":"parent-id"}}"#,
            equals: "child-id"
        )
    }

    func testSeparateChildrenWithSameParentKeepTheirOwnIDs() {
        for childID in ["child-one", "child-two"] {
            assertSessionID(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(childID)\",\"session_id\":\"shared-parent\"}}",
                equals: childID
            )
        }
    }

    func testRootOwnIDWinsOverRootAliases() {
        assertSessionID(
            #"{"type":"session_meta","session_id":"root-parent","sessionId":"root-camel","id":"own-root-id"}"#,
            equals: "own-root-id"
        )
    }

    func testPayloadLegacyAliasKeepsPrecedenceOverRootIdentity() {
        assertSessionID(
            #"{"type":"session_meta","id":"root-id","payload":{"session_id":"payload-alias","sessionId":"payload-camel"}}"#,
            equals: "payload-alias"
        )
    }

    func testLegacyAliasesRemainSupportedAtBothLevels() {
        let fixtures = [
            #"{"type":"session_meta","payload":{"session_id":"legacy-id"}}"#,
            #"{"type":"session_meta","payload":{"sessionId":"legacy-id"}}"#,
            #"{"type":"session_meta","session_id":"legacy-id"}"#,
            #"{"type":"session_meta","sessionId":"legacy-id"}"#,
        ]
        for line in fixtures {
            assertSessionID(line, equals: "legacy-id")
        }
    }

    func testBlankPayloadIDFallsBackToTrimmedLegacyAlias() {
        assertSessionID(
            #"{"type":"session_meta","payload":{"id":" \t\n ","session_id":"  legacy-id\r\n","sessionId":"other-id"}}"#,
            equals: "legacy-id"
        )
    }

    func testBlankPayloadIdentifiersFallBackToTrimmedRootID() {
        assertSessionID(
            #"{"type":"session_meta","id":" \troot-id\n","session_id":"other-id","payload":{"id":"\u00a0","session_id":" ","sessionId":"\n\t"}}"#,
            equals: "root-id"
        )
    }

    func testBlankRootIDFallsBackThroughLegacyAliases() {
        assertSessionID(
            #"{"type":"session_meta","id":"\t","session_id":"\n","sessionId":" legacy-id "}"#,
            equals: "legacy-id"
        )
    }

    func testAllBlankIdentifiersAreAbsent() {
        assertSessionID(
            #"{"type":"session_meta","id":" ","session_id":"\t","sessionId":"\n","payload":{"id":"","session_id":"\r","sessionId":"\u00a0"}}"#,
            equals: nil
        )
    }

    func testNestedUnrelatedIdentityIsIgnored() {
        assertSessionID(
            #"{"type":"session_meta","context":{"id":"irrelevant-root"},"payload":{"source":{"id":"irrelevant-source","session_id":"irrelevant-parent"},"session_id":"actual-id"}}"#,
            equals: "actual-id"
        )
        assertSessionID(
            #"{"type":"session_meta","payload":{"source":{"id":"irrelevant-id"}}}"#,
            equals: nil
        )
    }

    func testNonStringIdentityFallsBackToStringAlias() {
        assertSessionID(
            #"{"type":"session_meta","payload":{"id":123,"session_id":null,"sessionId":"legacy-id"}}"#,
            equals: "legacy-id"
        )
    }

    func testEscapedIdentityIsDecodedAndTrimmedConsistently() {
        assertSessionID(
            #"{"type":"session_meta","payload":{"id":"\u00a0child\u002Did\n","session_id":"parent-id"}}"#,
            equals: "child-id"
        )
    }

    func testEscapedPayloadIdentityKeyWinsOverParentAlias() {
        assertSessionID(
            #"{"type":"session_meta","payload":{"i\u0064":"child-id","session_id":"parent-id"}}"#,
            equals: "child-id"
        )
    }

    func testEscapedRootIdentityAndContainerKeysAreDecodedConsistently() {
        assertSessionID(
            #"{"ty\u0070e":"session_meta","i\u0064":"root-id","session_id":"root-parent","pa\u0079load":{"source":{"i\u0064":"unrelated"}}}"#,
            equals: "root-id"
        )
    }

    private func assertSessionID(
        _ line: String,
        equals expected: String?,
        file: StaticString = #filePath,
        line lineNumber: UInt = #line
    ) {
        let coreID = CodexDesktopSessionParser.sessionID(fromSessionMetaLine: line)
        XCTAssertEqual(coreID, expected, file: file, line: lineNumber)
        guard case let .sessionMeta(metadata) = CodexTokenActivityFastParser.parseLine(Data(line.utf8)) else {
            XCTFail("Expected session metadata", file: file, line: lineNumber)
            return
        }
        XCTAssertEqual(metadata.sessionID, expected, file: file, line: lineNumber)
        XCTAssertEqual(metadata.sessionID, coreID, file: file, line: lineNumber)
    }
}
