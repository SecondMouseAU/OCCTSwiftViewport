// MeasurementOverlay.swift
// ViewportKit
//
// SwiftUI overlay for rendering measurement annotations on the viewport.

import SwiftUI
import simd

/// A SwiftUI overlay that draws measurement annotations (distances, angles, radii)
/// on top of the Metal viewport using Canvas for leader lines and dimension text.
@MainActor
struct MeasurementOverlay: View {
    let measurements: [ViewportMeasurement]
    let vpMatrix: simd_float4x4
    let viewportSize: CGSize

    var body: some View {
        Canvas { context, size in
            for measurement in measurements {
                switch measurement {
                case .distance(let m):
                    drawDistance(m, in: &context, size: size)
                case .angle(let m):
                    drawAngle(m, in: &context, size: size)
                case .radius(let m):
                    drawRadius(m, in: &context, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Distance

    private func drawDistance(
        _ m: DistanceMeasurement, in context: inout GraphicsContext, size: CGSize
    ) {
        guard let startPt = project(m.start),
            let endPt = project(m.end),
            let midPt = project(m.midpoint)
        else { return }

        // Leader line
        let path = Path { p in
            p.move(to: startPt)
            p.addLine(to: endPt)
        }
        context.stroke(path, with: .color(.white), lineWidth: 1.5)
        context.stroke(path, with: .color(.blue), lineWidth: 1.0)

        // Endpoints (small circles)
        drawEndpoint(at: startPt, in: &context)
        drawEndpoint(at: endPt, in: &context)

        // Label
        let text = m.label ?? formatDistance(m.distance)
        drawLabel(text, at: midPt, in: &context)
    }

    // MARK: - Angle

    private func drawAngle(_ m: AngleMeasurement, in context: inout GraphicsContext, size: CGSize) {
        guard let vertexPt = project(m.vertex),
            let aPt = project(m.pointA),
            let bPt = project(m.pointB)
        else { return }

        // Draw the two arms
        let armPath = Path { p in
            p.move(to: aPt)
            p.addLine(to: vertexPt)
            p.addLine(to: bPt)
        }
        context.stroke(armPath, with: .color(.white), lineWidth: 1.5)
        context.stroke(armPath, with: .color(.orange), lineWidth: 1.0)

        // Draw arc indicator
        let armLength: CGFloat = 30
        let angleA = atan2(aPt.y - vertexPt.y, aPt.x - vertexPt.x)
        let angleB = atan2(bPt.y - vertexPt.y, bPt.x - vertexPt.x)

        let arcPath = Path { p in
            p.addArc(
                center: vertexPt,
                radius: armLength,
                startAngle: .radians(Double(angleA)),
                endAngle: .radians(Double(angleB)),
                clockwise: angleSweepClockwise(from: angleA, to: angleB)
            )
        }
        context.stroke(arcPath, with: .color(.orange), lineWidth: 1.0)

        // Label at arc midpoint
        let midAngle = (angleA + angleB) / 2
        let labelPt = CGPoint(
            x: vertexPt.x + cos(midAngle) * (armLength + 15),
            y: vertexPt.y + sin(midAngle) * (armLength + 15)
        )

        let text = m.label ?? String(format: "%.1f\u{00B0}", m.degrees)
        drawLabel(text, at: labelPt, in: &context)
    }

    // MARK: - Radius

    private func drawRadius(_ m: RadiusMeasurement, in context: inout GraphicsContext, size: CGSize)
    {
        guard let centerPt = project(m.center),
            let edgePt = project(m.edgePoint)
        else { return }

        // Leader line from center to edge
        let path = Path { p in
            p.move(to: centerPt)
            p.addLine(to: edgePt)
        }
        context.stroke(path, with: .color(.white), lineWidth: 1.5)
        context.stroke(path, with: .color(.green), lineWidth: 1.0)

        // Center marker (cross)
        let crossSize: CGFloat = 4
        let crossPath = Path { p in
            p.move(to: CGPoint(x: centerPt.x - crossSize, y: centerPt.y))
            p.addLine(to: CGPoint(x: centerPt.x + crossSize, y: centerPt.y))
            p.move(to: CGPoint(x: centerPt.x, y: centerPt.y - crossSize))
            p.addLine(to: CGPoint(x: centerPt.x, y: centerPt.y + crossSize))
        }
        context.stroke(crossPath, with: .color(.green), lineWidth: 1.5)

        drawEndpoint(at: edgePt, in: &context)

        // Label
        let value = m.showDiameter ? m.diameter : m.radius
        let prefix = m.showDiameter ? "\u{2300}" : "R"
        let text = m.label ?? "\(prefix)\(formatDistance(value))"
        let midPt = CGPoint(
            x: (centerPt.x + edgePt.x) / 2,
            y: (centerPt.y + edgePt.y) / 2
        )
        drawLabel(text, at: midPt, in: &context)
    }

    // MARK: - Helpers

    private func project(_ point: SIMD3<Float>) -> CGPoint? {
        ProjectionUtility.worldToScreen(
            point: point, vpMatrix: vpMatrix, viewportSize: viewportSize)
    }

    private func drawEndpoint(at point: CGPoint, in context: inout GraphicsContext) {
        let radius: CGFloat = 3
        let circle = Path(
            ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2
            ))
        context.fill(circle, with: .color(.white))
        context.stroke(circle, with: .color(.blue), lineWidth: 1.0)
    }

    private func drawLabel(_ text: String, at point: CGPoint, in context: inout GraphicsContext) {
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white))

        let textSize = resolved.measure(in: CGSize(width: 200, height: 50))

        // Background capsule
        let padding: CGFloat = 4
        let bgRect = CGRect(
            x: point.x - textSize.width / 2 - padding,
            y: point.y - textSize.height / 2 - padding - 10,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        let capsule = Path(roundedRect: bgRect, cornerRadius: bgRect.height / 2)
        context.fill(capsule, with: .color(.black.opacity(0.7)))
        context.stroke(capsule, with: .color(.white.opacity(0.3)), lineWidth: 0.5)

        context.draw(
            resolved,
            at: CGPoint(
                x: point.x,
                y: point.y - 10
            ), anchor: .center)
    }

    private func formatDistance(_ value: Float) -> String {
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }

    private func angleSweepClockwise(from a: CGFloat, to b: CGFloat) -> Bool {
        var diff = b - a
        if diff < 0 { diff += .pi * 2 }
        return diff > .pi
    }
}
