// CameraScale.swift
// ViewportKit
//
// Pure (SwiftUI-free) helpers for screen-space HUD overlays: world-units-per-point
// from the camera, and "nice" scale-bar metrics. A Graphic3d_TransMode analogue —
// these feed overlays that ignore the camera transform.

import Foundation
import CoreGraphics

extension CameraState {

    /// World units spanned by one screen point at the focus (pivot) depth.
    ///
    /// For orthographic cameras the value is depth-independent (`orthographicScale`
    /// is the on-screen vertical extent). For perspective cameras it is evaluated at
    /// `distance` — the pivot depth — since perspective scale varies with depth and
    /// the pivot is the meaningful reference for a scale bar.
    ///
    /// - Parameter viewportHeightPoints: The viewport height in points (not pixels).
    /// - Returns: World units per point, or `0` for a degenerate viewport.
    public func worldUnitsPerPoint(viewportHeightPoints: Float) -> Float {
        guard viewportHeightPoints > 0, viewportHeightPoints.isFinite else { return 0 }
        let visibleHeight: Float
        if isOrthographic {
            visibleHeight = orthographicScale
        } else {
            let fovY = fieldOfView * .pi / 180.0
            visibleHeight = 2.0 * distance * tan(fovY * 0.5)
        }
        return max(0, visibleHeight) / viewportHeightPoints
    }
}

/// Resolved geometry for a screen-space scale bar.
///
/// Given a world-units-per-point scale and a target on-screen length, snaps the
/// represented length to a "nice" 1 / 2 / 5 × 10ⁿ value and reports the matching
/// bar length in points plus a formatted label.
public struct ScaleBarMetrics: Equatable, Sendable {

    /// The (rounded) world length the bar represents.
    public let worldLength: Float

    /// The bar length in screen points.
    public let pointLength: CGFloat

    /// Formatted label, e.g. `"10 mm"` (or just `"10"` when no unit is given).
    public let label: String

    /// Builds metrics for a scale bar, or `nil` if the inputs are degenerate.
    ///
    /// - Parameters:
    ///   - worldUnitsPerPoint: World units per screen point (see
    ///     `CameraState.worldUnitsPerPoint(viewportHeightPoints:)`).
    ///   - targetPoints: The desired bar length in points; the actual length is the
    ///     nearest nice value to this.
    ///   - unitLabel: Optional unit suffix (the library is unit-agnostic).
    public init?(worldUnitsPerPoint: Float, targetPoints: CGFloat, unitLabel: String = "") {
        guard worldUnitsPerPoint > 0, worldUnitsPerPoint.isFinite,
              targetPoints > 0 else { return nil }
        let targetWorld = worldUnitsPerPoint * Float(targetPoints)
        let nice = Self.niceNumber(targetWorld)
        guard nice > 0 else { return nil }
        self.worldLength = nice
        self.pointLength = CGFloat(nice / worldUnitsPerPoint)
        let num = Self.format(nice)
        self.label = unitLabel.isEmpty ? num : "\(num) \(unitLabel)"
    }

    /// Rounds a positive value to the nearest 1 / 2 / 5 × 10ⁿ.
    public static func niceNumber(_ x: Float) -> Float {
        guard x > 0, x.isFinite else { return 0 }
        let exp = floor(log10(x))
        let base = pow(10, exp)
        let f = x / base                 // in [1, 10)
        let nice: Float
        if f < 1.5 { nice = 1 }
        else if f < 3.5 { nice = 2 }
        else if f < 7.5 { nice = 5 }
        else { nice = 10 }
        return nice * base
    }

    /// Formats a nice value: integers above 1, trimmed decimals below.
    static func format(_ x: Float) -> String {
        if x >= 1 {
            return String(Int(x.rounded()))
        }
        var s = String(format: "%.3f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
