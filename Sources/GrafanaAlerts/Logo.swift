import AppKit
import SwiftUI

/// Grafana's icon, drawn from its SVG path so it stays crisp at any size.
enum GrafanaMark {
    enum Fill {
        case gradient
        case solid(CGColor)
    }

    /// Draws in y-up coordinates, fitted and centered in `rect`.
    static func draw(in ctx: CGContext, rect: CGRect, fill: Fill) {
        let box = GrafanaIconPath.viewBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        ctx.saveGState()
        // SVG space is y-down: flip into it around the rect's center.
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -box.width / 2, y: -box.height / 2)
        ctx.addPath(GrafanaIconPath.path)
        switch fill {
        case .solid(let color):
            ctx.setFillColor(color)
            ctx.fillPath()
        case .gradient:
            ctx.clip()
            // Same as the SVG: #F05A28 at 30% height → #FBCA0A at 99%, top to bottom.
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            let gradient = CGGradient(colorsSpace: srgb, colors: [
                NSColor.grafanaOrange.cgColor, NSColor.grafanaYellow.cgColor,
            ] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: box.width / 2, y: box.height * 0.30),
                                   end: CGPoint(x: box.width / 2, y: box.height * 0.99),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }
}

/// SwiftUI wrapper for the mark.
struct GrafanaMarkView: View {
    var monochrome = false

    var body: some View {
        Canvas { context, size in
            context.withCGContext { ctx in
                // Canvas is y-down; flip so the shared drawing code (y-up) renders upright.
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                GrafanaMark.draw(in: ctx, rect: CGRect(origin: .zero, size: size),
                                 fill: monochrome ? .solid(NSColor.labelColor.cgColor) : .gradient)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Menu bar

struct MenuBarModel: Equatable {
    enum State: Equatable { case ok, loading, error }

    var state: State = .loading
    var count = 0
    var severity: Severity = .critical
    var color: IconColor = .color
    var badge: BadgeStyle = .badge
    var severityColors = true
    var dimWhenEmpty = true

    @MainActor
    static func make(store: AlertStore) -> MenuBarModel {
        var model = MenuBarModel(color: Prefs.iconColor, badge: Prefs.badgeStyle,
                                 severityColors: Prefs.severityColors, dimWhenEmpty: Prefs.dimWhenEmpty)
        model.count = store.badgeCount
        model.severity = store.worstSeverity ?? .critical
        if store.error != nil, store.lastFetched == nil || store.error == .notConfigured {
            model.state = .error
        } else if store.lastFetched == nil {
            model.state = .loading
        } else if let error = store.error {
            // A brief network blip with recent data isn't worth flagging; auth problems and stale data are.
            if case .network = error, !store.isStale { model.state = .ok } else { model.state = .error }
        } else {
            model.state = .ok
        }
        return model
    }

    var countText: String { count > 99 ? "99+" : "\(count)" }

    var badgeNSColor: NSColor {
        guard severityColors else { return .systemRed }
        return severity == .unknown ? .systemRed : severity.nsColor
    }
}

enum MenuBarRenderer {
    static let logoSide: CGFloat = 18
    /// How far the count badge tucks over the logo's right edge.
    static let badgeOverlap: CGFloat = 5
    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    static func width(for model: MenuBarModel) -> CGFloat {
        let base: CGFloat = logoSide + 8
        guard model.count > 0 else { return base }
        switch model.badge {
        case .badge: return 4 + logoSide - badgeOverlap + badgeSize(model).width + 3
        case .number: return logoSide + 4 + 4 + textWidth(model.countText, numberFont) + 4
        case .dot, .none: return base
        }
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func badgeSize(_ model: MenuBarModel) -> CGSize {
        let height: CGFloat = 12
        return CGSize(width: max(height, textWidth(model.countText, badgeFont) + 6), height: height)
    }

    /// Call with the status button's appearance so the ink color matches the menu bar.
    static func draw(_ model: MenuBarModel, in ctx: CGContext, bounds: CGRect, appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            let ink = NSColor.labelColor.cgColor
            let mono = model.color == .monochrome
            let logoRect = CGRect(x: 4, y: (bounds.height - logoSide) / 2, width: logoSide, height: logoSide)

            var alpha: CGFloat = 1
            switch model.state {
            case .error: alpha = 0.4
            case .loading: alpha = 0.55
            case .ok: if model.count == 0 && model.dimWhenEmpty { alpha = 0.5 }
            }

            ctx.saveGState()
            ctx.setAlpha(alpha)
            GrafanaMark.draw(in: ctx, rect: logoRect, fill: mono ? .solid(ink) : .gradient)
            ctx.restoreGState()

            let badgeVisible = model.count > 0 && model.badge != .none
            if model.state == .error && !badgeVisible {
                drawErrorMark(ctx, at: CGPoint(x: logoRect.maxX - 2.5, y: logoRect.minY + 3.5), ink: ink, mono: mono)
            }
            guard model.count > 0 else { return }

            let badgeColor = mono ? ink : (model.state == .error ? NSColor.systemGray.cgColor : model.badgeNSColor.cgColor)
            switch model.badge {
            case .badge:
                let size = badgeSize(model)
                let rect = CGRect(x: logoRect.maxX - badgeOverlap, y: logoRect.minY - 1,
                                  width: size.width, height: size.height)
                drawBadge(ctx, rect: rect, text: model.countText, fill: badgeColor, mono: mono)
            case .number:
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: numberFont,
                    .foregroundColor: mono || !model.severityColors ? NSColor.labelColor : NSColor(cgColor: badgeColor) ?? .labelColor,
                ]
                let text = NSAttributedString(string: model.countText, attributes: attributes)
                let size = text.size()
                NSGraphicsContext.saveGraphicsState()
                text.draw(at: CGPoint(x: logoRect.maxX + 4, y: (bounds.height - size.height) / 2))
                NSGraphicsContext.restoreGraphicsState()
            case .dot:
                let d: CGFloat = 7
                let rect = CGRect(x: logoRect.maxX - d + 1, y: logoRect.minY, width: d, height: d)
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: rect.insetBy(dx: -1.5, dy: -1.5))
                ctx.restoreGState()
                ctx.setFillColor(badgeColor)
                ctx.fillEllipse(in: rect)
            case .none:
                break
            }
        }
    }

    private static func drawBadge(_ ctx: CGContext, rect: CGRect, text: String, fill: CGColor, mono: Bool) {
        // Punch a gap around the badge so it doesn't merge with the mark.
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        let halo = rect.insetBy(dx: -1.5, dy: -1.5)
        ctx.addPath(CGPath(roundedRect: halo, cornerWidth: halo.height / 2, cornerHeight: halo.height / 2, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()

        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: badgeFont, .foregroundColor: NSColor.white,
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                   y: rect.midY - bounds.height / 2 - bounds.minY)
        if mono { ctx.setBlendMode(.destinationOut) }   // knock the digits out of the ink pill
        CTLineDraw(line, ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawErrorMark(_ ctx: CGContext, at center: CGPoint, ink: CGColor, mono: Bool) {
        let d: CGFloat = 7
        let rect = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: rect.insetBy(dx: -1.5, dy: -1.5))
        ctx.restoreGState()
        ctx.setFillColor(mono ? ink : NSColor.systemGray.cgColor)
        ctx.fillEllipse(in: rect)
    }

    static func image(for model: MenuBarModel, appearance: NSAppearance, height: CGFloat = 22) -> NSImage {
        let size = NSSize(width: width(for: model), height: height)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(model, in: ctx, bounds: rect, appearance: appearance)
            return true
        }
    }
}

// MARK: - App icon

enum AppIcon {
    static func renderIconset(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in specs {
            let rep = bitmap(side: CGFloat(pixels)) { ctx, side in draw(ctx, side: side) }
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
    }

    /// The Grafana icon on a dark, Grafana-panel-colored squircle.
    static func draw(_ ctx: CGContext, side: CGFloat) {
        let inset = side * 100 / 1024
        let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = rect.width * 0.225
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.grafanaDark.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: srgb, colors: [
            CGColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1),
            CGColor(srgbRed: 0.075, green: 0.082, blue: 0.094, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        let logo = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.14)
        GrafanaMark.draw(in: ctx, rect: logo, fill: .gradient)
        ctx.restoreGState()
    }

    static func bitmap(side: CGFloat, draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(context.cgContext, side)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
