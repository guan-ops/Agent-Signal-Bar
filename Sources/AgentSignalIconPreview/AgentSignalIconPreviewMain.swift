import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
@main
struct AgentSignalIconPreview {
    static func main() throws {
        let outputURL = try parseOutputURL()
        let iconsURL = outputURL.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsURL, withIntermediateDirectories: true)

        let records = try renderIcons(to: iconsURL)
        try renderSheet(records: records, to: outputURL.appendingPathComponent("status-icon-preview.png"))
        try renderStatusBarDemo(to: outputURL.appendingPathComponent("status-bar-demo.gif"))
        try renderStatusBarStylePreviews(to: outputURL)
        try renderEffectGallery(language: .english, to: outputURL.appendingPathComponent("light-effects-en.gif"))
        try renderEffectGallery(language: .simplifiedChinese, to: outputURL.appendingPathComponent("light-effects-zh-CN.gif"))
        try writeManifest(records: records, to: outputURL.appendingPathComponent("manifest.json"))

        print("status icon preview: \(outputURL.path)")
        print("sheet: \(outputURL.appendingPathComponent("status-icon-preview.png").path)")
        print("status bar demo: \(outputURL.appendingPathComponent("status-bar-demo.gif").path)")
        print("status bar minimal dots: \(outputURL.appendingPathComponent("status-bar-minimal-dots.gif").path)")
        print("status bar classic lamp: \(outputURL.appendingPathComponent("status-bar-classic-lamp.gif").path)")
        print("status bar minimal dots vertical: \(outputURL.appendingPathComponent("status-bar-minimal-dots-vertical.gif").path)")
        print("status bar classic lamp vertical: \(outputURL.appendingPathComponent("status-bar-classic-lamp-vertical.gif").path)")
        print("light effects en: \(outputURL.appendingPathComponent("light-effects-en.gif").path)")
        print("light effects zh-CN: \(outputURL.appendingPathComponent("light-effects-zh-CN.gif").path)")
        print("manifest: \(outputURL.appendingPathComponent("manifest.json").path)")
    }

    private static func parseOutputURL() throws -> URL {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            return URL(fileURLWithPath: "dist/status-icon-preview", isDirectory: true)
        }

        if args.count == 1 {
            return URL(fileURLWithPath: args[0], isDirectory: true)
        }

        if args.count == 2, args[0] == "--output" {
            return URL(fileURLWithPath: args[1], isDirectory: true)
        }

        throw PreviewError.usage
    }

    private static func renderIcons(to iconsURL: URL) throws -> [PreviewRecord] {
        var records: [PreviewRecord] = []
        for style in TrafficSignalStyle.allCases {
            for layout in TrafficSignalLayout.allCases {
                for item in previewItems {
                    let snapshot = SignalSnapshot(
                        aggregate: item.signal,
                        sessions: [],
                        stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json")
                    )
                    let image = StatusBarIconRenderer.image(
                        snapshot: snapshot,
                        tick: item.tick,
                        layout: layout,
                        style: style,
                        macOSBreathingStrength: .maximum,
                        allLightsOn: item.allLightsOn
                    )
                    let filename = [
                        style.rawValue,
                        layout.rawValue,
                        item.identifier
                    ].joined(separator: "-") + ".png"
                    let fileURL = iconsURL.appendingPathComponent(filename)
                    try writePNG(image, to: fileURL)
                    records.append(
                        PreviewRecord(
                            style: style,
                            layout: layout,
                            item: item,
                            fileURL: fileURL,
                            imageSize: image.size
                        )
                    )
                }
            }
        }
        return records
    }

    private static func renderSheet(records: [PreviewRecord], to outputURL: URL) throws {
        let columns: [(TrafficSignalStyle, TrafficSignalLayout)] = TrafficSignalStyle.allCases.flatMap { style in
            TrafficSignalLayout.allCases.map { layout in (style, layout) }
        }
        let rowHeight: CGFloat = 88
        let labelWidth: CGFloat = 132
        let columnWidth: CGFloat = 178
        let headerHeight: CGFloat = 58
        let padding: CGFloat = 18
        let sheetSize = NSSize(
            width: labelWidth + CGFloat(columns.count) * columnWidth + padding * 2,
            height: headerHeight + CGFloat(previewItems.count) * rowHeight + padding * 2
        )
        let sheet = try makeBitmap(size: sheetSize, path: outputURL.path)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.14, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheetSize).fill()

        drawText(
            "Agent Signal Bar status bar preview",
            in: NSRect(x: padding, y: sheetSize.height - padding - 24, width: sheetSize.width - padding * 2, height: 22),
            font: .boldSystemFont(ofSize: 15),
            color: .white
        )

        for (columnIndex, column) in columns.enumerated() {
            let x = padding + labelWidth + CGFloat(columnIndex) * columnWidth
            let title = "\(column.0.displayName) / \(column.1.displayName)"
            drawText(
                title,
                in: NSRect(x: x, y: sheetSize.height - padding - 52, width: columnWidth - 12, height: 20),
                font: .systemFont(ofSize: 11, weight: .semibold),
                color: NSColor.white.withAlphaComponent(0.82)
            )
        }

        for (rowIndex, item) in previewItems.enumerated() {
            let rowY = sheetSize.height - padding - headerHeight - CGFloat(rowIndex + 1) * rowHeight
            let rowRect = NSRect(
                x: padding,
                y: rowY + 8,
                width: sheetSize.width - padding * 2,
                height: rowHeight - 12
            )
            NSColor.white.withAlphaComponent(rowIndex.isMultiple(of: 2) ? 0.035 : 0.018).setFill()
            NSBezierPath(roundedRect: rowRect, xRadius: 8, yRadius: 8).fill()

            drawText(
                item.label,
                in: NSRect(x: padding + 12, y: rowY + rowHeight / 2 - 2, width: labelWidth - 20, height: 18),
                font: .systemFont(ofSize: 12, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.88)
            )
            drawText(
                "tick \(item.tick)",
                in: NSRect(x: padding + 12, y: rowY + rowHeight / 2 - 22, width: labelWidth - 20, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.45)
            )

            for (columnIndex, column) in columns.enumerated() {
                guard let record = records.first(where: {
                    $0.style == column.0 && $0.layout == column.1 && $0.item.identifier == item.identifier
                }) else {
                    continue
                }

                let x = padding + labelWidth + CGFloat(columnIndex) * columnWidth
                let iconBackground = NSRect(x: x + 18, y: rowY + 22, width: columnWidth - 48, height: 34)
                NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.36, alpha: 1).setFill()
                NSBezierPath(roundedRect: iconBackground, xRadius: 7, yRadius: 7).fill()

                let image = try loadImage(record.fileURL)
                let scale: CGFloat = column.0 == .trafficLight ? 3 : 4
                let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                let drawRect = NSRect(
                    x: iconBackground.midX - drawSize.width / 2,
                    y: iconBackground.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
                NSGraphicsContext.current?.imageInterpolation = .none
                image.draw(in: drawRect)
            }
        }

        try writePNG(sheet, to: outputURL)
    }

    private static func renderStatusBarDemo(to outputURL: URL) throws {
        let demoSize = NSSize(width: 720, height: 300)
        let frameCount = 24
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw PreviewError.missingGIFRepresentation(outputURL.path)
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: 0.12
            ]
        ]

        for frameIndex in 0..<frameCount {
            let frame = try renderStatusBarDemoFrame(
                frameIndex: frameIndex,
                size: demoSize,
                path: outputURL.path
            )
            guard let image = frame.cgImage else {
                throw PreviewError.missingGIFRepresentation(outputURL.path)
            }
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        if !CGImageDestinationFinalize(destination) {
            throw PreviewError.missingGIFRepresentation(outputURL.path)
        }
    }

    private static func renderStatusBarStylePreviews(to outputURL: URL) throws {
        try renderStatusBarStylePreview(
            to: outputURL.appendingPathComponent("status-bar-minimal-dots.gif"),
            style: .macOS,
            layout: .horizontal,
            size: NSSize(width: 360, height: 180),
            iconOutputScale: 7,
            macOSHorizontalUsesTrafficLightSize: true
        )
        try renderStatusBarStylePreview(
            to: outputURL.appendingPathComponent("status-bar-classic-lamp.gif"),
            style: .trafficLight,
            layout: .horizontal,
            size: NSSize(width: 360, height: 180),
            iconOutputScale: 7
        )
        try renderStatusBarStylePreview(
            to: outputURL.appendingPathComponent("status-bar-minimal-dots-vertical.gif"),
            style: .macOS,
            layout: .vertical,
            size: NSSize(width: 360, height: 180),
            iconOutputScale: 9
        )
        try renderStatusBarStylePreview(
            to: outputURL.appendingPathComponent("status-bar-classic-lamp-vertical.gif"),
            style: .trafficLight,
            layout: .vertical,
            size: NSSize(width: 360, height: 180),
            iconOutputScale: 8
        )
    }

    private static func renderStatusBarStylePreview(
        to outputURL: URL,
        style: TrafficSignalStyle,
        layout: TrafficSignalLayout,
        size: NSSize,
        iconOutputScale: CGFloat,
        macOSHorizontalUsesTrafficLightSize: Bool = false
    ) throws {
        let frameCount = 12
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw PreviewError.missingGIFRepresentation(outputURL.path)
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: 0.14
            ]
        ]

        for frameIndex in 0..<frameCount {
            let frame = try renderStatusBarStylePreviewFrame(
                frameIndex: frameIndex,
                style: style,
                layout: layout,
                size: size,
                iconOutputScale: iconOutputScale,
                macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
                path: outputURL.path
            )
            guard let image = frame.cgImage else {
                throw PreviewError.missingGIFRepresentation(outputURL.path)
            }
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        if !CGImageDestinationFinalize(destination) {
            throw PreviewError.missingGIFRepresentation(outputURL.path)
        }
    }

    private static func renderStatusBarStylePreviewFrame(
        frameIndex: Int,
        style: TrafficSignalStyle,
        layout: TrafficSignalLayout,
        size: NSSize,
        iconOutputScale: CGFloat,
        macOSHorizontalUsesTrafficLightSize: Bool,
        path: String
    ) throws -> NSBitmapImageRep {
        let sheet = try makeBitmap(size: size, path: path)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        defer { NSGraphicsContext.restoreGraphicsState() }

        drawMenuBarPreviewBackdrop(in: NSRect(origin: .zero, size: size))

        let snapshot = SignalSnapshot(
            aggregate: .working,
            sessions: [],
            stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json")
        )
        let image = StatusBarIconRenderer.image(
            snapshot: snapshot,
            tick: frameIndex,
            layout: layout,
            style: style,
            macOSBreathingStrength: .maximum,
            macOSHorizontalUsesTrafficLightSize: macOSHorizontalUsesTrafficLightSize,
            allLightsOn: false,
            effectCustomization: SignalEffectCustomization(activeEffect: .trafficCycle),
            outputScale: iconOutputScale
        )

        let drawRect = NSRect(
            x: floor((size.width - image.size.width) / 2),
            y: floor((size.height - image.size.height) / 2),
            width: image.size.width,
            height: image.size.height
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: drawRect)

        return sheet
    }

    private static func drawMenuBarPreviewBackdrop(in rect: NSRect) {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.30, alpha: 1)
        ])?.draw(in: rect, angle: 0)

        NSColor.black.withAlphaComponent(0.12).setFill()
        NSRect(x: rect.minX, y: rect.maxY - min(24, rect.height * 0.28), width: rect.width, height: min(24, rect.height * 0.28)).fill()
        NSColor.white.withAlphaComponent(0.045).setFill()
        NSRect(origin: .zero, size: rect.size).fill()
    }

    private static func renderStatusBarDemoFrame(
        frameIndex: Int,
        size demoSize: NSSize,
        path: String
    ) throws -> NSBitmapImageRep {
        let sheet = try makeBitmap(size: demoSize, path: path)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGradient(colors: [
            NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.18, alpha: 1),
            NSColor(calibratedRed: 0.03, green: 0.34, blue: 0.36, alpha: 1)
        ])?.draw(in: NSRect(origin: .zero, size: demoSize), angle: 0)

        NSColor.white.withAlphaComponent(0.018).setFill()
        NSRect(origin: .zero, size: demoSize).fill()

        let snapshot = SignalSnapshot(
            aggregate: .working,
            sessions: [],
            stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json")
        )
        let customization = SignalEffectCustomization(activeEffect: .trafficCycle)
        let tick = frameIndex % 12

        drawStatusBarDemoIcon(
            snapshot: snapshot,
            tick: tick,
            style: .trafficLight,
            scale: 4.6,
            center: NSPoint(x: 190, y: 186),
            customization: customization
        )
        drawStatusBarDemoIcon(
            snapshot: snapshot,
            tick: tick,
            style: .macOS,
            scale: 4.8,
            center: NSPoint(x: 190, y: 106),
            customization: customization
        )

        drawText(
            "Agent Signal Bar",
            in: NSRect(x: 356, y: 168, width: 300, height: 34),
            font: .systemFont(ofSize: 21, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.86)
        )
        drawText(
            "Working",
            in: NSRect(x: 356, y: 118, width: 300, height: 54),
            font: .systemFont(ofSize: 40, weight: .bold),
            color: NSColor.white.withAlphaComponent(0.98)
        )
        drawText(
            "red / yellow / green sequence",
            in: NSRect(x: 358, y: 84, width: 320, height: 28),
            font: .systemFont(ofSize: 18, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.70)
        )

        return sheet
    }

    private static func drawStatusBarDemoIcon(
        snapshot: SignalSnapshot,
        tick: Int,
        style: TrafficSignalStyle,
        scale: CGFloat,
        center: NSPoint,
        customization: SignalEffectCustomization
    ) {
        let image = StatusBarIconRenderer.image(
            snapshot: snapshot,
            tick: tick,
            layout: .horizontal,
            style: style,
            macOSBreathingStrength: .maximum,
            allLightsOn: false,
            effectCustomization: customization
        )
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = NSRect(
            x: center.x - drawSize.width / 2,
            y: center.y - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func renderEffectGallery(language: EffectGalleryLanguage, to outputURL: URL) throws {
        let gallerySize = NSSize(width: 1600, height: 1280)
        let renderScale: CGFloat = 1
        let bitmapSize = NSSize(width: gallerySize.width * renderScale, height: gallerySize.height * renderScale)
        let frameCount = 16
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw PreviewError.missingGIFRepresentation(outputURL.path)
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: 0.16
            ]
        ]

        for frameIndex in 0..<frameCount {
            let sheet = try renderEffectGalleryFrame(
                language: language,
                frameIndex: frameIndex,
                size: gallerySize,
                bitmapSize: bitmapSize,
                renderScale: renderScale,
                path: outputURL.path
            )
            guard let image = sheet.cgImage else {
                throw PreviewError.missingGIFRepresentation(outputURL.path)
            }
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        if !CGImageDestinationFinalize(destination) {
            throw PreviewError.missingGIFRepresentation(outputURL.path)
        }
    }

    private static func renderEffectGalleryFrame(
        language: EffectGalleryLanguage,
        frameIndex: Int,
        size gallerySize: NSSize,
        bitmapSize: NSSize,
        renderScale: CGFloat,
        path: String
    ) throws -> NSBitmapImageRep {
        let sheet = try makeBitmap(size: bitmapSize, path: path)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGraphicsContext.current?.cgContext.scaleBy(x: renderScale, y: renderScale)

        NSGradient(colors: [
            NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.18, alpha: 1),
            NSColor(calibratedRed: 0.04, green: 0.24, blue: 0.27, alpha: 1)
        ])?.draw(in: NSRect(origin: .zero, size: gallerySize), angle: 0)

        NSColor.white.withAlphaComponent(0.018).setFill()
        NSRect(origin: .zero, size: gallerySize).fill()

        let outerPadding: CGFloat = 52
        let topReserved: CGFloat = 128
        let bottomPadding: CGFloat = 52

        drawText(
            language.title,
            in: NSRect(x: outerPadding, y: gallerySize.height - 78, width: 920, height: 42),
            font: .systemFont(ofSize: language == .english ? 30 : 32, weight: .bold),
            color: .white
        )
        drawText(
            language.subtitle,
            in: NSRect(x: outerPadding + 2, y: gallerySize.height - 110, width: 920, height: 24),
            font: .systemFont(ofSize: 18, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.62)
        )

        let columns = 3
        let rows = Int(ceil(Double(effectGalleryItems.count) / Double(columns)))
        let gapX: CGFloat = 24
        let gapY: CGFloat = 18
        let cardWidth = (gallerySize.width - outerPadding * 2 - gapX * CGFloat(columns - 1)) / CGFloat(columns)
        let cardHeight = (gallerySize.height - topReserved - bottomPadding - gapY * CGFloat(rows - 1)) / CGFloat(rows)
        let startX = outerPadding
        let startY = gallerySize.height - topReserved - cardHeight

        for (index, item) in effectGalleryItems.enumerated() {
            let column = index % columns
            let row = index / columns
            let cardRect = NSRect(
                x: startX + CGFloat(column) * (cardWidth + gapX),
                y: startY - CGFloat(row) * (cardHeight + gapY),
                width: cardWidth,
                height: cardHeight
            )
            drawEffectGalleryCard(
                item,
                language: language,
                frameIndex: frameIndex,
                in: cardRect
            )
        }

        return sheet
    }

    private static func drawEffectGalleryCard(
        _ item: EffectGalleryItem,
        language: EffectGalleryLanguage,
        frameIndex: Int,
        in rect: NSRect
    ) {
        NSColor.white.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 17, yRadius: 17)
        border.lineWidth = 1
        border.stroke()

        let contentInsetX: CGFloat = 22
        let halfWidth = rect.width / 2
        let textX = rect.minX + contentInsetX
        let iconAreaWidth: CGFloat = min(170, max(118, halfWidth - contentInsetX * 2))
        let iconAreaX = rect.midX + (halfWidth - iconAreaWidth) / 2
        let textColumnWidth = max(130, iconAreaX - textX - 14)

        drawText(
            item.title(for: language),
            in: NSRect(x: textX, y: rect.midY + 8, width: textColumnWidth, height: 38),
            font: .systemFont(ofSize: language == .english ? 27 : 30, weight: .bold),
            color: NSColor.white.withAlphaComponent(0.96)
        )
        drawText(
            item.detail(for: language),
            in: NSRect(x: textX, y: rect.midY - 22, width: textColumnWidth, height: 24),
            font: .systemFont(ofSize: language == .english ? 16 : 18, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.58)
        )

        let rowHeight: CGFloat = 36
        let rowGap: CGFloat = 10
        let groupHeight = rowHeight * 2 + rowGap
        let groupMinY = rect.midY - groupHeight / 2
        let minimalRect = NSRect(x: iconAreaX, y: groupMinY, width: iconAreaWidth, height: rowHeight)
        let classicRect = NSRect(x: iconAreaX, y: groupMinY + rowHeight + rowGap, width: iconAreaWidth, height: rowHeight)

        drawAnimatedPreviewIcon(item, style: .trafficLight, frameIndex: frameIndex, in: classicRect)
        drawAnimatedPreviewIcon(item, style: .macOS, frameIndex: frameIndex, in: minimalRect)
    }

    private static func drawAnimatedPreviewIcon(
        _ item: EffectGalleryItem,
        style: TrafficSignalStyle,
        frameIndex: Int,
        in rect: NSRect
    ) {
        let tick = item.tick(at: frameIndex)
        let lampDiameter: CGFloat = 20
        let lampSpacing: CGFloat = 8
        let lampSpan = lampDiameter * 3 + lampSpacing * 2
        let housingPaddingX: CGFloat = 9
        let housingPaddingY: CGFloat = 5
        let center = CGPoint(x: rect.midX, y: rect.midY)

        if style == .trafficLight {
            let housingRect = NSRect(
                x: center.x - (lampSpan + housingPaddingX * 2) / 2,
                y: center.y - (lampDiameter + housingPaddingY * 2) / 2,
                width: lampSpan + housingPaddingX * 2,
                height: lampDiameter + housingPaddingY * 2
            )
            drawPreviewHousing(in: housingRect)
        }

        let lampStartX = center.x - lampSpan / 2
        let lampY = center.y - lampDiameter / 2
        let colors: [SignalLampColor] = [.red, .yellow, .green]

        for (index, color) in colors.enumerated() {
            let lampRect = NSRect(
                x: lampStartX + CGFloat(index) * (lampDiameter + lampSpacing),
                y: lampY,
                width: lampDiameter,
                height: lampDiameter
            )
            let intensity = SignalLampAnimation.intensity(
                color,
                signal: item.signal,
                tick: tick,
                allLightsOn: item.allLightsOn,
                customization: item.customization
            )
            let baseScale = SignalLampAnimation.scale(
                color,
                signal: item.signal,
                tick: tick,
                allLightsOn: item.allLightsOn,
                customization: item.customization
            )
            let scale = SignalVisualScale.lampScale(
                baseScale: baseScale,
                intensity: intensity,
                style: style == .trafficLight ? .trafficLight : .macOS,
                macOSStrength: .maximum
            )
            drawPreviewLamp(
                color,
                in: lampRect,
                intensity: intensity,
                scale: scale,
                style: style,
                displayState: item.signal.displayState
            )
        }
    }

    private static func drawPreviewHousing(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: pixelAligned(rect), xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.88).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1.2
        path.stroke()
    }

    private static func drawPreviewLamp(
        _ color: SignalLampColor,
        in rect: NSRect,
        intensity: Double,
        scale: Double,
        style: TrafficSignalStyle,
        displayState: DisplayState
    ) {
        let baseRect = pixelAligned(rect)
        let basePath = NSBezierPath(ovalIn: baseRect)
        inactivePreviewFillColor(displayState: displayState, style: style).setFill()
        basePath.fill()
        previewBaseStrokeColor(displayState: displayState, style: style).setStroke()
        basePath.lineWidth = style == .macOS ? 2.2 : 0.85
        basePath.stroke()

        guard intensity > 0 else {
            return
        }

        let activeRect = pixelAligned(scaled(baseRect, by: scale))
        let activePath = NSBezierPath(ovalIn: activeRect)
        let lampColor = previewLampColor(color).withAlphaComponent(intensity)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = previewLampColor(color).withAlphaComponent(intensity * 0.38)
        shadow.shadowBlurRadius = style == .macOS ? 5 : 4
        shadow.set()
        lampColor.setFill()
        activePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        lampColor.withAlphaComponent(min(1, 0.82 + intensity * 0.18)).setStroke()
        activePath.lineWidth = style == .macOS ? 2.2 : 0.85
        activePath.stroke()

        guard style == .trafficLight, intensity > 0.7 else {
            return
        }

        let highlight = NSBezierPath(
            ovalIn: NSRect(
                x: activeRect.minX + activeRect.width * 0.18,
                y: activeRect.maxY - activeRect.height * 0.48,
                width: max(activeRect.width * 0.34, 1.5),
                height: max(activeRect.height * 0.34, 1.5)
            )
        )
        NSColor.white.withAlphaComponent(0.34).setFill()
        highlight.fill()
    }

    private static func inactivePreviewFillColor(displayState: DisplayState, style: TrafficSignalStyle) -> NSColor {
        if displayState == .paused {
            return NSColor.secondaryLabelColor.withAlphaComponent(style == .macOS ? 0.62 : 0.28)
        }
        if displayState == .stale {
            return NSColor.secondaryLabelColor.withAlphaComponent(style == .macOS ? 0.40 : 0.24)
        }

        switch style {
        case .trafficLight:
            return NSColor.secondaryLabelColor.withAlphaComponent(0.28)
        case .macOS:
            return NSColor.clear
        }
    }

    private static func previewBaseStrokeColor(displayState: DisplayState, style: TrafficSignalStyle) -> NSColor {
        if style == .trafficLight {
            return NSColor.white.withAlphaComponent(0.08)
        }
        if displayState == .paused || displayState == .stale {
            return NSColor.secondaryLabelColor.withAlphaComponent(0.70)
        }
        return NSColor.white.withAlphaComponent(0.86)
    }

    private static func previewLampColor(_ color: SignalLampColor) -> NSColor {
        switch color {
        case .green:
            return NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.34, alpha: 1)
        case .yellow:
            return NSColor(calibratedRed: 0.97, green: 0.72, blue: 0.16, alpha: 1)
        case .red:
            return NSColor(calibratedRed: 0.94, green: 0.20, blue: 0.18, alpha: 1)
        }
    }

    private static func pixelAligned(_ rect: NSRect) -> NSRect {
        NSRect(
            x: (rect.origin.x * 2).rounded() / 2,
            y: (rect.origin.y * 2).rounded() / 2,
            width: (rect.size.width * 2).rounded() / 2,
            height: (rect.size.height * 2).rounded() / 2
        )
    }

    private static func scaled(_ rect: NSRect, by scale: Double) -> NSRect {
        let scale = max(0, min(scale, 1))
        let width = rect.width * scale
        let height = rect.height * scale
        return NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func writeManifest(records: [PreviewRecord], to outputURL: URL) throws {
        let formatter = ISO8601DateFormatter()
        let manifest = PreviewManifest(
            generatedAt: formatter.string(from: Date()),
            description: "Status bar icon previews generated from StatusBarIconRenderer.",
            records: records.map { record in
                PreviewManifest.Record(
                    style: record.style.rawValue,
                    layout: record.layout.rawValue,
                    state: record.item.identifier,
                    signal: record.item.signal.rawValue,
                    displayState: record.item.signal.displayState.rawValue,
                    tick: record.item.tick,
                    allLightsOn: record.item.allLightsOn,
                    width: Int(record.imageSize.width),
                    height: Int(record.imageSize.height),
                    path: "icons/\(record.fileURL.lastPathComponent)"
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: outputURL)
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        let rep = try makeBitmap(size: image.size, path: url.path)
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PreviewError.missingPNGRepresentation(url.path)
        }
        try png.write(to: url)
    }

    private static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PreviewError.missingPNGRepresentation(url.path)
        }
        try png.write(to: url)
    }

    private static func makeBitmap(size: NSSize, path: String) throws -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)),
            pixelsHigh: Int(ceil(size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw PreviewError.missingPNGRepresentation(path)
        }
        rep.size = size
        return rep
    }

    private static func loadImage(_ url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url) else {
            throw PreviewError.missingImage(url.path)
        }
        return image
    }

    private static func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}

private struct PreviewItem: Sendable {
    let identifier: String
    let label: String
    let signal: AgentSignal
    let tick: Int
    let allLightsOn: Bool
}

private let previewItems: [PreviewItem] = [
    PreviewItem(identifier: "idle", label: "Idle", signal: .idle, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "working-low", label: "Working low", signal: .working, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "working-mid", label: "Working mid", signal: .working, tick: 2, allLightsOn: false),
    PreviewItem(identifier: "working-high", label: "Working high", signal: .working, tick: 5, allLightsOn: false),
    PreviewItem(identifier: "done", label: "Done", signal: .done, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "attention", label: "Attention", signal: .attention, tick: 2, allLightsOn: false),
    PreviewItem(identifier: "permission", label: "Permission", signal: .permission, tick: 2, allLightsOn: false),
    PreviewItem(identifier: "blocked-on", label: "Blocked on", signal: .blocked, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "blocked-off", label: "Blocked off", signal: .blocked, tick: 1, allLightsOn: false),
    PreviewItem(identifier: "stale", label: "Stale", signal: .stale, tick: 2, allLightsOn: false),
    PreviewItem(identifier: "off", label: "Off", signal: .off, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "all-lights-on", label: "All lights on", signal: .idle, tick: 0, allLightsOn: true)
]

private struct PreviewRecord {
    let style: TrafficSignalStyle
    let layout: TrafficSignalLayout
    let item: PreviewItem
    let fileURL: URL
    let imageSize: NSSize
}

private struct PreviewManifest: Encodable {
    let generatedAt: String
    let description: String
    let records: [Record]

    struct Record: Encodable {
        let style: String
        let layout: String
        let state: String
        let signal: String
        let displayState: String
        let tick: Int
        let allLightsOn: Bool
        let width: Int
        let height: Int
        let path: String
    }
}

private enum EffectGalleryLanguage {
    case english
    case simplifiedChinese

    var title: String {
        switch self {
        case .english:
            return "Light Effect Preview"
        case .simplifiedChinese:
            return "动态灯效预览图"
        }
    }

    var subtitle: String {
        switch self {
        case .english:
            return "Animated preview rendered from the same light animation engine"
        case .simplifiedChinese:
            return "由同一套灯效动画引擎生成的效果预览图"
        }
    }

}

private struct EffectGalleryItem {
    let enTitle: String
    let zhTitle: String
    let enDetail: String
    let zhDetail: String
    let signal: AgentSignal
    let ticks: [Int]
    let allLightsOn: Bool
    let customization: SignalEffectCustomization

    init(
        enTitle: String,
        zhTitle: String,
        enDetail: String,
        zhDetail: String,
        signal: AgentSignal,
        ticks: [Int],
        allLightsOn: Bool = false,
        customization: SignalEffectCustomization = .default
    ) {
        self.enTitle = enTitle
        self.zhTitle = zhTitle
        self.enDetail = enDetail
        self.zhDetail = zhDetail
        self.signal = signal
        self.ticks = ticks
        self.allLightsOn = allLightsOn
        self.customization = customization
    }

    func title(for language: EffectGalleryLanguage) -> String {
        switch language {
        case .english:
            return enTitle
        case .simplifiedChinese:
            return zhTitle
        }
    }

    func detail(for language: EffectGalleryLanguage) -> String {
        switch language {
        case .english:
            return enDetail
        case .simplifiedChinese:
            return zhDetail
        }
    }

    func tick(at frameIndex: Int) -> Int {
        guard !ticks.isEmpty else {
            return 0
        }
        return ticks[frameIndex % ticks.count]
    }
}

private let effectGalleryItems: [EffectGalleryItem] = [
    EffectGalleryItem(
        enTitle: "Idle",
        zhTitle: "空闲",
        enDetail: "steady green",
        zhDetail: "绿灯常亮",
        signal: .idle,
        ticks: [0]
    ),
    EffectGalleryItem(
        enTitle: "Thinking",
        zhTitle: "思考中",
        enDetail: "green fast flash",
        zhDetail: "绿灯快闪",
        signal: .thinking,
        ticks: [0, 1],
        customization: SignalEffectCustomization(thinkingEffect: .greenFastFlash)
    ),
    EffectGalleryItem(
        enTitle: "Working",
        zhTitle: "工作中",
        enDetail: "green slow flash",
        zhDetail: "绿灯慢闪",
        signal: .working,
        ticks: [0, 1, 2, 3, 4, 5],
        customization: SignalEffectCustomization(activeEffect: .greenSlowFlash)
    ),
    EffectGalleryItem(
        enTitle: "Green Breathe",
        zhTitle: "绿灯呼吸",
        enDetail: "smooth strength curve",
        zhDetail: "强度平滑变化",
        signal: .working,
        ticks: Array(0...9),
        customization: SignalEffectCustomization(activeEffect: .greenBreathing)
    ),
    EffectGalleryItem(
        enTitle: "Green Steady",
        zhTitle: "绿灯常亮",
        enDetail: "custom active effect",
        zhDetail: "自定义运行灯效",
        signal: .working,
        ticks: [0],
        customization: SignalEffectCustomization(activeEffect: .greenSteady)
    ),
    EffectGalleryItem(
        enTitle: "R/Y/G Sequence",
        zhTitle: "红黄绿依次亮",
        enDetail: "red, yellow, green",
        zhDetail: "红、黄、绿轮流亮",
        signal: .working,
        ticks: Array(0...11),
        customization: SignalEffectCustomization(activeEffect: .trafficCycle)
    ),
    EffectGalleryItem(
        enTitle: "Attention",
        zhTitle: "需要查看",
        enDetail: "yellow flash",
        zhDetail: "黄灯闪烁",
        signal: .attention,
        ticks: Array(0...7)
    ),
    EffectGalleryItem(
        enTitle: "Permission",
        zhTitle: "请求授权",
        enDetail: "red flash",
        zhDetail: "红灯闪烁",
        signal: .permission,
        ticks: Array(0...7)
    ),
    EffectGalleryItem(
        enTitle: "Blocked",
        zhTitle: "阻塞",
        enDetail: "fast red flash",
        zhDetail: "红灯快速闪烁",
        signal: .blocked,
        ticks: [0, 1]
    ),
    EffectGalleryItem(
        enTitle: "Done",
        zhTitle: "已完成",
        enDetail: "steady green",
        zhDetail: "绿灯常亮",
        signal: .done,
        ticks: [0],
        customization: SignalEffectCustomization(completedEffect: .greenSteady)
    ),
    EffectGalleryItem(
        enTitle: "Done Pulse",
        zhTitle: "完成闪烁",
        enDetail: "green or yellow pulse",
        zhDetail: "绿灯/黄灯慢闪",
        signal: .done,
        ticks: [0, 1, 2, 3],
        customization: SignalEffectCustomization(completedEffect: .yellowPulse)
    ),
    EffectGalleryItem(
        enTitle: "All On",
        zhTitle: "三灯全亮",
        enDetail: "all lights steady",
        zhDetail: "三个灯同时常亮",
        signal: .done,
        ticks: [0],
        customization: SignalEffectCustomization(completedEffect: .allSteady)
    ),
    EffectGalleryItem(
        enTitle: "All Flash",
        zhTitle: "三灯同步闪",
        enDetail: "all lights pulse",
        zhDetail: "三个灯一起闪烁",
        signal: .done,
        ticks: [0, 1, 2, 3],
        customization: SignalEffectCustomization(completedEffect: .allPulse)
    ),
    EffectGalleryItem(
        enTitle: "Stale",
        zhTitle: "状态不可信",
        enDetail: "soft yellow warning",
        zhDetail: "柔和黄灯提醒",
        signal: .stale,
        ticks: Array(0...7)
    ),
    EffectGalleryItem(
        enTitle: "Off",
        zhTitle: "关闭",
        enDetail: "all lights off",
        zhDetail: "灯全灭",
        signal: .off,
        ticks: [0]
    )
]

private enum PreviewError: Error, LocalizedError {
    case usage
    case missingPNGRepresentation(String)
    case missingGIFRepresentation(String)
    case missingImage(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: agent-signal-icon-preview [output-dir] or agent-signal-icon-preview --output <dir>"
        case .missingPNGRepresentation(let path):
            return "could not create PNG representation for \(path)"
        case .missingGIFRepresentation(let path):
            return "could not create GIF representation for \(path)"
        case .missingImage(let path):
            return "could not load preview image at \(path)"
        }
    }
}
