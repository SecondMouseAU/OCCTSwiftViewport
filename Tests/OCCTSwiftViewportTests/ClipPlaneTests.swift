import Testing
import simd
@testable import OCCTSwiftViewport

@Suite("Scene-adaptive clip planes")
struct ClipPlaneTests {

    /// Camera at +Z looking at the origin from `distance` (identity rotation,
    /// pivot at origin → camera distance to a centered scene == `distance`).
    private func camera(distance: Float) -> CameraState {
        CameraState(rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
                    distance: distance, pivot: .zero)
    }

    @Test("Nil bounds falls back to the wide default")
    func nilBoundsFallback() {
        let (near, far) = camera(distance: 10).clipPlanes(sceneBounds: nil)
        #expect(near == 0.01)
        #expect(far == 10_000)
    }

    @Test("Small unit model gets a tight, well-conditioned range")
    func smallModelTightRange() {
        let bounds = BoundingBox(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        let (near, far) = camera(distance: 6).clipPlanes(sceneBounds: bounds)
        #expect(near > 0)
        #expect(near < far)
        #expect(near > 3 && near < 6)        // hugs the front of the model
        #expect(far / near < 100)            // vs ~1e6 with the old fixed range
    }

    @Test("Large mm-scale model (railcar-ish) keeps the ratio bounded (fixes #57)")
    func largeModelBoundedRatio() {
        // ~37.9 × 50.1 × 269.5 mm, like the reported railcar STL.
        let bounds = BoundingBox(min: SIMD3<Float>(-19, -25, -135),
                                 max: SIMD3<Float>(19, 25, 135))
        let (near, far) = camera(distance: 400).clipPlanes(sceneBounds: bounds)
        #expect(near > 0 && near < far)
        #expect(far / near < 100,
                "ratio must stay sane at mm scale; got near=\(near) far=\(far) ratio=\(far / near)")
    }

    @Test("Camera inside the scene still yields a valid positive range")
    func cameraInsideScene() {
        let bounds = BoundingBox(min: SIMD3<Float>(-5, -5, -5), max: SIMD3<Float>(5, 5, 5))
        let (near, far) = camera(distance: 0.5).clipPlanes(sceneBounds: bounds)
        #expect(near > 0)
        #expect(near < far)
    }

    @Test("Range scales with the model: tiny and huge models both stay conditioned")
    func scalesWithModel() {
        let tiny = BoundingBox(min: SIMD3<Float>(repeating: -0.001), max: SIMD3<Float>(repeating: 0.001))
        let huge = BoundingBox(min: SIMD3<Float>(repeating: -5000), max: SIMD3<Float>(repeating: 5000))
        let (tn, tf) = camera(distance: 0.01).clipPlanes(sceneBounds: tiny)
        let (hn, hf) = camera(distance: 20_000).clipPlanes(sceneBounds: huge)
        #expect(tn > 0 && tn < tf && tf / tn < 1000)
        #expect(hn > 0 && hn < hf && hf / hn < 1000)
    }

    // MARK: - Camera inside the bounding sphere, issue #116

    @Test("Near plane hugs the box, not the bounding sphere, once the camera is inside it")
    func nearHugsBoxNotSphere() {
        // A flat slab, so the circumscribed sphere is far larger than the geometry.
        // Camera at +Z 5 units out is well inside that sphere but 4 units clear of the slab.
        let slab = BoundingBox(min: SIMD3<Float>(-10, -10, -1), max: SIMD3<Float>(10, 10, 1))
        let (near, far) = camera(distance: 5).clipPlanes(sceneBounds: slab)

        #expect(near > 0 && near < far)
        // The sphere approximation collapsed near to the far * 1e-4 floor here, costing four
        // orders of magnitude of depth precision. The AABB distance is the true 4.0.
        #expect(abs(near - 4) < 1e-3, "near should be the box distance; got \(near)")
        #expect(far / near < 20, "ratio must stay conditioned; got \(far / near)")
    }

    @Test("Camera genuinely inside the geometry still falls back to the floor")
    func cameraInsideBoxUsesFloor() {
        let bounds = BoundingBox(min: SIMD3<Float>(-5, -5, -5), max: SIMD3<Float>(5, 5, 5))
        let (near, far) = camera(distance: 2).clipPlanes(sceneBounds: bounds)

        // distance(to:) is 0 inside the box, so the far * 1e-4 floor takes over.
        #expect(near > 0 && near < far)
        #expect(abs(near - far * 1e-4) < 1e-6)
    }
}
