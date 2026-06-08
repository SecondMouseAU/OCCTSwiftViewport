import Testing
import simd
import CoreGraphics
@testable import OCCTSwiftViewport

@Suite("Navigation cube geometry + hit-testing")
struct NavigationCubeTests {

    // MARK: - Region ↔ base faces

    @Test("Every region maps to the right number of base faces; lookup is complete")
    func baseFaceSets() {
        for r in ViewCubeRegion.allCases {
            let n = r.baseFaceSet.count
            if r.isFace { #expect(n == 1) }
            else if r.isEdge { #expect(n == 2) }
            else if r.isCorner { #expect(n == 3) }
        }
        // All 26 regions are reachable via their face set (no collisions).
        #expect(NavigationCube.regionLookup.count == ViewCubeRegion.allCases.count)
    }

    // MARK: - classify()

    @Test("Surface points classify into face / edge / corner")
    func classifyPoints() {
        #expect(NavigationCube.classify(SIMD3(0, 0, 1)) == .top)
        #expect(NavigationCube.classify(SIMD3(0, 0, -1)) == .bottom)
        #expect(NavigationCube.classify(SIMD3(1, 0, 0)) == .right)
        #expect(NavigationCube.classify(SIMD3(0, -1, 0)) == .front)
        // Edge: right + back.
        #expect(NavigationCube.classify(SIMD3(1, 0.5, 0)) == .backRight)
        // Corner: top + back + right.
        #expect(NavigationCube.classify(SIMD3(1, 1, 1)) == .topBackRight)
        // Front-left-top corner.
        #expect(NavigationCube.classify(SIMD3(-1, -1, 1)) == .topFrontLeft)
    }

    // MARK: - Cube ray intersection

    @Test("Ray through the centre hits the cube; a far-offset ray misses")
    func rayIntersection() {
        let hit = NavigationCube.intersectUnitCube(base: SIMD3(0, 0, 0), dir: SIMD3(0, 0, 1))
        #expect(hit != nil)
        let miss = NavigationCube.intersectUnitCube(base: SIMD3(5, 0, 0), dir: SIMD3(0, 0, 1))
        #expect(miss == nil)
    }

    // MARK: - End-to-end hit-test (identity rotation → looking at the top face)

    @Test("Identity rotation: taps resolve to the expected face/edge/corner")
    func identityHitTest() {
        let cube = NavigationCube(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), size: 80)
        let s = cube.scale
        let c = CGPoint(x: 40, y: 40)

        // Centre → the face we're looking at (top, given the convention).
        #expect(cube.region(at: c) == .top)
        // Right of centre → top-right edge.
        #expect(cube.region(at: CGPoint(x: c.x + CGFloat(0.6) * s, y: c.y)) == .topRight)
        // Up-right (screen y is down, so subtract) → top-back-right corner.
        #expect(cube.region(at: CGPoint(x: c.x + CGFloat(0.6) * s, y: c.y - CGFloat(0.6) * s)) == .topBackRight)
        // Down-left → top-front-left corner.
        #expect(cube.region(at: CGPoint(x: c.x - CGFloat(0.6) * s, y: c.y + CGFloat(0.6) * s)) == .topFrontLeft)
        // Far outside the silhouette → miss.
        #expect(cube.region(at: CGPoint(x: c.x + 10 * s, y: c.y)) == nil)
    }

    // MARK: - Visible faces

    @Test("At most three faces are visible and they front-face the camera")
    func visibleFaceCount() {
        // A generic tilt so three faces show.
        let rot = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))
        let cube = NavigationCube(rotation: rot, size: 80)
        let visible = cube.visibleFaces()
        #expect(visible.count >= 1 && visible.count <= 3)
        // Identity shows exactly one face (axis-aligned).
        let axisCube = NavigationCube(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), size: 80)
        #expect(axisCube.visibleFaces().count == 1)
        #expect(axisCube.visibleFaces().first?.region == .top)
    }
}
