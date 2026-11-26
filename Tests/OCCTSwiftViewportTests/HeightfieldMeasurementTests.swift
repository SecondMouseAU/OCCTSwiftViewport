// HeightfieldMeasurementTests.swift
// OCCTSwiftViewport Tests
//
// Tap-to-measure on a heightfield body (#261). `worldHitPoint(ray:triangleIndex:)` reads corners
// through `indices`, which a heightfield body does not have, so a measurement tap on terrain used
// to be dropped silently. Every test taps through the real pick rig: a GPU pick of the field, then
// `handleTapPick` with the tap's own NDC, as `MetalViewportView` does.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Tap-to-measure on a heightfield (#261)")
struct HeightfieldMeasurementTests {

    private static let cells = 120
    private static let slope: Float = 0.05
    private static let size = 256

    /// A plane, `slope * (x + y)` high at cell `(x, y)`.
    ///
    /// The surface spans the cell centres, so in body-local space a point `(x, y)` on it has
    /// `z = slope * (x + y - 1)`, whichever way the quads are split into triangles.
    private static func plane() throws -> Heightfield {
        var heights = [Float](repeating: 0, count: cells * cells)
        for y in 0..<cells {
            for x in 0..<cells { heights[y * cells + x] = Float(x + y) * slope }
        }
        return try Heightfield(width: cells, height: cells, heights: heights)
    }

    private static func localHeight(x: Float, y: Float) -> Float { slope * (x + y - 1) }

    /// Top-down orthographic camera over `pivot`: 256 px for 260 world units, about 1 unit a pixel.
    private static func camera(over pivot: SIMD3<Float>) -> CameraState {
        CameraState(distance: 400, pivot: pivot, orthographicScale: 260, isOrthographic: true)
    }

    private static func ndc(of pixel: SIMD2<Int>) -> SIMD2<Float> {
        SIMD2(
            (Float(pixel.x) + 0.5) / Float(size) * 2 - 1,
            1 - (Float(pixel.y) + 0.5) / Float(size) * 2)
    }

    /// World XY of the centre of `pixel` for `camera(over: pivot)`: 260 units over 256 px, y down.
    private static func world(of pixel: SIMD2<Int>, pivot: SIMD3<Float>) -> SIMD2<Float> {
        let scale: Float = 260 / Float(size)
        let half = Float(size) / 2
        return SIMD2(
            pivot.x + (Float(pixel.x) + 0.5 - half) * scale,
            pivot.y - (Float(pixel.y) + 0.5 - half) * scale)
    }

    /// A rig over `bodies` and a controller in `.distance` mode.
    private static func rig(
        bodies: [ViewportBody], pivot: SIMD3<Float>
    ) throws -> HeightfieldPickRig {
        let rig = try HeightfieldPickRig(
            bodies: bodies, camera: camera(over: pivot), width: size, height: size)
        rig.controller.measurementMode = .distance
        return rig
    }

    /// Taps `pixel`: the GPU pick, then the controller's tap routing with the pixel's own NDC.
    private static func tap(
        _ pixel: SIMD2<Int>, rig: HeightfieldPickRig, bodies: [ViewportBody],
        ndc override: SIMD2<Float>? = nil
    ) async throws {
        let raw = try #require(await rig.pick(pixel), "the GPU pick missed \(pixel)")
        #expect(raw.kind == .face)
        #expect(raw.heightfield != nil)
        rig.controller.handleTapPick(
            result: raw, ndc: override ?? ndc(of: pixel), bodies: bodies, aspectRatio: 1)
    }

    /// `point` in the body's local space.
    private static func local(_ point: SIMD3<Float>, of body: ViewportBody) -> SIMD3<Float> {
        let p = body.transform.inverse * SIMD4<Float>(point, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// Checks that the pending point is on the field's surface under `pixel`.
    private static func expectOnSurface(
        _ point: SIMD3<Float>, pixel: SIMD2<Int>, pivot: SIMD3<Float>, body: ViewportBody
    ) {
        // The camera looks straight down, so the point is over the pixel's own world XY ...
        let xy = world(of: pixel, pivot: pivot)
        #expect(abs(point.x - xy.x) < 0.01 && abs(point.y - xy.y) < 0.01, "\(point) over \(xy)")
        // ... and, in the field's own space, on the plane.
        let l = local(point, of: body)
        let expected = localHeight(x: l.x, y: l.y)
        #expect(abs(l.z - expected) < 0.01, "local \(l): height \(l.z), the plane has \(expected)")
    }

    // MARK: Tapping the surface

    @Test("A tap on a heightfield adds a measurement point at the field's surface")
    func tapAddsPointOnSurface() async throws {
        let body = HeightfieldScene.body(try Self.plane())
        let pivot = SIMD3<Float>(60, 60, 0)
        let rig = try Self.rig(bodies: [body], pivot: pivot)

        let first = SIMD2(128, 128)
        try await Self.tap(first, rig: rig, bodies: [body])
        let firstPoint = try #require(rig.controller.pendingMeasurementPoints.first)
        Self.expectOnSurface(firstPoint, pixel: first, pivot: pivot, body: body)

        let second = SIMD2(90, 170)
        try await Self.tap(second, rig: rig, bodies: [body])
        // Two taps commit a distance, between the two surface points.
        #expect(rig.controller.pendingMeasurementPoints.isEmpty)
        let measurement = try #require(rig.controller.measurements.first)
        guard case .distance(let distance) = measurement else {
            Issue.record("expected a distance measurement")
            return
        }
        Self.expectOnSurface(distance.start, pixel: first, pivot: pivot, body: body)
        Self.expectOnSurface(distance.end, pixel: second, pivot: pivot, body: body)
        #expect(distance.distance > 10)
    }

    @Test("A tap on a translated heightfield lands on the moved surface")
    func tapOnTranslatedField() async throws {
        var body = HeightfieldScene.body(try Self.plane())
        body.transform.columns.3 = SIMD4(30, -10, 15, 1)
        let pivot = SIMD3<Float>(90, 50, 15)
        let rig = try Self.rig(bodies: [body], pivot: pivot)

        for pixel in [SIMD2(128, 128), SIMD2(100, 150), SIMD2(160, 90)] {
            try await Self.tap(pixel, rig: rig, bodies: [body])
            let point = try #require(rig.controller.pendingMeasurementPoints.last)
            Self.expectOnSurface(point, pixel: pixel, pivot: pivot, body: body)
            // Not the field's local point: the translation is in the result.
            #expect(point.z > 15)
            rig.controller.cancelPendingMeasurement()
        }
    }

    @Test("A tap on a rotated, non-uniformly scaled and moved heightfield lands on its surface")
    func tapOnRotatedScaledField() async throws {
        var body = HeightfieldScene.body(try Self.plane())
        body.transform =
            simd_float4x4(simd_quatf(angle: 0.4, axis: SIMD3(0, 0, 1)))
            * simd_float4x4(diagonal: SIMD4(1.2, 0.9, 2, 1))
        body.transform.columns.3 = SIMD4(-30, 20, 5, 1)
        // The camera is over the field's local centre (60, 60).
        let centre = body.transform * SIMD4<Float>(60, 60, 0, 1)
        let pivot = SIMD3<Float>(centre.x, centre.y, 0)
        let rig = try Self.rig(bodies: [body], pivot: pivot)

        for pixel in [SIMD2(128, 128), SIMD2(100, 150), SIMD2(160, 90)] {
            try await Self.tap(pixel, rig: rig, bodies: [body])
            let point = try #require(rig.controller.pendingMeasurementPoints.last)
            Self.expectOnSurface(point, pixel: pixel, pivot: pivot, body: body)
            rig.controller.cancelPendingMeasurement()
        }
    }

    // MARK: Tapping beside the field

    @Test("A tap whose ray misses the field adds no point, and does not crash")
    func tapThatMissesAddsNothing() async throws {
        var body = HeightfieldScene.body(try Self.plane())
        body.transform.columns.3 = SIMD4(30, -10, 15, 1)
        let bodies = [body]
        let pivot = SIMD3<Float>(90, 50, 15)
        let rig = try Self.rig(bodies: bodies, pivot: pivot)

        // The GPU pick is a heightfield hit, but this tap's ray passes beside the field.
        for ndc in [SIMD2<Float>(-5, -5), SIMD2(5, 0), SIMD2(0, 5), SIMD2(0.9, 0.99)] {
            try await Self.tap(SIMD2(128, 128), rig: rig, bodies: bodies, ndc: ndc)
        }
        #expect(rig.controller.pendingMeasurementPoints.isEmpty)
        #expect(rig.controller.measurements.isEmpty)

        // A tap that does hit still works afterwards.
        try await Self.tap(SIMD2(128, 128), rig: rig, bodies: bodies)
        #expect(rig.controller.pendingMeasurementPoints.count == 1)
    }

    // MARK: Meshes are unchanged

    @Test("A tap on a mesh in front of a heightfield still measures the mesh")
    func meshInFrontStillMeasuresTheMesh() async throws {
        let field = HeightfieldScene.body(try Self.plane())
        var box = ViewportBody.box(
            id: "box", width: 20, height: 20, depth: 20, color: SIMD4(0.8, 0.2, 0.2, 1))
        box.transform.columns.3 = SIMD4(60, 60, 200, 1)
        let bodies = [field, box]
        let pivot = SIMD3<Float>(60, 60, 0)
        let rig = try Self.rig(bodies: bodies, pivot: pivot)

        let raw = try #require(await rig.pick(SIMD2(128, 128)))
        #expect(raw.bodyID == "box")
        #expect(raw.heightfield == nil)
        rig.controller.handleTapPick(
            result: raw, ndc: Self.ndc(of: SIMD2(128, 128)), bodies: bodies, aspectRatio: 1)
        let point = try #require(rig.controller.pendingMeasurementPoints.first)
        // The top face of a 20-unit box centred at z = 200.
        #expect(abs(point.z - 210) < 0.01, "\(point)")
    }
}
