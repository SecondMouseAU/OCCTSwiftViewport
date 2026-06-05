import Testing
import simd
@testable import OCCTSwiftViewport

@Suite("HUD overlay logic")
struct HUDOverlayTests {

    // MARK: - CameraState.worldUnitsPerPoint

    @Test("Orthographic scale is depth-independent and divides by viewport height")
    func orthographicScale() {
        var cs = CameraState()
        cs.isOrthographic = true
        cs.orthographicScale = 20  // 20 world units span the full height
        // 20 units over 100 points → 0.2 units/point
        #expect(abs(cs.worldUnitsPerPoint(viewportHeightPoints: 100) - 0.2) < 1e-6)
        // Distance must not matter in ortho.
        cs.distance = 999
        #expect(abs(cs.worldUnitsPerPoint(viewportHeightPoints: 100) - 0.2) < 1e-6)
    }

    @Test("Perspective scale uses 2*distance*tan(fov/2) over height")
    func perspectiveScale() {
        var cs = CameraState()
        cs.isOrthographic = false
        cs.fieldOfView = 90      // tan(45°) = 1
        cs.distance = 10         // visible height = 2 * 10 * 1 = 20
        let wpp = cs.worldUnitsPerPoint(viewportHeightPoints: 200)
        #expect(abs(wpp - (20.0 / 200.0)) < 1e-5)  // 0.1
    }

    @Test("Degenerate viewport height yields zero")
    func degenerateHeight() {
        let cs = CameraState()
        #expect(cs.worldUnitsPerPoint(viewportHeightPoints: 0) == 0)
        #expect(cs.worldUnitsPerPoint(viewportHeightPoints: -5) == 0)
    }

    // MARK: - ScaleBarMetrics.niceNumber

    @Test("niceNumber snaps to 1/2/5 x 10^n")
    func niceNumbers() {
        #expect(ScaleBarMetrics.niceNumber(1.0) == 1)
        #expect(ScaleBarMetrics.niceNumber(1.2) == 1)
        #expect(ScaleBarMetrics.niceNumber(1.6) == 2)
        #expect(ScaleBarMetrics.niceNumber(3.0) == 2)
        #expect(ScaleBarMetrics.niceNumber(4.0) == 5)
        #expect(ScaleBarMetrics.niceNumber(8.0) == 10)
        #expect(ScaleBarMetrics.niceNumber(40.0) == 50)
        #expect(ScaleBarMetrics.niceNumber(230.0) == 200)
        #expect(abs(ScaleBarMetrics.niceNumber(0.04) - 0.05) < 1e-6)
    }

    @Test("niceNumber rejects non-positive / non-finite")
    func niceNumberGuards() {
        #expect(ScaleBarMetrics.niceNumber(0) == 0)
        #expect(ScaleBarMetrics.niceNumber(-3) == 0)
        #expect(ScaleBarMetrics.niceNumber(.nan) == 0)
        #expect(ScaleBarMetrics.niceNumber(.infinity) == 0)
    }

    // MARK: - ScaleBarMetrics

    @Test("Metrics snap world length and recompute point length")
    func metrics() {
        // 0.1 units/point, target 100 points → target world 10 → nice 10.
        let m = ScaleBarMetrics(worldUnitsPerPoint: 0.1, targetPoints: 100)
        #expect(m != nil)
        #expect(m?.worldLength == 10)
        // 10 world / 0.1 per point = 100 points exactly.
        #expect(abs((m?.pointLength ?? 0) - 100) < 1e-6)
        #expect(m?.label == "10")
    }

    @Test("Unit label is appended; sub-unit lengths format with trimmed decimals")
    func labelFormatting() {
        // 0.004 units/point, target 100 → target world 0.4 → nice 0.5.
        let m = ScaleBarMetrics(worldUnitsPerPoint: 0.004, targetPoints: 100, unitLabel: "mm")
        #expect(m?.worldLength == 0.5)
        #expect(m?.label == "0.5 mm")
    }

    @Test("Metrics reject degenerate scale")
    func metricsGuards() {
        #expect(ScaleBarMetrics(worldUnitsPerPoint: 0, targetPoints: 100) == nil)
        #expect(ScaleBarMetrics(worldUnitsPerPoint: .nan, targetPoints: 100) == nil)
        #expect(ScaleBarMetrics(worldUnitsPerPoint: 0.1, targetPoints: 0) == nil)
    }

    // MARK: - OrientationGnomon projection

    @Test("Identity rotation maps +X right, +Y up (screen y flipped), +Z toward viewer")
    func gnomonIdentity() {
        let axes = OrientationGnomon.projectedAxes(rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)))
        let byLabel = Dictionary(uniqueKeysWithValues: axes.map { ($0.label, $0) })
        #expect(abs((byLabel["X"]?.direction.width ?? 0) - 1) < 1e-5)
        #expect(abs(byLabel["X"]?.direction.height ?? 9) < 1e-5)
        // +Y world is up → screen y negative.
        #expect(abs((byLabel["Y"]?.direction.height ?? 0) - (-1)) < 1e-5)
        #expect(abs(byLabel["Y"]?.direction.width ?? 9) < 1e-5)
        #expect(axes.count == 3)
    }

    @Test("Axes are sorted back-to-front by depth")
    func gnomonDepthSorted() {
        // A tilted rotation so the three depths differ.
        let q = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))
        let axes = OrientationGnomon.projectedAxes(rotation: q)
        for i in 1..<axes.count {
            #expect(axes[i - 1].depth <= axes[i].depth)
        }
    }
}
