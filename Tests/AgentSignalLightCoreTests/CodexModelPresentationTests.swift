import XCTest
@testable import AgentSignalLight

final class CodexModelPresentationTests: XCTestCase {
    func testCurrentModelsHaveDistinctColorsAndFollowPickerOrder() throws {
        let models = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
                      "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
        let presentations = models.map(CodexModelPresentation.forModel)
        XCTAssertEqual(Set(presentations.compactMap(\.colorRGB)).count, models.count)
        XCTAssertEqual(presentations.map(\.sortRank), presentations.map(\.sortRank).sorted())
        XCTAssertEqual(Set(presentations.map(\.sortRank)).count, models.count)
        for model in models {
            XCTAssertEqual(CodexModelPresentation.forModel("openai/\(model)-2026-09-22"),
                           CodexModelPresentation.forModel(model))
        }
    }

    func testNewModelsUseReadableNamesInChartAndSessionDetails() {
        XCTAssertEqual(CodexModelPresentation.forModel("gpt-6-sol").displayName, "GPT-6 Sol")
        XCTAssertEqual(CodexModelPresentation.forModel("gpt-6-luna").displayName, "GPT-6 Luna")
    }

    func testUnknownModelsCannotInheritKnownModelColorsBySubstring() {
        XCTAssertNil(CodexModelPresentation.forModel("custom-gpt-6-sol").colorRGB)
        XCTAssertNil(CodexModelPresentation.forModel("gpt-6-sol-unknown").colorRGB)
        XCTAssertEqual(CodexModelPresentation.forModel("gpt-5.4-mini").colorRGB,
                       CodexModelPresentation.forModel("gpt-5.4").colorRGB)
    }
}
