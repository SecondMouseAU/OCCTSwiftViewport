// OrthographicFollowupTests.swift
// OCCTSwiftViewport Tests
//
// Issue #211: orthographic zoom walked the eye into the model, orthographic rays started at the
// eye, focusOn(point:distance:) did not zoom an orthographic camera, a measurement with one end
// behind the camera vanished, and a roll schedules no pivot update. Most checks project a point
// with the matrices and clip planes the renderer builds.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Orthographic, measurement and roll follow-ups (#211)")
struct OrthographicFollowupTests {

    // MARK: - Helpers

    /// A camera on +Z at `distance` from the origin, looking down -Z.
    private func camera(
        orthographic: Bool = true, distance: Float = 10, scale: Float = 10
    ) -> CameraState {
        CameraState(
            distance: distance, pivot: .zero, orthographicScale: scale,
            isOrthographic: orthographic)
    }

    /// A 4-unit box centred on the origin: its front face, toward +Z, is at z = 2.
    private var box: ViewportBody { .box(id: "b", width: 4, height: 4, depth: 4) }

    private var boxBounds: BoundingBox {
        BoundingBox(min: SIMD3(repeating: -2), max: SIMD3(repeating: 2))
    }

    /// The renderer's view-projection: clip planes fitted to `bounds`, as each frame does.
    private func viewProjection(_ state: CameraState, bounds: BoundingBox) -> simd_float4x4 {
        let clip = state.clipPlanes(sceneBounds: bounds)
        return state.projectionMatrix(aspectRatio: 1, near: clip.near, far: clip.far)
            * state.viewMatrix
    }

    /// Whether `point` lies inside the renderer's depth range (NDC z in 0...1).
    private func isDrawn(_ point: SIMD3<Float>, _ state: CameraState, bounds: BoundingBox) -> Bool {
        guard
            let ndc = ProjectionUtility.worldToNDC(
                point: point, vpMatrix: viewProjection(state, bounds: bounds))
        else { return false }
        return ndc.z >= 0 && ndc.z <= 1
    }

    private func corners(of b: BoundingBox) -> [SIMD3<Float>] {
        (0..<8).map { c in
            SIMD3(
                c & 1 == 0 ? b.min.x : b.max.x, c & 2 == 0 ? b.min.y : b.max.y,
                c & 4 == 0 ? b.min.z : b.max.z)
        }
    }

    // MARK: - 1. Orthographic zoom keeps the eye out of the model

    @Test("An orthographic zoom in changes the scale only, so the box's front is still drawn")
    func orthographicZoomKeepsEye() {
        let controller = CameraController(initialState: camera())
        let eye = controller.cameraState.position
        for _ in 0..<4 { controller.zoom(factor: 2) }

        let state = controller.cameraState
        #expect(abs(state.orthographicScale - 10.0 / 16) < 1e-4)
        #expect(state.distance == 10)
        #expect(simd_distance(state.position, eye) < 1e-5)
        // The front face, at z = 2: the eye walked to z = 0.625 used to cut it away.
        #expect(isDrawn(SIMD3(0.1, 0.1, 2), state, bounds: boxBounds))
    }

    @Test("A perspective zoom still changes the distance")
    func perspectiveZoomChangesDistance() {
        let controller = CameraController(initialState: camera(orthographic: false))
        controller.zoom(factor: 2)
        #expect(abs(controller.cameraState.distance - 5) < 1e-5)
        #expect(controller.cameraState.orthographicScale == 10)
    }

    @Test("placingOrthographicEye moves the eye in front of the bounds and keeps the picture")
    func placingKeepsPicture() {
        // Eye at z = 1, inside the box.
        let inside = camera(distance: 1, scale: 3)
        let placed = inside.placingOrthographicEye(inFrontOf: boxBounds)
        let radius = boxBounds.diagonalLength / 2
        #expect(
            CameraState.nearestDepth(
                of: boxBounds, from: placed.position, along: placed.viewDirection)
                >= radius - 1e-3)
        #expect(placed.pivot == inside.pivot && placed.rotation == inside.rotation)
        #expect(placed.orthographicScale == inside.orthographicScale)
        // Every corner is drawn, and lands where the unplaced camera put it across the view.
        let wide = inside.projectionMatrix(aspectRatio: 1, near: -100, far: 100) * inside.viewMatrix
        for corner in corners(of: boxBounds) {
            #expect(isDrawn(corner, placed, bounds: boxBounds), "corner \(corner)")
            let before = wide * SIMD4(corner, 1)
            let after = viewProjection(placed, bounds: boxBounds) * SIMD4(corner, 1)
            #expect(abs(before.x - after.x) < 1e-4 && abs(before.y - after.y) < 1e-4)
        }
        // Already in front, perspective, or no bounds: unchanged.
        #expect(
            camera(distance: 50).placingOrthographicEye(inFrontOf: boxBounds)
                == camera(distance: 50))
        #expect(
            camera(orthographic: false, distance: 1).placingOrthographicEye(inFrontOf: boxBounds)
                == camera(orthographic: false, distance: 1))
        #expect(inside.placingOrthographicEye(inFrontOf: nil) == inside)
    }

    @Test("With scene bounds, the controller keeps an orthographic eye in front through an orbit")
    func controllerKeepsEyeInFront() {
        let controller = CameraController(initialState: camera(distance: 3, scale: 3))
        controller.rotationStyle = .arcball
        let bounds = boxBounds
        controller.sceneBoundsProvider = { bounds }
        // Setting the provider already moved the eye at z = 3 back, out of reach of the box.
        let radius = bounds.diagonalLength / 2
        for step in 0..<12 {
            let state = controller.cameraState
            let nearest = CameraState.nearestDepth(
                of: bounds, from: state.position, along: state.viewDirection)
            #expect(nearest >= radius - 1e-3, "step \(step): nearest corner at depth \(nearest)")
            for corner in corners(of: bounds) {
                #expect(isDrawn(corner, state, bounds: bounds), "step \(step): \(corner)")
            }
            controller.orbit(deltaX: 40, deltaY: 25)
            controller.zoom(factor: 1.5)
        }
    }

    @Test("The orthographic grid spacing follows the scale, not the eye's distance")
    func orthographicGridFollowsScale() {
        func spacing(_ state: CameraState) -> Float {
            RendererSharedSetup.adaptiveGridSpacing(
                cameraState: state, baseSpacing: 1, subdivisions: 10)
        }
        // An orthographic zoom changes only the scale now, so the grid must read the scale.
        #expect(spacing(camera(distance: 10, scale: 1)) == spacing(camera(distance: 500, scale: 1)))
        #expect(spacing(camera(distance: 10, scale: 1)) < spacing(camera(distance: 10, scale: 100)))
        // The same height shown gives the same spacing in either projection.
        let persp = camera(orthographic: false, distance: 20)
        #expect(spacing(persp) == spacing(persp.matchingFraming(orthographic: true)))
    }

    @Test("fit(to:) in orthographic puts the eye in front of what it frames")
    func fitPlacesEye() {
        let fitted = camera(distance: 0.5).fit(to: boxBounds, aspectRatio: 1)
        for corner in corners(of: boxBounds) {
            #expect(isDrawn(corner, fitted, bounds: boxBounds), "corner \(corner)")
        }
    }

    @Test(
        "With scene bodies attached, a pivot update after an orthographic pan leaves the eye",
        arguments: [Float(0.5), 3])
    func pivotUpdateKeepsPlacedEye(zoomThreshold: Float) {
        var config = ViewportConfiguration()
        config.rotationStyle = .turntable
        var state = StandardView.isometricFrontRight.cameraState(distance: 2)
        state.isOrthographic = true
        state.orthographicScale = 7
        config.initialCameraState = state
        config.dynamicPivotConfiguration = DynamicPivotConfiguration(zoomThreshold: zoomThreshold)
        let vc = ViewportController(configuration: config)
        vc.updateViewportSize(CGSize(width: 800, height: 600))
        let scene = [box]
        vc.attachSceneBodies { scene }

        for _ in 0..<8 { vc.dispatch(.twoFingerPanChanged(translation: SIMD2(5, -3))) }
        vc.dispatch(.twoFingerPanEnded(velocity: .zero))
        for _ in 0..<60 where vc.cameraController.advance(by: 1.0 / 60) {}
        let released = vc.cameraState
        vc.updateDynamicPivot(bodies: scene)
        for _ in 0..<60 where vc.cameraController.advance(by: 1.0 / 60) {}

        #expect(simd_distance(vc.cameraState.position, released.position) < 1e-3)
        #expect(simd_dot(vc.cameraState.viewDirection, released.viewDirection) > 0.999999)
        #expect(simd_dot(vc.cameraState.upVector, released.upVector) > 0.999999)
        for corner in corners(of: boxBounds) {
            #expect(isDrawn(corner, vc.cameraState, bounds: boxBounds), "corner \(corner)")
        }
    }

    // MARK: - 2. Orthographic rays start in front of the scene

    @Test("An orthographic pivot raycast from an eye inside the box finds the front face")
    func orthographicPivotRayFromInside() throws {
        // Eye at z = 1, inside the box, zoomed in so the raycast branch runs.
        let pivot = try #require(
            PivotStrategy().computePivot(
                cameraState: camera(distance: 1, scale: 1), bodies: [box], aspectRatio: 1,
                config: .default))
        #expect(abs(pivot.z - 2) < 1e-3, "pivot \(pivot)")
    }

    @Test("Ray.fromCamera with scene bounds starts an orthographic ray in front of them")
    func rayStartsInFrontOfBounds() throws {
        let state = camera(distance: 1, scale: 4)
        let ray = Ray.fromCamera(
            ndc: SIMD2(0.5, -0.25), cameraState: state, aspectRatio: 1, sceneBounds: boxBounds)
        #expect(ray.origin.z > 2)
        // Still through the same point of the view.
        let atEye = Ray.fromCamera(ndc: SIMD2(0.5, -0.25), cameraState: state, aspectRatio: 1)
        #expect(
            abs(ray.origin.x - atEye.origin.x) < 1e-5 && abs(ray.origin.y - atEye.origin.y) < 1e-5)
        let hit = try #require(
            SceneRaycast.cast(ray: ray, bodies: [box], boundingBoxCache: ["b": boxBounds]))
        #expect(abs(hit.point.z - 2) < 1e-3)

        // Perspective rays start at the eye whatever the bounds.
        let persp = camera(orthographic: false, distance: 1)
        let perspRay = Ray.fromCamera(
            ndc: .zero, cameraState: persp, aspectRatio: 1, sceneBounds: boxBounds)
        #expect(simd_distance(perspRay.origin, persp.position) < 1e-6)
    }

    // MARK: - 3. focusOn zooms an orthographic camera

    @Test("focusOn(point:distance:) in orthographic sets the scale that distance shows")
    func orthographicFocusZooms() {
        let controller = CameraController(initialState: camera(distance: 10, scale: 10))
        controller.focusOn(point: SIMD3(1, 2, 0), distance: 4, animated: false)
        let state = controller.cameraState
        let expected = 2 * 4 * tan(state.fieldOfView * .pi / 360)
        #expect(abs(state.orthographicScale - expected) < 1e-4)
        #expect(state.pivot == SIMD3(1, 2, 0))
        #expect(state.distance == 10)

        let persp = CameraController(initialState: camera(orthographic: false))
        persp.focusOn(point: .zero, distance: 4, animated: false)
        #expect(persp.cameraState.distance == 4)
        #expect(persp.cameraState.orthographicScale == 10)
    }

    // MARK: - 4. A measurement with one end behind the camera is cut, not dropped

    @Test(
        "A segment with one end behind the camera is cut where it leaves the view",
        arguments: [true, false])
    func segmentIsClipped(orthographic: Bool) throws {
        let state = camera(orthographic: orthographic)
        let vp = state.projectionMatrix(aspectRatio: 1, near: 0.5, far: 100) * state.viewMatrix
        let size = CGSize(width: 400, height: 400)

        // Both ends in front: the plain projections.
        let front = try #require(
            ProjectionUtility.clippedSegmentToScreen(
                from: SIMD3(-1, 0, 0), to: SIMD3(1, 1, 0), vpMatrix: vp, viewportSize: size))
        #expect(front.startIsEndpoint && front.endIsEndpoint)
        #expect(
            front.end
                == ProjectionUtility.worldToScreen(
                    point: SIMD3(1, 1, 0), vpMatrix: vp, viewportSize: size))

        // The end at z = 20 is behind the eye at z = 10.
        let cut = try #require(
            ProjectionUtility.clippedSegmentToScreen(
                from: SIMD3(1, 1, 0), to: SIMD3(1, 1, 20), vpMatrix: vp, viewportSize: size))
        #expect(cut.startIsEndpoint && !cut.endIsEndpoint)
        #expect(cut.start.x.isFinite && cut.end.x.isFinite && cut.end.y.isFinite)
        if orthographic {
            // Cut at the near plane, z = 9.5; the line runs along the view, so it is one point.
            #expect(abs(cut.end.x - cut.start.x) < 1e-2 && abs(cut.end.y - cut.start.y) < 1e-2)
        } else {
            // Heads off away from the centre, as the line toward the eye does.
            #expect(cut.end.x > cut.start.x)
        }

        // Both ends behind: nothing.
        #expect(
            ProjectionUtility.clippedSegmentToScreen(
                from: SIMD3(0, 0, 15), to: SIMD3(1, 0, 20), vpMatrix: vp, viewportSize: size)
                == nil)
    }

    @Test("A headless distance measurement with one end behind the camera is still drawn")
    func compositorDrawsClippedMeasurement() throws {
        let width = 64
        let height = 64
        let base = try #require(Self.blackImage(width: width, height: height))
        let state = camera(scale: 8)
        let vp = state.projectionMatrix(aspectRatio: 1, near: 0.5, far: 100) * state.viewMatrix
        // From the left of the view to a point behind the eye at z = 10.
        let measurement = ViewportMeasurement.distance(
            DistanceMeasurement(start: SIMD3(-3, 0, 0), end: SIMD3(3, 0, 15)))
        let image = try #require(
            MeasurementCompositor.composite(
                baseImage: base, measurements: [measurement], viewProjection: vp,
                viewportSize: CGSize(width: width, height: height)))
        let pixels = Self.bgra(image)
        let lit = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 40 || pixels[$0 + 1] > 40 || pixels[$0 + 2] > 40
        }
        #expect(!lit.isEmpty, "the measurement was dropped")
    }

    private static func blackImage(width: Int, height: Int) -> CGImage? {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx?.makeImage()
    }

    private static func bgra(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }

    // MARK: - 5. A roll needs no pivot update

    @Test(
        "A roll leaves the dynamic pivot where it was", arguments: [false, true], [Float(0.5), 3])
    func rollKeepsPivot(orthographic: Bool, zoomThreshold: Float) throws {
        var state = StandardView.isometricFrontRight.cameraState(distance: 12)
        state.isOrthographic = orthographic
        state.orthographicScale = 7
        state.pivot = SIMD3(0.3, -0.2, 0.1)
        var body = box
        body.transform = simd_float4x4(
            columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0.4, -0.3, -1.5, 1)
            ))
        let config = DynamicPivotConfiguration(zoomThreshold: zoomThreshold)
        let before = try #require(
            PivotStrategy().computePivot(
                cameraState: state, bodies: [body], aspectRatio: 1, config: config))

        let controller = CameraController(initialState: state)
        controller.roll(deltaAngle: 0.7)
        let after = try #require(
            PivotStrategy().computePivot(
                cameraState: controller.cameraState, bodies: [body], aspectRatio: 1,
                config: config))
        #expect(simd_distance(before, after) < 1e-3, "before \(before), after \(after)")
    }
}
