import Testing
import simd

@testable import OCCTSwiftViewport

/// The viewport is Z-up, so the ground plane is the XY plane and "below" means negative Z.
@Suite("ClipPlane Z-up ground plane and default")
struct ClipPlanePresetTests {

    /// True when the plane keeps `point`, i.e. the shader's discard test fails for it.
    private func keeps(_ plane: ClipPlane, _ point: SIMD3<Float>) -> Bool {
        simd_dot(plane.normal, point) + plane.distance >= 0
    }

    @Test("groundPlane is the Z = 0 plane and clips below it")
    func groundPlaneIsZUp() {
        let plane = ClipPlane.groundPlane
        #expect(plane.normal == SIMD3<Float>(0, 0, 1))
        #expect(plane.distance == 0)
        #expect(plane.isEnabled)
        #expect(keeps(plane, SIMD3(3, -4, 0.5)))
        #expect(!keeps(plane, SIMD3(3, 4, -0.5)))
        // Y no longer matters: a point below the old Y-up ground plane but above Z = 0 stays.
        #expect(keeps(plane, SIMD3(0, -10, 1)))
    }

    @Test("Default init clips below Z = 0, matching groundPlane")
    func defaultInitIsGroundPlane() {
        #expect(ClipPlane() == ClipPlane.groundPlane)
        #expect(ClipPlane(distance: -2).asFloat4 == SIMD4<Float>(0, 0, 1, -2))
        // A default plane lifted to Z = 2 keeps what is above it, whatever its Y.
        let raised = ClipPlane(distance: -2)
        #expect(keeps(raised, SIMD3(0, -50, 2.5)))
        #expect(!keeps(raised, SIMD3(0, 50, 1.5)))
    }
}
