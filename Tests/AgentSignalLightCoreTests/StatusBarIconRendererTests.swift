import AppKit
import Foundation
import XCTest
@testable import AgentSignalLightUI
@testable import AgentSignalLightCore

@MainActor
final class StatusBarIconRendererTests: XCTestCase {
    
    func testMacOSStatusBarBreathingChangesRenderedActiveArea() throws {
        let breathing = SignalEffectCustomization(activeEffect: .greenBreathing)
        for layout in TrafficSignalLayout.allCases {
            let low = try renderedPixels(signal: .working, tick: 0, layout: layout, style: .macOS, customization: breathing)
            let mid = try renderedPixels(signal: .working, tick: 2, layout: layout, style: .macOS, customization: breathing)
            let nearHigh = try renderedPixels(signal: .working, tick: 4, layout: layout, style: .macOS, customization: breathing)
            let high = try renderedPixels(signal: .working, tick: 5, layout: layout, style: .macOS, customization: breathing)

            let expectedSize = layout == .horizontal
                ? CGSize(width: 27, height: 18)
                : CGSize(width: 10, height: 18)
            let lowStrength = low.greenSignalStrength
            let midStrength = mid.greenSignalStrength
            let nearHighStrength = nearHigh.greenSignalStrength
            let highStrength = high.greenSignalStrength

            XCTAssert(low.imageSize == expectedSize)
            XCTAssert(lowStrength > 0)
            XCTAssert(midStrength > lowStrength)
            XCTAssert(nearHighStrength > midStrength)
            XCTAssert(highStrength > nearHighStrength)
            XCTAssert(highStrength >= lowStrength * 1.8)
        }
    }

    
    func testMacOSStatusBarIconKeepsWhiteOuterRingsAndTransparentCanvas() throws {
        let pixels = try renderedPixels(signal: .idle, tick: 0, layout: .vertical, style: .macOS)
        let totalPixels = pixels.width * pixels.height

        XCTAssert(pixels.imageSize == CGSize(width: 10, height: 18))
        XCTAssert(pixels.count(where: \.isWhiteRingPixel) >= 6)
        XCTAssert(pixels.count(where: \.isGreenLampPixel) >= 8)
        XCTAssert(pixels.count(where: \.isTransparent) > totalPixels / 3)
    }

    
    func testMacOSHorizontalStatusBarCanUseTrafficLightSizingWithoutTrafficLightHousing() throws {
        let macOS = try renderedPixels(
            signal: .idle,
            tick: 0,
            layout: .horizontal,
            style: .macOS,
            macOSHorizontalUsesTrafficLightSize: true
        )
        let trafficLight = try renderedPixels(
            signal: .idle,
            tick: 0,
            layout: .horizontal,
            style: .trafficLight
        )
        let verticalMacOS = try renderedPixels(
            signal: .idle,
            tick: 0,
            layout: .vertical,
            style: .macOS,
            macOSHorizontalUsesTrafficLightSize: true
        )

        XCTAssert(macOS.imageSize == trafficLight.imageSize)
        XCTAssert(verticalMacOS.imageSize == CGSize(width: 10, height: 18))
        XCTAssert(
            StatusBarIconRenderer.statusItemLength(
                layout: .horizontal,
                style: .macOS,
                macOSHorizontalUsesTrafficLightSize: true
            ) == StatusBarIconRenderer.statusItemLength(layout: .horizontal, style: .trafficLight)
        )
        XCTAssert(macOS.count(where: \.isDarkHousingPixel) == 0)
        XCTAssert(macOS.count(where: \.isWhiteRingPixel) >= 8)
        XCTAssert(macOS.count(where: \.isGreenLampPixel) >= 8)
    }

    
    func testTrafficLightVerticalStatusBarCanUseCompactLargeSizingWithTrafficLightHousing() throws {
        let trafficLight = try renderedPixels(
            signal: .idle,
            tick: 0,
            layout: .vertical,
            style: .trafficLight,
            trafficLightVerticalUsesMacOSSize: true
        )
        let macOS = try renderedPixels(signal: .idle, tick: 0, layout: .vertical, style: .macOS)
        let defaultTrafficLight = try renderedPixels(signal: .idle, tick: 0, layout: .vertical, style: .trafficLight)
        let horizontalTrafficLight = try renderedPixels(
            signal: .idle,
            tick: 0,
            layout: .horizontal,
            style: .trafficLight,
            trafficLightVerticalUsesMacOSSize: true
        )

        XCTAssert(trafficLight.imageSize == CGSize(width: 16, height: 24))
        XCTAssert(macOS.imageSize == CGSize(width: 10, height: 18))
        XCTAssert(defaultTrafficLight.imageSize == CGSize(width: 14, height: 22))
        XCTAssert(horizontalTrafficLight.imageSize == CGSize(width: 40, height: 20))
        XCTAssert(
            StatusBarIconRenderer.statusItemLength(
                layout: .vertical,
                style: .trafficLight,
                trafficLightVerticalUsesMacOSSize: true
            ) == 16
        )
        XCTAssert(trafficLight.count(where: \.isDarkHousingPixel) > macOS.count(where: \.isDarkHousingPixel))
        XCTAssert(trafficLight.count(where: \.isGreenLampPixel) > macOS.count(where: \.isGreenLampPixel))
        XCTAssert(trafficLight.count(where: \.isGreenLampPixel) >= 16)

        let metrics = SignalIconGeometry.metrics(
            layout: .vertical,
            style: .trafficLight,
            trafficLightVerticalUsesMacOSSize: true
        )
        XCTAssert(metrics.lampDiameter == 6)
        XCTAssert(metrics.lampSpacing == 1)
        XCTAssert(metrics.lampStep == 7)
        XCTAssert(metrics.verticalLampSpan == 20)

        let rects = StatusBarIconRenderer.lampRects(
            in: NSSize(width: metrics.iconSize.width, height: metrics.iconSize.height),
            layout: .vertical,
            metrics: metrics
        )
        let red = try XCTUnwrap(rects.first { $0.0 == .red }?.1)
        let yellow = try XCTUnwrap(rects.first { $0.0 == .yellow }?.1)
        let green = try XCTUnwrap(rects.first { $0.0 == .green }?.1)
        let topGap = red.minY - yellow.maxY
        let bottomGap = yellow.minY - green.maxY
        let redCenterGap = red.midY - yellow.midY
        let greenCenterGap = yellow.midY - green.midY
        let topInset = metrics.iconSize.height - red.maxY
        let bottomInset = green.minY
        let housingInset: CGFloat = 1
        XCTAssert(topGap == bottomGap)
        XCTAssert(topGap == metrics.lampSpacing)
        XCTAssert(redCenterGap == greenCenterGap)
        XCTAssert(redCenterGap == metrics.lampStep)
        XCTAssert(topInset == bottomInset)
        XCTAssert(topInset - housingInset == metrics.lampSpacing)
        XCTAssert(bottomInset - housingInset == metrics.lampSpacing)
    }

    
    func testTrafficLightStatusBarIconKeepsOpaqueHousing() throws {
        let pixels = try renderedPixels(signal: .working, tick: 0, layout: .vertical, style: .trafficLight)

        XCTAssert(pixels.imageSize == CGSize(width: 14, height: 22))
        XCTAssert(pixels.count(where: \.isDarkHousingPixel) >= 40)
        XCTAssert(pixels.count(where: \.isGreenLampPixel) >= 8)
    }

    
    func testActiveStatusBarRenderingNeverShowsWarningColors() throws {
        for style in TrafficSignalStyle.allCases {
            for layout in TrafficSignalLayout.allCases {
                let pixels = try renderedPixels(signal: .working, tick: 0, layout: layout, style: style)

                XCTAssert(pixels.count(where: \.isGreenLampPixel) >= 8)
                XCTAssert(pixels.count(where: \.isYellowLampPixel) == 0)
                XCTAssert(pixels.count(where: \.isRedLampPixel) == 0)
            }
        }
    }

    
    func testWarningStatusBarRenderingUsesOnlyItsWarningColor() throws {
        for style in TrafficSignalStyle.allCases {
            for layout in TrafficSignalLayout.allCases {
                let attention = try renderedPixels(signal: .attention, tick: 2, layout: layout, style: style)
                XCTAssert(attention.count(where: \.isYellowLampPixel) >= minimumVisibleLampPixels)
                XCTAssert(attention.count(where: \.isRedLampPixel) == 0)
                XCTAssert(attention.count(where: \.isGreenLampPixel) == 0)

                let permission = try renderedPixels(signal: .permission, tick: 2, layout: layout, style: style)
                XCTAssert(permission.count(where: \.isRedLampPixel) >= minimumVisibleLampPixels)
                XCTAssert(permission.count(where: \.isYellowLampPixel) == 0)
                XCTAssert(permission.count(where: \.isGreenLampPixel) == 0)
            }
        }
    }

    
    func testStatusBarRendererMatchesLampLanguageAcrossStylesAndLayouts() throws {
        let cases: [(signal: AgentSignal, tick: Int, expected: ExpectedLampColor)] = [
            (.idle, 0, .green),
            (.working, 0, .green),
            (.done, 0, .green),
            (.attention, 2, .yellow),
            (.permission, 2, .red),
            (.blocked, 0, .red),
            (.stale, 2, .yellow),
            (.off, 0, .none)
        ]

        for style in TrafficSignalStyle.allCases {
            for layout in TrafficSignalLayout.allCases {
                for item in cases {
                    let pixels = try renderedPixels(signal: item.signal, tick: item.tick, layout: layout, style: style)
                    try expectLampColor(item.expected, in: pixels)
                }
            }
        }
    }

    @MainActor
    private func renderedPixels(
        signal: AgentSignal,
        tick: Int,
        layout: TrafficSignalLayout,
        style: TrafficSignalStyle,
        macOSHorizontalUsesTrafficLightSize: Bool = false,
        trafficLightVerticalUsesMacOSSize: Bool = false,
        customization: SignalEffectCustomization = .default
    ) throws -> PixelBuffer {
        let image = StatusBarIconRenderer.image(
            snapshot: SignalSnapshot(
                aggregate: signal,
                sessions: [],
                stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json")
            ),
            tick: tick,
            layout: layout,
            style: style,
            macOSBreathingStrength: .maximum,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            trafficLightVerticalUsesMacOSSize: trafficLightVerticalUsesMacOSSize,
            allLightsOn: false,
            effectCustomization: customization
        )

        return try PixelBuffer(image: image)
    }

    private func expectLampColor(_ expected: ExpectedLampColor, in pixels: PixelBuffer) throws {
        let red = pixels.count(where: \.isRedLampPixel)
        let yellow = pixels.count(where: \.isYellowLampPixel)
        let green = pixels.count(where: \.isGreenLampPixel)

        switch expected {
        case .red:
            XCTAssert(red >= minimumVisibleLampPixels)
            XCTAssert(yellow == 0)
            XCTAssert(green == 0)
        case .yellow:
            XCTAssert(yellow >= minimumVisibleLampPixels)
            XCTAssert(red == 0)
            XCTAssert(green == 0)
        case .green:
            XCTAssert(green >= minimumVisibleLampPixels)
            XCTAssert(red == 0)
            XCTAssert(yellow == 0)
        case .none:
            XCTAssert(red == 0)
            XCTAssert(yellow == 0)
            XCTAssert(green == 0)
        }
    }
}

private let minimumVisibleLampPixels = 4

private enum ExpectedLampColor {
    case red
    case yellow
    case green
    case none
}

private struct PixelBuffer {
    let imageSize: CGSize
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(image: NSImage) throws {
        imageSize = image.size
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw PixelBufferError.missingCGImage
        }

        width = cgImage.width
        height = cgImage.height
        var data = Array(repeating: UInt8(0), count: width * height * 4)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PixelBufferError.missingContext
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    func count(where predicate: (Pixel) -> Bool) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, index in
            let pixel = Pixel(
                red: bytes[index],
                green: bytes[index + 1],
                blue: bytes[index + 2],
                alpha: bytes[index + 3]
            )
            return predicate(pixel) ? count + 1 : count
        }
    }

    var greenSignalStrength: Double {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { strength, index in
            let red = Double(bytes[index])
            let green = Double(bytes[index + 1])
            let blue = Double(bytes[index + 2])
            let alpha = Double(bytes[index + 3]) / 255
            let dominance = max(0, green - max(red, blue))
            return strength + dominance * alpha
        }
    }
}

private struct Pixel {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var isTransparent: Bool {
        alpha <= 12
    }

    var isGreenLampPixel: Bool {
        Int(alpha) > 90 && Int(green) > Int(red) + 45 && Int(green) > Int(blue) + 40
    }

    var isYellowLampPixel: Bool {
        let red = Int(red)
        let green = Int(green)
        let blue = Int(blue)
        return Int(alpha) > 90
            && red > 150
            && green > 110
            && green * 100 >= red * 65
            && blue < 110
    }

    var isRedLampPixel: Bool {
        let red = Int(red)
        let green = Int(green)
        let blue = Int(blue)
        return Int(alpha) > 90
            && red > 150
            && green * 100 < red * 55
            && red > blue + 45
    }

    var isWhiteRingPixel: Bool {
        alpha > 120 && red > 180 && green > 180 && blue > 180
    }

    var isDarkHousingPixel: Bool {
        alpha > 120 && red < 45 && green < 45 && blue < 45
    }
}

private enum PixelBufferError: Error {
    case missingCGImage
    case missingContext
}
