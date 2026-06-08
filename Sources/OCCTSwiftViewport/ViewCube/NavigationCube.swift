// NavigationCube.swift
// ViewportKit
//
// Pure projection + hit-testing for the interactive navigation cube (issue #60).
// SwiftUI-free so it can be unit-tested without a view.

import simd
import CoreGraphics

/// Projects a unit cube under a camera rotation and resolves taps to one of the
/// 26 `ViewCubeRegion`s (6 faces / 12 edges / 8 corners).
///
/// Convention matches the existing ViewCube: a world point projects to screen as
/// `(rotatedₓ, -rotated_y)` where `rotated = rotation.inverse.act(point)`, and the
/// face↔axis mapping is +X=right, -X=left, +Y=back, -Y=front, +Z=top, -Z=bottom.
public struct NavigationCube {

    /// Current camera rotation the cube tracks.
    public var rotation: simd_quatf
    /// Widget side length in points.
    public var size: CGFloat
    /// Inset from the widget edge, in points.
    public var padding: CGFloat

    public init(rotation: simd_quatf, size: CGFloat, padding: CGFloat = 6) {
        self.rotation = rotation
        self.size = size
        self.padding = padding
    }

    /// Pixels per cube unit. The rotated cube's silhouette reaches ~√3 units; we
    /// scale so a face (±1) fits comfortably with the corners allowed to approach
    /// the edges.
    public var scale: CGFloat { (size * 0.5 - padding) / 1.45 }

    private var center: CGPoint { CGPoint(x: size * 0.5, y: size * 0.5) }

    /// Projects a cube-local point (`[-1,1]³`) to widget coordinates.
    public func project(_ p: SIMD3<Float>) -> CGPoint {
        let r = rotation.inverse.act(p)
        return CGPoint(x: center.x + CGFloat(r.x) * scale,
                       y: center.y - CGFloat(r.y) * scale)
    }

    // MARK: - Faces

    /// The 6 faces with their outward normals (cube convention above).
    static let faces: [(region: ViewCubeRegion, normal: SIMD3<Float>)] = [
        (.right,  SIMD3( 1, 0, 0)),
        (.left,   SIMD3(-1, 0, 0)),
        (.back,   SIMD3( 0, 1, 0)),
        (.front,  SIMD3( 0,-1, 0)),
        (.top,    SIMD3( 0, 0, 1)),
        (.bottom, SIMD3( 0, 0,-1)),
    ]

    /// A face that currently faces the camera, with its projected geometry.
    public struct VisibleFace {
        public let region: ViewCubeRegion
        public let corners: [CGPoint]   // 4, in projected order
        public let center: CGPoint
        public let depth: Float         // toward-camera depth of the face centre (for sorting)
    }

    /// The faces pointing toward the camera, back-to-front (draw in order).
    public func visibleFaces() -> [VisibleFace] {
        let viewDir = rotation.act(SIMD3<Float>(0, 0, -1))   // where the camera looks
        var result: [VisibleFace] = []
        for face in Self.faces {
            // Visible when the outward normal opposes the look direction.
            if simd_dot(face.normal, viewDir) >= -1e-4 { continue }
            let corners3 = Self.faceCorners(normal: face.normal)
            let projected = corners3.map { project($0) }
            // Depth = component of the face centre along the toward-camera axis.
            let towardCam = rotation.act(SIMD3<Float>(0, 0, 1))
            let depth = simd_dot(face.normal, towardCam)
            result.append(VisibleFace(region: face.region,
                                      corners: projected,
                                      center: project(face.normal),
                                      depth: depth))
        }
        return result.sorted { $0.depth < $1.depth }   // far first
    }

    /// The four corners of a face (cube-local), ordered around the face.
    static func faceCorners(normal n: SIMD3<Float>) -> [SIMD3<Float>] {
        // Two in-plane axes.
        let u: SIMD3<Float>
        let v: SIMD3<Float>
        if abs(n.x) > 0.5 { u = SIMD3(0, 1, 0); v = SIMD3(0, 0, 1) }
        else if abs(n.y) > 0.5 { u = SIMD3(1, 0, 0); v = SIMD3(0, 0, 1) }
        else { u = SIMD3(1, 0, 0); v = SIMD3(0, 1, 0) }
        return [n - u - v, n + u - v, n + u + v, n - u + v]
    }

    // MARK: - Hit testing

    /// Resolves a tap (widget coordinates) to a region, or `nil` if it misses the
    /// cube silhouette. Casts the tap as a ray through the cube and classifies the
    /// frontmost surface point into the 3×3-per-face grid.
    public func region(at point: CGPoint) -> ViewCubeRegion? {
        guard scale > 0 else { return nil }
        // Tap in the rotated frame's screen plane (x right, y up).
        let tx = Float((point.x - center.x) / scale)
        let ty = Float((center.y - point.y) / scale)   // screen y is down → flip

        // Ray in world space: base + s * dir, where +s goes toward the camera.
        let base = rotation.act(SIMD3<Float>(tx, ty, 0))
        let dir = rotation.act(SIMD3<Float>(0, 0, 1))

        guard let (sNear, sFar) = Self.intersectUnitCube(base: base, dir: dir),
              sFar >= sNear else { return nil }
        let surface = base + sFar * dir   // frontmost (toward camera)

        return Self.classify(surface)
    }

    /// Slab clip of `base + s·dir` against `[-1,1]³`. Returns the `s` interval, or nil.
    static func intersectUnitCube(base: SIMD3<Float>, dir: SIMD3<Float>) -> (Float, Float)? {
        var tMin = -Float.greatestFiniteMagnitude
        var tMax = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            let b = base[axis], d = dir[axis]
            if abs(d) < 1e-6 {
                if b < -1 || b > 1 { return nil }   // parallel & outside this slab
            } else {
                var t0 = (-1 - b) / d
                var t1 = (1 - b) / d
                if t0 > t1 { swap(&t0, &t1) }
                tMin = max(tMin, t0)
                tMax = min(tMax, t1)
                if tMin > tMax { return nil }
            }
        }
        return (tMin, tMax)
    }

    /// Classifies a cube-surface point into a region. Each tangent coordinate in
    /// the outer third (|c| > 1/3) activates that face; the hit face's own
    /// near-±1 coordinate is always active. 1–3 active faces → face/edge/corner.
    static func classify(_ p: SIMD3<Float>) -> ViewCubeRegion? {
        let t: Float = 1.0 / 3.0
        var active: Set<ViewCubeRegion> = []
        if p.z > t { active.insert(.top) } else if p.z < -t { active.insert(.bottom) }
        if p.y > t { active.insert(.back) } else if p.y < -t { active.insert(.front) }
        if p.x > t { active.insert(.right) } else if p.x < -t { active.insert(.left) }
        guard !active.isEmpty else { return nil }
        return regionLookup[active]
    }

    /// `Set<face regions>` → the combined region (built from each region's faces).
    static let regionLookup: [Set<ViewCubeRegion>: ViewCubeRegion] = {
        var map: [Set<ViewCubeRegion>: ViewCubeRegion] = [:]
        for region in ViewCubeRegion.allCases {
            map[region.baseFaceSet] = region
        }
        return map
    }()
}

extension ViewCubeRegion {
    /// The 1–3 base faces this region combines, e.g. `.topFrontRight → {top,front,right}`.
    var baseFaceSet: Set<ViewCubeRegion> {
        let names: [String: ViewCubeRegion] = [
            "top": .top, "bottom": .bottom, "front": .front,
            "back": .back, "left": .left, "right": .right,
        ]
        return Set(displayName.lowercased().split(separator: "-").compactMap { names[String($0)] })
    }
}
