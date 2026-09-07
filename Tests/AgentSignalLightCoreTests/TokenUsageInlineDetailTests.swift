import AppKit
import SwiftUI
import XCTest
@testable import AgentSignalLight

final class TokenUsageInlineDetailTests: XCTestCase {
    @MainActor
    func testInlineDetailKeepsBreathingRoomAndFitsOnlyCurrentContent() {
        _ = NSApplication.shared
        func size(rows: Int) -> NSSize {
            NSHostingView(rootView: VStack(spacing: 8) {
                Color.blue.frame(height: 48)
                TokenUsageInlineDetail {
                    if rows == 0 {
                        Text("Hover for details").frame(height: 16)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(0..<rows, id: \.self) { _ in
                                Text("Fixture model usage").frame(height: 24)
                            }
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }.frame(width: 480)).fittingSize
        }
        let idle = size(rows: 0)
        let short = size(rows: 1)
        let long = size(rows: 8)
        XCTAssertEqual(idle.width, 480, accuracy: 1)
        XCTAssertEqual(idle.height, 152, accuracy: 1, "A small inline area remains even without hovered details")
        XCTAssertEqual(short, idle)
        XCTAssertGreaterThan(long.height, short.height, "Visible details must expand the inline area rather than overlay other content")
        XCTAssertEqual(long.height, 316, accuracy: 1)
        XCTAssertEqual(size(rows: 0), idle, "Leaving the chart must release the extra detail space")
    }
}
