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
        // An end behind the camera cuts the line where it leaves the view rather than dropping
        // the measurement (issue #211); only the ends in view get a dot.
        guard let line = segment(m.start, m.end) else { return }

        // Leader line
        let path = Path { p in
            p.move(to: line.start)
            p.addLine(to: line.end)
        }
        context.stroke(path, with: .color(.white), lineWidth: 1.5)
        context.stroke(path, with: .color(.blue), lineWidth: 1.0)

        // Endpoints (small circles)
        if line.startIsEndpoint { drawEndpoint(at: line.start, in: &context) }
        if line.endIsEndpoint { drawEndpoint(at: line.end, in: &context) }

        // Label, at the midpoint, or at the middle of what is in view when that is culled.
        let text = m.label ?? formatDistance(m.distance)
        drawLabel(text, at: project(m.midpoint) ?? line.midpoint, in: &context)
    }

    // MARK: - Angle

    private func drawAngle(_ m: AngleMeasurement, in context: inout GraphicsContext, size: CGSize) {
        // Each arm is cut where it leaves the view (issue #211). Without the vertex in view
        // there is no corner for the arc, so only the visible parts of the arms are drawn.
        let armA = segment(m.vertex, m.pointA)
        let armB = segment(m.vertex, m.pointB)
        guard armA != nil || armB != nil else { return }

        // Draw the two arms
        let armPath = Path { p in
            for arm in [armA, armB].compactMap({ $0 }) {
                p.move(to: arm.start)
                p.addLine(to: arm.end)
            }
        }
        context.stroke(armPath, with: .color(.white), lineWidth: 1.5)
        context.stroke(armPath, with: .color(.orange), lineWidth: 1.0)

        guard let armA, let armB, armA.startIsEndpoint else { return }
        let vertexPt = armA.start
        let aPt = armA.end
        let bPt = armB.end

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
        // Cut where it leaves the view (issue #211); the markers only on the ends in view.
        guard let line = segment(m.center, m.edgePoint) else { return }
        let centerPt = line.start
        let edgePt = line.end

        // Leader line from center to edge
        let path = Path { p in
            p.move(to: centerPt)
            p.addLine(to: edgePt)
        }
        context.stroke(path, with: .color(.white), lineWidth: 1.5)
        context.stroke(path, with: .color(.green), lineWidth: 1.0)

        // Center marker (cross)
        if line.startIsEndpoint { drawCenterCross(at: centerPt, in: &context) }

        if line.endIsEndpoint { drawEndpoint(at: edgePt, in: &context) }

        // Label
        let value = m.showDiameter ? m.diameter : m.radius
        let prefix = m.showDiameter ? "\u{2300}" : "R"
        let text = m.label ?? "\(prefix)\(formatDistance(value))"
        drawLabel(text, at: line.midpoint, in: &context)
    }

    private func drawCenterCross(at centerPt: CGPoint, in context: inout GraphicsContext) {
        let crossSize: CGFloat = 4
        let crossPath = Path { p in
            p.move(to: CGPoint(x: centerPt.x - crossSize, y: centerPt.y))
            p.addLine(to: CGPoint(x: centerPt.x + crossSize, y: centerPt.y))
            p.move(to: CGPoint(x: centerPt.x, y: centerPt.y - crossSize))
            p.addLine(to: CGPoint(x: centerPt.x, y: centerPt.y + crossSize))
        }
        context.stroke(crossPath, with: .color(.green), lineWidth: 1.5)
    }

    // MARK: - Helpers

    private func project(_ point: SIMD3<Float>) -> CGPoint? {
        ProjectionUtility.worldToScreen(
            point: point, vpMatrix: vpMatrix, viewportSize: viewportSize)
    }

    /// The part of the segment from `a` to `b` in front of the camera, on screen.
    private func segment(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> ProjectionUtility.ScreenSegment? {
        ProjectionUtility.clippedSegmentToScreen(
            from: a, to: b, vpMatrix: vpMatrix, viewportSize: viewportSize)
    }

    /// The view-projection matrix the overlay projects with, built with the renderer's
    /// near/far planes for its last frame rather than a fixed 0.01/10000 (issue #204), so the
    /// overlay's depth is the renderer's.
    ///
    /// - Parameters:
    ///   - cameraState: The camera to project through.
    ///   - aspectRatio: The view's width / height.
    ///   - clipPlanes: The renderer's `lastFrameClipPlanes`, or `nil` before its first frame,
    ///     when `CameraState.clipPlanes(sceneBounds: nil)` (the wide default) is used.
    /// - Returns: Projection times view matrix.
    static func viewProjection(
        cameraState: CameraState, aspectRatio: Float, clipPlanes: (near: Float, far: Float)?
    ) -> simd_float4x4 {
        let clip = clipPlanes ?? cameraState.clipPlanes(sceneBounds: nil)
        return cameraState.projectionMatrix(
            aspectRatio: aspectRatio, near: clip.near, far: clip.far) * cameraState.viewMatrix
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
