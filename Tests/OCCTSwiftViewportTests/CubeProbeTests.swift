import Testing
import simd
import CoreGraphics
@testable import OCCTSwiftViewport

/// Regression for the "every cube click goes to top" bug: StandardView mixed a Y-up
/// front-is-identity convention with Z-axis yaws, so front/back/left/right all produced the SAME
/// −Z (top-down) look direction. The world is Z-UP (turntable orbits Z; cube top = +Z).
@Suite("StandardView orientations (Z-up)")
struct StandardViewOrientationTests {

    private func look(_ v: StandardView) -> SIMD3<Float> { v.rotation.act(SIMD3<Float>(0, 0, -1)) }

    @Test func sixFaceViewsLookAlongTheRightAxes() {
        #expect(simd_length(look(.top)    - SIMD3<Float>( 0,  0, -1)) < 1e-5)
        #expect(simd_length(look(.bottom) - SIMD3<Float>( 0,  0,  1)) < 1e-5)
        #expect(simd_length(look(.front)  - SIMD3<Float>( 0,  1,  0)) < 1e-5)
        #expect(simd_length(look(.back)   - SIMD3<Float>( 0, -1,  0)) < 1e-5)
        #expect(simd_length(look(.left)   - SIMD3<Float>( 1,  0,  0)) < 1e-5)
        #expect(simd_length(look(.right)  - SIMD3<Float>(-1,  0,  0)) < 1e-5)
    }

    @Test func allTenViewsAreDistinct() {
        let views: [StandardView] = [.top, .bottom, .front, .back, .left, .right,
                                     .isometricFrontRight, .isometricFrontLeft,
                                     .isometricBackRight, .isometricBackLeft]
        for i in views.indices {
            for j in views.indices where j > i {
                #expect(simd_length(look(views[i]) - look(views[j])) > 0.1,
                        "\(views[i]) and \(views[j]) coincide")
            }
        }
    }

    @Test func sideViewsKeepZUpHorizon() {
        for v: StandardView in [.front, .back, .left, .right] {
            let up = v.rotation.act(SIMD3<Float>(0, 1, 0))
            #expect(simd_length(up - SIMD3<Float>(0, 0, 1)) < 1e-5, "\(v) horizon tilted")
        }
    }

    @Test func cubeFaceCentresRoundTripAtIso() {
        let cube = NavigationCube(rotation: StandardView.isometricFrontRight.rotation, size: 84)
        let faces = cube.visibleFaces()
        #expect(faces.count == 3)   // a corner view shows exactly three faces
        for f in faces { #expect(cube.region(at: f.center) == f.region) }
    }
}
