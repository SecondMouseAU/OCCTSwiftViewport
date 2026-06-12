import Testing
import simd
@testable import OCCTSwiftViewport

/// Tap-to-measure interaction (#68): `measurementMode` now drives point
/// accumulation that commits `ViewportMeasurement`s.
@Suite("Measurement mode interaction")
struct MeasurementModeTests {

    // A unit quad in the z=0 plane, centred at the origin, normal +Z, stride-6
    // interleaved (position + normal). Two triangles: (0,1,2) and (0,2,3).
    private static func quad(id: String = "quad",
                             halfExtent h: Float = 2,
                             transform: simd_float4x4 = matrix_identity_float4x4) -> ViewportBody {
        let n: SIMD3<Float> = [0, 0, 1]
        let corners: [SIMD3<Float>] = [[-h, -h, 0], [h, -h, 0], [h, h, 0], [-h, h, 0]]
        var vertexData: [Float] = []
        for c in corners {
            vertexData += [c.x, c.y, c.z, n.x, n.y, n.z]
        }
        return ViewportBody(
            id: id,
            vertexData: vertexData,
            indices: [0, 1, 2, 0, 2, 3],
            edges: [],
            color: .one,
            transform: transform
        )
    }

    // Decoded face PickResult for body `objectIndex`, triangle `primitiveID`.
    private static func facePick(objectIndex: UInt32, primitiveID: UInt32, indexMap: [Int: String]) -> PickResult {
        let raw: UInt32 = (UInt32(PrimitiveKind.face.rawValue) << 30)
            | ((primitiveID & 0x3FFF) << 16)
            | (objectIndex & 0xFFFF)
        return PickResult(rawValue: raw, indexMap: indexMap, layerMap: [:])!
    }

    // Camera at +Z looking down -Z at the origin (identity rotation).
    private static func topCamera(distance: Float = 5) -> CameraState {
        CameraState(rotation: simd_quatf(angle: 0, axis: [0, 0, 1]),
                    distance: distance,
                    pivot: .zero)
    }

    // Column-major translation matrix (simd has no built-in initialiser).
    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    // MARK: - Point counts

    @Test("pointCount maps each mode to its requirement")
    func pointCounts() {
        #expect(ViewportController.pointCount(for: .none) == 0)
        #expect(ViewportController.pointCount(for: .distance) == 2)
        #expect(ViewportController.pointCount(for: .radius) == 2)
        #expect(ViewportController.pointCount(for: .angle) == 3)
    }

    // MARK: - Accumulation (pure)

    @MainActor
    @Test("Distance commits after two points and clears pending")
    func distanceCommits() {
        let c = ViewportController()
        c.measurementMode = .distance

        c.addMeasurementPoint([0, 0, 0])
        #expect(c.measurements.isEmpty)
        #expect(c.pendingMeasurementPoints.count == 1)

        c.addMeasurementPoint([3, 4, 0])
        #expect(c.pendingMeasurementPoints.isEmpty)
        #expect(c.measurements.count == 1)
        guard case let .distance(m) = c.measurements[0] else {
            Issue.record("expected a distance measurement"); return
        }
        #expect(m.start == [0, 0, 0])
        #expect(m.end == [3, 4, 0])
        #expect(abs(m.distance - 5) < 1e-5)
    }

    @MainActor
    @Test("Angle commits after three points in armA/vertex/armB order")
    func angleCommits() {
        let c = ViewportController()
        c.measurementMode = .angle

        c.addMeasurementPoint([1, 0, 0])   // armA
        c.addMeasurementPoint([0, 0, 0])   // vertex
        #expect(c.measurements.isEmpty)
        c.addMeasurementPoint([0, 1, 0])   // armB

        #expect(c.measurements.count == 1)
        guard case let .angle(m) = c.measurements[0] else {
            Issue.record("expected an angle measurement"); return
        }
        #expect(m.pointA == [1, 0, 0])
        #expect(m.vertex == [0, 0, 0])
        #expect(m.pointB == [0, 1, 0])
        #expect(abs(m.degrees - 90) < 1e-3)
    }

    @MainActor
    @Test("Radius commits as centre-then-edge")
    func radiusCommits() {
        let c = ViewportController()
        c.measurementMode = .radius

        c.addMeasurementPoint([0, 0, 0])   // centre
        c.addMeasurementPoint([2, 0, 0])   // edge

        #expect(c.measurements.count == 1)
        guard case let .radius(m) = c.measurements[0] else {
            Issue.record("expected a radius measurement"); return
        }
        #expect(m.center == [0, 0, 0])
        #expect(abs(m.radius - 2) < 1e-5)
    }

    @MainActor
    @Test("Two distance measurements accumulate independently")
    func multipleMeasurements() {
        let c = ViewportController()
        c.measurementMode = .distance
        c.addMeasurementPoint([0, 0, 0]); c.addMeasurementPoint([1, 0, 0])
        c.addMeasurementPoint([0, 0, 0]); c.addMeasurementPoint([0, 2, 0])
        #expect(c.measurements.count == 2)
        #expect(c.pendingMeasurementPoints.isEmpty)
    }

    // MARK: - Mode gating & cancellation

    @MainActor
    @Test("addMeasurementPoint is a no-op when mode is .none")
    func noneIgnores() {
        let c = ViewportController()
        c.addMeasurementPoint([0, 0, 0])
        #expect(c.pendingMeasurementPoints.isEmpty)
        #expect(c.measurements.isEmpty)
    }

    @MainActor
    @Test("Changing mode discards in-progress points")
    func modeChangeClearsPending() {
        let c = ViewportController()
        c.measurementMode = .distance
        c.addMeasurementPoint([0, 0, 0])
        #expect(c.pendingMeasurementPoints.count == 1)

        c.measurementMode = .angle
        #expect(c.pendingMeasurementPoints.isEmpty)
        #expect(c.measurements.isEmpty)
    }

    @MainActor
    @Test("cancelPendingMeasurement keeps the mode, drops points")
    func cancelKeepsMode() {
        let c = ViewportController()
        c.measurementMode = .distance
        c.addMeasurementPoint([0, 0, 0])
        c.cancelPendingMeasurement()
        #expect(c.pendingMeasurementPoints.isEmpty)
        #expect(c.measurementMode == .distance)
    }

    @MainActor
    @Test("clearMeasurements removes committed and pending")
    func clearAll() {
        let c = ViewportController()
        c.measurementMode = .distance
        c.addMeasurementPoint([0, 0, 0]); c.addMeasurementPoint([1, 0, 0]) // 1 committed
        c.addMeasurementPoint([0, 0, 0]) // 1 pending
        c.clearMeasurements()
        #expect(c.measurements.isEmpty)
        #expect(c.pendingMeasurementPoints.isEmpty)
    }

    // MARK: - World-point reconstruction

    @Test("worldHitPoint intersects the picked triangle in world space")
    func worldHitPointIdentity() {
        let body = Self.quad()
        // Ray straight down -Z through the origin hits the quad at (0,0,0).
        let ray = Ray(origin: [0, 0, 5], direction: [0, 0, -1])
        let p = body.worldHitPoint(ray: ray, triangleIndex: 0)
        #expect(p != nil)
        if let p {
            #expect(abs(p.x) < 1e-5 && abs(p.y) < 1e-5 && abs(p.z) < 1e-5)
        }
    }

    @Test("worldHitPoint respects the body transform")
    func worldHitPointTransformed() {
        let t = Self.translation([10, 0, 0])
        let body = Self.quad(transform: t)
        // The quad now spans x∈[8,12]; a ray at x=0 misses, x=10 hits.
        #expect(body.worldHitPoint(ray: Ray(origin: [0, 0, 5], direction: [0, 0, -1]), triangleIndex: 0) == nil)
        let hit = body.worldHitPoint(ray: Ray(origin: [10, 0, 5], direction: [0, 0, -1]), triangleIndex: 0)
        #expect(hit != nil)
        if let hit { #expect(abs(hit.x - 10) < 1e-5 && abs(hit.z) < 1e-5) }
    }

    @Test("worldHitPoint returns nil for an out-of-range triangle")
    func worldHitPointOutOfRange() {
        let body = Self.quad()
        #expect(body.worldHitPoint(ray: Ray(origin: [0, 0, 5], direction: [0, 0, -1]), triangleIndex: 99) == nil)
    }

    // MARK: - End-to-end pick routing

    @MainActor
    @Test("handleMeasurementPick reconstructs and accumulates surface points")
    func pickRoutingCommitsDistance() {
        let c = ViewportController()
        c.animateTo(Self.topCamera(), duration: 0)
        c.measurementMode = .distance
        let bodies = [Self.quad()]
        let map: [Int: String] = [0: "quad"]

        // Two off-centre face taps land on distinct points of the quad.
        c.handleMeasurementPick(result: Self.facePick(objectIndex: 0, primitiveID: 0, indexMap: map),
                                ndc: [0.2, -0.2], bodies: bodies, aspectRatio: 1)
        #expect(c.pendingMeasurementPoints.count == 1)

        c.handleMeasurementPick(result: Self.facePick(objectIndex: 0, primitiveID: 1, indexMap: map),
                                ndc: [-0.2, 0.2], bodies: bodies, aspectRatio: 1)

        #expect(c.measurements.count == 1)
        guard case let .distance(m) = c.measurements[0] else {
            Issue.record("expected a distance measurement"); return
        }
        #expect(m.distance > 0)             // the two taps were distinct points
        #expect(abs(m.start.z) < 1e-4)      // both lie on the z=0 quad
        #expect(abs(m.end.z) < 1e-4)
    }

    @MainActor
    @Test("handleMeasurementPick ignores misses and non-face picks")
    func pickRoutingIgnoresNonFace() {
        let c = ViewportController()
        c.animateTo(Self.topCamera(), duration: 0)
        c.measurementMode = .distance
        let bodies = [Self.quad()]
        let map: [Int: String] = [0: "quad"]

        // A miss (nil) does nothing.
        c.handleMeasurementPick(result: nil, ndc: .zero, bodies: bodies, aspectRatio: 1)
        #expect(c.pendingMeasurementPoints.isEmpty)

        // An edge pick (not a surface) does nothing.
        let edgeRaw = (UInt32(PrimitiveKind.edge.rawValue) << 30) | 0
        let edge = PickResult(rawValue: edgeRaw, indexMap: map, layerMap: [:])!
        c.handleMeasurementPick(result: edge, ndc: .zero, bodies: bodies, aspectRatio: 1)
        #expect(c.pendingMeasurementPoints.isEmpty)
    }
}
