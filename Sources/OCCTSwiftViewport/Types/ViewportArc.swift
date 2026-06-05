// ViewportArc.swift
// ViewportKit
//
// Analytic arc/circle feature edge, sampled to line segments adaptively by the
// renderer (issue #48) so circular edges stay smooth at any zoom.

import simd

/// An analytic circular arc in body-local space.
///
/// Defined by a center, radius, and an in-plane orthonormal basis (`xAxis`,
/// `yAxis`); a point at angle θ is
/// `center + radius * (cos θ · xAxis + sin θ · yAxis)`. The renderer samples the
/// arc to line segments adaptively to its projected size each frame, so a circle
/// renders smooth regardless of zoom — no pre-faceting by the consumer.
public struct ViewportArc: Sendable, Hashable {

    /// Arc center (body-local space).
    public var center: SIMD3<Float>

    /// Arc radius.
    public var radius: Float

    /// Unit in-plane axis for angle 0.
    public var xAxis: SIMD3<Float>

    /// Unit in-plane axis for angle π/2 (with `xAxis`, spans the arc plane).
    public var yAxis: SIMD3<Float>

    /// Start angle in radians.
    public var startAngle: Float

    /// End angle in radians (`endAngle > startAngle` sweeps counter-clockwise in
    /// the `xAxis`→`yAxis` plane).
    public var endAngle: Float

    public init(center: SIMD3<Float>,
                radius: Float,
                xAxis: SIMD3<Float>,
                yAxis: SIMD3<Float>,
                startAngle: Float = 0,
                endAngle: Float = 2 * .pi) {
        self.center = center
        self.radius = radius
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.startAngle = startAngle
        self.endAngle = endAngle
    }

    /// A full circle in the plane spanned by `xAxis`/`yAxis` (which should be unit
    /// and orthogonal; their cross product is the circle's normal).
    public static func circle(center: SIMD3<Float>,
                              radius: Float,
                              xAxis: SIMD3<Float>,
                              yAxis: SIMD3<Float>) -> ViewportArc {
        ViewportArc(center: center, radius: radius, xAxis: xAxis, yAxis: yAxis,
                    startAngle: 0, endAngle: 2 * .pi)
    }

    /// The swept angle (always non-negative).
    public var sweep: Float { abs(endAngle - startAngle) }

    /// Point on the arc at parameter `t` in `[0, 1]` (local space).
    public func point(at t: Float) -> SIMD3<Float> {
        let theta = startAngle + (endAngle - startAngle) * t
        return center + radius * (cos(theta) * xAxis + sin(theta) * yAxis)
    }
}

/// Pure helpers for adaptively sampling `ViewportArc`s to line segments.
public enum ArcSampling {

    /// Number of line segments to draw the arc with, chosen so each segment is
    /// roughly `targetPixels` long on screen.
    ///
    /// Estimates the arc's projected length by coarsely sampling and projecting
    /// through `mvp` (model · view · projection), then divides by `targetPixels`.
    /// Clamped to `[minSegments, maxSegments]` and to an angular ceiling so even a
    /// tiny on-screen circle keeps a round-ish shape. Falls back to `maxSegments`
    /// if the arc crosses behind the camera (`w <= 0`).
    public static func segmentCount(arc: ViewportArc,
                                    mvp: simd_float4x4,
                                    viewportSize: SIMD2<Float>,
                                    targetPixels: Float = 6,
                                    minSegments: Int = 6,
                                    maxSegments: Int = 512) -> Int {
        let coarse = 8
        var pixelLength: Float = 0
        var prev: SIMD2<Float>? = nil
        var behind = false
        for i in 0...coarse {
            let t = Float(i) / Float(coarse)
            let local = arc.point(at: t)
            let clip = mvp * SIMD4<Float>(local, 1)
            if clip.w <= 1e-5 { behind = true; break }
            let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
            let px = SIMD2<Float>((ndc.x * 0.5) * viewportSize.x,
                                  (ndc.y * 0.5) * viewportSize.y)
            if let p = prev { pixelLength += simd_length(px - p) }
            prev = px
        }

        // Angular ceiling: at least one segment per ~12° keeps small circles round.
        let angularMin = Int((arc.sweep / (Float.pi / 15)).rounded(.up))

        if behind {
            return max(minSegments, min(maxSegments, max(angularMin, maxSegments / 4)))
        }
        let byPixels = Int((pixelLength / max(targetPixels, 0.5)).rounded(.up))
        let n = max(minSegments, max(angularMin, byPixels))
        return min(maxSegments, n)
    }
}
