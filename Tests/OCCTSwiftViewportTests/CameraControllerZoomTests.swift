import Testing
import simd

@testable import OCCTSwiftViewport

@Suite("Zoom-at-cursor pivot shift")
@MainActor
struct CameraControllerZoomTests {

    private func controller() -> CameraController {
        CameraController(
            initialState: CameraState(
                rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
                distance: 10,
                pivot: .zero
            )
        )
    }

    @Test("Zoom-at-cursor shifts the pivot by default")
    func shiftsPivotByDefault() {
        let camera = controller()
        #expect(camera.zoomTowardShiftsPivot)

        camera.zoomToward(factor: 2, cursorNormalized: SIMD2<Float>(0.5, 0.5), aspectRatio: 1.5)

        #expect(camera.cameraState.pivot != .zero)
        #expect(camera.cameraState.distance < 10)
    }

    @Test("Disabling the shift zooms without moving the pivot (issue #117)")
    func disabledLeavesPivotAlone() {
        let camera = controller()
        camera.zoomTowardShiftsPivot = false

        camera.zoomToward(factor: 2, cursorNormalized: SIMD2<Float>(0.5, 0.5), aspectRatio: 1.5)

        #expect(camera.cameraState.pivot == .zero)
        // The distance change is the part that must survive: only the drift is suppressed.
        #expect(camera.cameraState.distance < 10)
    }

    @Test("A centred cursor never shifts the pivot, either way")
    func centredCursorNeverShifts() {
        for shifts in [true, false] {
            let camera = controller()
            camera.zoomTowardShiftsPivot = shifts

            camera.zoomToward(factor: 2, cursorNormalized: .zero, aspectRatio: 1.5)

            #expect(camera.cameraState.pivot == .zero)
        }
    }

    @Test("ViewportController syncs the flag from dynamicPivotConfiguration.isEnabled")
    func viewportControllerSyncsFlag() {
        var enabled = ViewportConfiguration.cad
        enabled.dynamicPivotConfiguration = DynamicPivotConfiguration(isEnabled: true)
        #expect(ViewportController(configuration: enabled).cameraController.zoomTowardShiftsPivot)

        var disabled = ViewportConfiguration.cad
        disabled.dynamicPivotConfiguration = DynamicPivotConfiguration(isEnabled: false)
        #expect(!ViewportController(configuration: disabled).cameraController.zoomTowardShiftsPivot)
    }
}
