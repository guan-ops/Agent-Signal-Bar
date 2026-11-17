import XCTest
@testable import AgentSignalLight

final class DebugLaunchOptionsTests: XCTestCase {
    func testHealthFileComesFromArgumentThenEnvironment() {
        let argument = "--debug-window-health", key = "AGENT_SIGNAL_LIGHT_DEBUG_WINDOW_HEALTH_FILE"
        XCTAssertEqual(
            DebugLaunchOptions.healthFileURL(argument: argument, environmentKey: key,
                                             arguments: ["app", argument, "/private/tmp/fixture/health.json"],
                                             environment: [key: "/private/tmp/fixture/env.json"])?.path,
            "/private/tmp/fixture/health.json"
        )
        XCTAssertEqual(
            DebugLaunchOptions.healthFileURL(argument: argument, environmentKey: key, arguments: ["app"],
                                             environment: [key: "/private/tmp/fixture/env.json"])?.path,
            "/private/tmp/fixture/env.json"
        )
        XCTAssertNil(DebugLaunchOptions.healthFileURL(argument: argument, environmentKey: key,
                                                      arguments: ["app", argument], environment: [key: "  "]),
                     "A flag without a path, or a blank variable, writes nothing")
    }
}
