// Measurement.swift
// ViewportKit
//
// Value types for viewport measurement annotations.

import Foundation
import simd

/// A measurement annotation displayed as an overlay on the viewport.
public enum ViewportMeasurement: Identifiable, Sendable {
    /// Point-to-point distance measurement.
    case distance(DistanceMeasurement)
    /// Angle measurement between three points.
    case angle(AngleMeasurement)
    /// Radius/diameter measurement.
    case radius(RadiusMeasurement)

    public var id: String {
        switch self {
        case .distance(let m): return m.id
        case .angle(let m): return m.id
        case .radius(let m): return m.id
        }
    }
}

/// A point-to-point distance measurement.
public struct DistanceMeasurement: Identifiable, Sendable {
    public let id: String
    /// Start point in world coordinates.
    public var start: SIMD3<Float>
    /// End point in world coordinates.
    public var end: SIMD3<Float>
    /// Optional label override (default: computed distance).
    public var label: String?

    /// The computed distance value.
    public var distance: Float {
        simd_length(end - start)
    }

    /// The midpoint for label placement.
    public var midpoint: SIMD3<Float> {
        (start + end) * 0.5
    }

    public init(id: String = UUID().uuidString, start: SIMD3<Float>, end: SIMD3<Float>, label: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.label = label
    }
}

/// An angle measurement between three points (vertex at the middle point).
public struct AngleMeasurement: Identifiable, Sendable {
    public let id: String
    /// First arm endpoint.
    public var pointA: SIMD3<Float>
    /// Vertex point (where the angle is measured).
    public var vertex: SIMD3<Float>
    /// Second arm endpoint.
    public var pointB: SIMD3<Float>
    /// Optional label override.
    public var label: String?

    /// The computed angle in degrees.
    public var degrees: Float {
        ProjectionUtility.angle(pointA, vertex: vertex, pointB)
    }

    public init(id: String = UUID().uuidString, pointA: SIMD3<Float>, vertex: SIMD3<Float>, pointB: SIMD3<Float>, label: String? = nil) {
        self.id = id
        self.pointA = pointA
        self.vertex = vertex
        self.pointB = pointB
        self.label = label
    }
}

/// A radius or diameter measurement.
public struct RadiusMeasurement: Identifiable, Sendable {
    public let id: String
    /// Center point of the circle/arc.
    public var center: SIMD3<Float>
    /// A point on the circle/arc edge.
    public var edgePoint: SIMD3<Float>
    /// Whether to display as diameter (true) or radius (false).
    public var showDiameter: Bool
    /// Optional label override.
    public var label: String?

    /// The computed radius value.
    public var radius: Float {
        simd_length(edgePoint - center)
    }

    /// The computed diameter value.
    public var diameter: Float {
        radius * 2.0
    }

    public init(id: String = UUID().uuidString, center: SIMD3<Float>, edgePoint: SIMD3<Float>, showDiameter: Bool = false, label: String? = nil) {
        self.id = id
        self.center = center
        self.edgePoint = edgePoint
        self.showDiameter = showDiameter
        self.label = label
    }
}

/// Mode for measurement interaction.
public enum MeasurementMode: Sendable, Equatable {
    /// No measurement tool active.
    case none
    /// Measuring point-to-point distance.
    case distance
    /// Measuring angle between three points.
    case angle
    /// Measuring radius/diameter.
    case radius
}
