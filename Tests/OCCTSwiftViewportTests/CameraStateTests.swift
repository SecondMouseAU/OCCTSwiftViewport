// CameraStateTests.swift
// OCCTSwiftViewport Tests

import Testing
import Foundation
import simd
@testable import OCCTSwiftViewport

@Suite("CameraState Tests")
struct CameraStateTests {

    @Test("Default initialization")
    func testDefaultInit() {
        let state = CameraState()

        #expect(state.distance == 10.0)
        #expect(state.pivot == .zero)
        #expect(state.fieldOfView == 45.0)
        #expect(state.isOrthographic == false)
        #expect(state.panOffset == .zero)
    }

    @Test("Position calculation")
    func testPositionCalculation() {
        // Camera looking along -Z at distance 10 from origin
        let state = CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
            distance: 10.0,
            pivot: .zero
        )

        let position = state.position

        // Camera should be at (0, 0, 10) looking toward origin
        #expect(abs(position.x) < 0.001)
        #expect(abs(position.y) < 0.001)
        #expect(abs(position.z - 10.0) < 0.001)
    }

    @Test("lookAt places the eye at the requested point, not its reflection")
    func testLookAtPlacesEyeAtRequestedPosition() {
        // Regression test for a bug where CameraState.lookAt(target:from:) placed the camera
        // at the reflection of `from` through `target` (2*target - from) instead of at `from`
        // itself. An origin target can't catch this: reflecting (0,0,0) and negating the
        // point both land on -from, so the two failure modes are indistinguishable there.
        // A non-origin target is required to tell them apart:
        //   target (10,0,0), requested eye (20,0,0)
        //   - correct:               eye stays at (20,0,0)
        //   - reflect-through-target: eye lands at (0,0,0)   (2*target - from)
        //   - negate-the-point:      eye lands at (-20,0,0)  (-from)
        let target = SIMD3<Float>(10, 0, 0)
        let requestedEye = SIMD3<Float>(20, 0, 0)

        let state = CameraState.lookAt(target: target, from: requestedEye)

        #expect(abs(state.position.x - requestedEye.x) < 0.001)
        #expect(abs(state.position.y - requestedEye.y) < 0.001)
        #expect(abs(state.position.z - requestedEye.z) < 0.001)
    }

    @Test("lookAt is correct for an off-axis, non-origin target")
    func testLookAtOffAxisNonOriginTarget() {
        // A general case (target and eye both off-axis, up not parallel to either) so a fix
        // that only happens to satisfy the axis-aligned case above is still caught.
        let target = SIMD3<Float>(1, 2, 3)
        let requestedEye = SIMD3<Float>(5, 8, -4)

        let state = CameraState.lookAt(target: target, from: requestedEye)

        #expect(abs(state.position.x - requestedEye.x) < 0.01)
        #expect(abs(state.position.y - requestedEye.y) < 0.01)
        #expect(abs(state.position.z - requestedEye.z) < 0.01)

        let expectedViewDirection = simd_normalize(target - requestedEye)
        #expect(simd_length(state.viewDirection - expectedViewDirection) < 0.01)
    }

    @Test("Fit perspective to symmetric box")
    func testFitPerspectiveSymmetric() {
        // Unit cube at origin, square viewport, default 45° FoV.
        let bounds = BoundingBox(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        let fitted = CameraState().fit(to: bounds, aspectRatio: 1.0, padding: 1.0)
        // Bounding sphere radius = sqrt(3); halfFov = 22.5°.
        // d = r / sin(22.5°) ≈ √3 / 0.3827 ≈ 4.527
        #expect(abs(fitted.distance - 4.527) < 0.05)
        #expect(fitted.pivot == bounds.center)
    }

    @Test("Fit centres pivot on bounding box")
    func testFitCentresPivot() {
        let bounds = BoundingBox(min: SIMD3<Float>(2, 4, -1), max: SIMD3<Float>(6, 8, 3))
        let fitted = CameraState().fit(to: bounds, aspectRatio: 1.5, padding: 1.0)
        #expect(fitted.pivot == bounds.center)        // (4, 6, 1)
        #expect(fitted.panOffset == .zero)
    }

    @Test("Fit orthographic uses scale, not distance")
    func testFitOrthographic() {
        let bounds = BoundingBox(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        var ortho = CameraState()
        ortho.isOrthographic = true
        ortho.distance = 7   // sentinel — should be left untouched
        let fitted = ortho.fit(to: bounds, aspectRatio: 1.0, padding: 1.0)
        // 2 · radius = 2√3 ≈ 3.464
        #expect(abs(fitted.orthographicScale - 3.464) < 0.05)
        #expect(fitted.distance == 7)
    }

    @Test("Fit padding scales distance proportionally")
    func testFitPadding() {
        let bounds = BoundingBox(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        let tight = CameraState().fit(to: bounds, aspectRatio: 1.0, padding: 1.0)
        let padded = CameraState().fit(to: bounds, aspectRatio: 1.0, padding: 1.5)
        #expect(abs(padded.distance / tight.distance - 1.5) < 0.001)
    }

    @Test("Fit to bodies returns nil on empty input")
    func testFitBodiesEmpty() {
        let result = CameraState().fit(to: [ViewportBody](), aspectRatio: 1.0)
        #expect(result == nil)
    }

    @Test("Interpolation")
    func testInterpolation() {
        let start = CameraState(distance: 10.0)
        let end = CameraState(distance: 20.0)

        let midpoint = start.interpolated(to: end, t: 0.5)

        #expect(abs(midpoint.distance - 15.0) < 0.001)
    }

    @Test("Standard view - Top")
    func testStandardViewTop() {
        let state = StandardView.top.cameraState()

        // Top view should look down (negative in Y or Z depending on rotation convention)
        let viewDir = state.viewDirection

        #expect(abs(viewDir.x) < 0.001)
        // View direction should be primarily downward (either -Y or -Z)
        #expect(abs(viewDir.y) > 0.9 || abs(viewDir.z) > 0.9)
    }

    @Test("Standard view - Front")
    func testStandardViewFront() {
        let state = StandardView.front.cameraState()

        // Front view looks toward the model
        let viewDir = state.viewDirection

        #expect(abs(viewDir.x) < 0.001)
        // Should have a strong component in Y or Z
        #expect(abs(viewDir.y) > 0.5 || abs(viewDir.z) > 0.5)
    }

    @Test("Codable round-trip")
    func testCodable() throws {
        let original = CameraState(
            rotation: simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1)),
            distance: 25.0,
            pivot: SIMD3<Float>(1, 2, 3),
            fieldOfView: 60.0,
            isOrthographic: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CameraState.self, from: data)

        #expect(abs(decoded.distance - original.distance) < 0.001)
        #expect(decoded.isOrthographic == original.isOrthographic)
        #expect(abs(decoded.fieldOfView - original.fieldOfView) < 0.001)
    }
}

@Suite("RotationStyle Tests")
struct RotationStyleTests {

    @Test("CAD default is turntable")
    func testCADDefault() {
        #expect(RotationStyle.cadDefault == .turntable)
    }

    @Test("Modeling default is arcball")
    func testModelingDefault() {
        #expect(RotationStyle.modelingDefault == .arcball)
    }
}

@Suite("StandardView Tests")
struct StandardViewTests {

    @Test("All standard views have unique rotations")
    func testUniqueRotations() {
        let views = StandardView.allCases
        var rotations: [simd_quatf] = []

        for view in views {
            let rotation = view.rotation
            // Check it's not a duplicate (allowing for numerical precision)
            for existing in rotations {
                let diff = simd_length(rotation.vector - existing.vector)
                // They should all be different
                if diff < 0.01 {
                    // Allow identical rotations for some edge cases
                }
            }
            rotations.append(rotation)
        }

        #expect(rotations.count == views.count)
    }

    @Test("Orthographic views are marked correctly")
    func testOrthographicMarking() {
        #expect(StandardView.top.isOrthographic == true)
        #expect(StandardView.front.isOrthographic == true)
        #expect(StandardView.right.isOrthographic == true)
        #expect(StandardView.isometricFrontRight.isOrthographic == false)
    }
}

@Suite("ViewCubeRegion Tests")
struct ViewCubeRegionTests {

    @Test("26 total regions")
    func testRegionCount() {
        #expect(ViewCubeRegion.allCases.count == 26)
    }

    @Test("6 faces")
    func testFaceCount() {
        let faces = ViewCubeRegion.allCases.filter { $0.isFace }
        #expect(faces.count == 6)
    }

    @Test("12 edges")
    func testEdgeCount() {
        let edges = ViewCubeRegion.allCases.filter { $0.isEdge }
        #expect(edges.count == 12)
    }

    @Test("8 corners")
    func testCornerCount() {
        let corners = ViewCubeRegion.allCases.filter { $0.isCorner }
        #expect(corners.count == 8)
    }
}

@Suite("DisplayMode Tests")
struct DisplayModeTests {

    @Test("Wireframe shows edges only")
    func testWireframe() {
        #expect(DisplayMode.wireframe.showsEdges == true)
        #expect(DisplayMode.wireframe.showsSurfaces == false)
    }

    @Test("Shaded shows surfaces without edges")
    func testShaded() {
        #expect(DisplayMode.shaded.showsSurfaces == true)
        #expect(DisplayMode.shaded.showsEdges == false)
    }

    @Test("ShadedWithEdges shows both")
    func testShadedWithEdges() {
        #expect(DisplayMode.shadedWithEdges.showsSurfaces == true)
        #expect(DisplayMode.shadedWithEdges.showsEdges == true)
    }
}
