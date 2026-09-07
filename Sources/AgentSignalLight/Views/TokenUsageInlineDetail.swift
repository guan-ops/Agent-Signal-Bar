import SwiftUI

/// Reserve a little breathing room, then grow only for the currently visible details.
struct TokenUsageInlineDetail<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
    }
}
