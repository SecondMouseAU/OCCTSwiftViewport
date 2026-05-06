// MeasurementCompositor.swift
// OCCTSwiftViewport
//
// Composites ViewportMeasurement annotations (distance / angle / radius)
// onto a base CGImage using Core Graphics + Core Text. The drawing semantics
// mirror the SwiftUI `MeasurementOverlay` Canvas so headless renders match
// what the interactive viewport shows.

import simd
import CoreGraphics
import CoreText
import Foundation

@MainActor
internal enum MeasurementCompositor {

    /// Composites measurements over `baseImage` and returns a new image of the same dimensions.
    /// Returns `baseImage` unchanged when `measurements` is empty.
    static func composite(
        baseImage: CGImage,
        measurements: [ViewportMeasurement],
        viewProjection: simd_float4x4,
        viewportSize: CGSize
    ) -> CGImage? {
        guard !measurements.isEmpty else { return baseImage }

        let width = Int(viewportSize.width)
        let height = Int(viewportSize.height)
        guard width > 0, height > 0 else { return baseImage }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        // Stamp the rendered scene first; CG draws bottom-up, but `draw(image,in:)`
        // already orients the CGImage so its row 0 lands at the top of the rect.
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Overlay drawing convention: every screen-space coordinate produced by
        // `ProjectionUtility.worldToScreen` is top-down (origin top-left). We
        // convert each point to bottom-up CG space at the call site.
        for measurement in measurements {
            switch measurement {
            case .distance(let m):
                drawDistance(m, in: ctx, vp: viewProjection, viewportSize: viewportSize)
            case .angle(let m):
                drawAngle(m, in: ctx, vp: viewProjection, viewportSize: viewportSize)
            case .radius(let m):
                drawRadius(m, in: ctx, vp: viewProjection, viewportSize: viewportSize)
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Distance

    private static func drawDistance(
        _ m: DistanceMeasurement,
        in ctx: CGContext,
        vp: simd_float4x4,
        viewportSize: CGSize
    ) {
        guard let s = project(m.start, vp: vp, viewportSize: viewportSize),
              let e = project(m.end, vp: vp, viewportSize: viewportSize),
              let mid = project(m.midpoint, vp: vp, viewportSize: viewportSize) else { return }

        // Leader line (white halo + blue core).
        strokeLine(s, e, in: ctx, color: Palette.white, width: 1.5)
        strokeLine(s, e, in: ctx, color: Palette.blue, width: 1.0)

        drawEndpoint(at: s, in: ctx)
        drawEndpoint(at: e, in: ctx)

        let text = m.label ?? formatDistance(m.distance)
        drawLabel(text, at: mid, in: ctx)
    }

    // MARK: - Angle

    private static func drawAngle(
        _ m: AngleMeasurement,
        in ctx: CGContext,
        vp: simd_float4x4,
        viewportSize: CGSize
    ) {
        guard let v = project(m.vertex, vp: vp, viewportSize: viewportSize),
              let a = project(m.pointA, vp: vp, viewportSize: viewportSize),
              let b = project(m.pointB, vp: vp, viewportSize: viewportSize) else { return }

        // Arms.
        strokePolyline([a, v, b], in: ctx, color: Palette.white, width: 1.5)
        strokePolyline([a, v, b], in: ctx, color: Palette.orange, width: 1.0)

        // Arc indicator. atan2 in screen-space (top-down y) gives the same
        // visual arc as the SwiftUI Canvas overlay, which also uses top-down y.
        let armLength: CGFloat = 30
        let angleA = atan2(a.y - v.y, a.x - v.x)
        let angleB = atan2(b.y - v.y, b.x - v.x)

        // CG's default arc direction matches "clockwise=true" when y-axis is
        // up (i.e., bottom-up CG space). Our screen-space angles were computed
        // in y-down space, so flip them when feeding CG.
        let cgAngleA = -angleA
        let cgAngleB = -angleB
        let vCG = toCG(v, viewportSize: viewportSize)

        ctx.setStrokeColor(Palette.orange)
        ctx.setLineWidth(1.0)
        ctx.beginPath()
        ctx.addArc(
            center: vCG,
            radius: armLength,
            startAngle: cgAngleA,
            endAngle: cgAngleB,
            clockwise: angleSweepClockwise(from: angleA, to: angleB)
        )
        ctx.strokePath()

        // Label sits just outside the arc midpoint.
        let midAngle = (angleA + angleB) / 2
        let label = CGPoint(
            x: v.x + cos(midAngle) * (armLength + 15),
            y: v.y + sin(midAngle) * (armLength + 15)
        )
        let text = m.label ?? String(format: "%.1f\u{00B0}", m.degrees)
        drawLabel(text, at: label, in: ctx)
    }

    // MARK: - Radius

    private static func drawRadius(
        _ m: RadiusMeasurement,
        in ctx: CGContext,
        vp: simd_float4x4,
        viewportSize: CGSize
    ) {
        guard let center = project(m.center, vp: vp, viewportSize: viewportSize),
              let edge = project(m.edgePoint, vp: vp, viewportSize: viewportSize) else { return }

        // Leader.
        strokeLine(center, edge, in: ctx, color: Palette.white, width: 1.5)
        strokeLine(center, edge, in: ctx, color: Palette.green, width: 1.0)

        // Center cross marker.
        let crossSize: CGFloat = 4
        strokeLine(
            CGPoint(x: center.x - crossSize, y: center.y),
            CGPoint(x: center.x + crossSize, y: center.y),
            in: ctx, color: Palette.green, width: 1.5
        )
        strokeLine(
            CGPoint(x: center.x, y: center.y - crossSize),
            CGPoint(x: center.x, y: center.y + crossSize),
            in: ctx, color: Palette.green, width: 1.5
        )

        drawEndpoint(at: edge, in: ctx)

        let value = m.showDiameter ? m.diameter : m.radius
        let prefix = m.showDiameter ? "\u{2300}" : "R"
        let text = m.label ?? "\(prefix)\(formatDistance(value))"
        let mid = CGPoint(x: (center.x + edge.x) / 2, y: (center.y + edge.y) / 2)
        drawLabel(text, at: mid, in: ctx)
    }

    // MARK: - Drawing primitives

    private static func strokeLine(
        _ a: CGPoint, _ b: CGPoint,
        in ctx: CGContext,
        color: CGColor,
        width: CGFloat
    ) {
        let viewportSize = CGSize(width: ctx.width, height: ctx.height)
        let aCG = toCG(a, viewportSize: viewportSize)
        let bCG = toCG(b, viewportSize: viewportSize)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.beginPath()
        ctx.move(to: aCG)
        ctx.addLine(to: bCG)
        ctx.strokePath()
    }

    private static func strokePolyline(
        _ pts: [CGPoint],
        in ctx: CGContext,
        color: CGColor,
        width: CGFloat
    ) {
        guard pts.count >= 2 else { return }
        let viewportSize = CGSize(width: ctx.width, height: ctx.height)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.beginPath()
        ctx.move(to: toCG(pts[0], viewportSize: viewportSize))
        for p in pts.dropFirst() {
            ctx.addLine(to: toCG(p, viewportSize: viewportSize))
        }
        ctx.strokePath()
    }

    private static func drawEndpoint(at point: CGPoint, in ctx: CGContext) {
        let viewportSize = CGSize(width: ctx.width, height: ctx.height)
        let cg = toCG(point, viewportSize: viewportSize)
        let radius: CGFloat = 3
        let rect = CGRect(x: cg.x - radius, y: cg.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(Palette.white)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(Palette.blue)
        ctx.setLineWidth(1.0)
        ctx.strokeEllipse(in: rect)
    }

    private static func drawLabel(_ text: String, at point: CGPoint, in ctx: CGContext) {
        let viewportSize = CGSize(width: ctx.width, height: ctx.height)
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 11, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Palette.white
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent

        // Match MeasurementOverlay: bg rect is centered on `point` but offset 10pt up,
        // with 4pt padding around the text size; text drawn at (point.x, point.y - 10).
        let padding: CGFloat = 4
        let labelOffsetY: CGFloat = 10
        let bgWidth = textWidth + padding * 2
        let bgHeight = textHeight + padding * 2

        let bgRectScreen = CGRect(
            x: point.x - bgWidth / 2,
            y: point.y - bgHeight / 2 - labelOffsetY,
            width: bgWidth,
            height: bgHeight
        )
        let bgRectCG = toCGRect(bgRectScreen, viewportSize: viewportSize)

        // Rounded-rect background (fill + thin stroke).
        let cornerRadius = bgRectCG.height / 2
        let bgPath = CGPath(roundedRect: bgRectCG, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.setFillColor(Palette.blackTranslucent)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.setStrokeColor(Palette.whiteTranslucent)
        ctx.setLineWidth(0.5)
        ctx.addPath(bgPath)
        ctx.strokePath()

        // Text baseline. The SwiftUI version centers the text at (point.x, point.y - 10).
        // CTLineDraw places the line origin on the baseline, so we offset down by descent
        // and left by half the line's typographic width.
        let textCenterScreen = CGPoint(x: point.x, y: point.y - labelOffsetY)
        let textCenterCG = toCG(textCenterScreen, viewportSize: viewportSize)
        let baselineX = textCenterCG.x - textWidth / 2
        let baselineY = textCenterCG.y - (ascent - descent) / 2
        ctx.textPosition = CGPoint(x: baselineX, y: baselineY)
        CTLineDraw(line, ctx)
    }

    // MARK: - Helpers

    private static func project(
        _ point: SIMD3<Float>,
        vp: simd_float4x4,
        viewportSize: CGSize
    ) -> CGPoint? {
        ProjectionUtility.worldToScreen(point: point, vpMatrix: vp, viewportSize: viewportSize)
    }

    /// Converts a top-down screen-space point into CG bottom-up coordinates.
    private static func toCG(_ p: CGPoint, viewportSize: CGSize) -> CGPoint {
        CGPoint(x: p.x, y: viewportSize.height - p.y)
    }

    /// Converts a top-down screen-space rect into CG bottom-up coordinates.
    private static func toCGRect(_ r: CGRect, viewportSize: CGSize) -> CGRect {
        CGRect(
            x: r.origin.x,
            y: viewportSize.height - r.origin.y - r.size.height,
            width: r.size.width,
            height: r.size.height
        )
    }

    private static func angleSweepClockwise(from a: CGFloat, to b: CGFloat) -> Bool {
        var diff = b - a
        if diff < 0 { diff += .pi * 2 }
        return diff > .pi
    }

    private static func formatDistance(_ value: Float) -> String {
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }

    // MARK: - Palette
    //
    // sRGB equivalents of the SwiftUI system colors used in MeasurementOverlay.
    // Picked to match Apple's system-blue / orange / green so headless and
    // interactive renders look identical at a glance.

    private enum Palette {
        static let white = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        static let blue = CGColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
        static let orange = CGColor(srgbRed: 1.0, green: 0.584, blue: 0.0, alpha: 1.0)
        static let green = CGColor(srgbRed: 0.204, green: 0.78, blue: 0.349, alpha: 1.0)
        static let blackTranslucent = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.7)
        static let whiteTranslucent = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.3)
    }
}
