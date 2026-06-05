import Testing
import simd
@testable import OCCTSwiftViewport

@Suite("Analytic arc edges")
struct ViewportArcTests {

    private static let unitCircle = ViewportArc.circle(
        center: .zero, radius: 1,
        xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)
    )

    // MARK: - Arc evaluation

    @Test("point(at:) walks the circle from xAxis through yAxis")
    func pointEvaluation() {
        let c = Self.unitCircle
        let p0 = c.point(at: 0)
        let pQuarter = c.point(at: 0.25)
        let pHalf = c.point(at: 0.5)
        #expect(simd_length(p0 - SIMD3<Float>(1, 0, 0)) < 1e-5)
        #expect(simd_length(pQuarter - SIMD3<Float>(0, 1, 0)) < 1e-5)
        #expect(simd_length(pHalf - SIMD3<Float>(-1, 0, 0)) < 1e-5)
    }

    @Test("A full circle sweeps 2π")
    func fullCircleSweep() {
        #expect(abs(Self.unitCircle.sweep - 2 * .pi) < 1e-5)
    }

    // MARK: - Adaptive segment count

    @Test("Larger projected circles get more segments than smaller ones")
    func segmentCountScalesWithProjectedSize() {
        let vp = SIMD2<Float>(1000, 1000)
        let mvp = matrix_identity_float4x4  // local x/y → NDC directly, w = 1

        let big = ArcSampling.segmentCount(arc: Self.unitCircle, mvp: mvp, viewportSize: vp)
        let small = ArcSampling.segmentCount(
            arc: ViewportArc.circle(center: .zero, radius: 0.01,
                                    xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
            mvp: mvp, viewportSize: vp
        )
        #expect(big > small)
    }

    @Test("Segment count honours min and max clamps")
    func segmentCountClamps() {
        let vp = SIMD2<Float>(4000, 4000)
        // Huge projected circle → clamps to maxSegments.
        let capped = ArcSampling.segmentCount(
            arc: ViewportArc.circle(center: .zero, radius: 10,
                                    xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
            mvp: matrix_identity_float4x4, viewportSize: vp,
            maxSegments: 256
        )
        #expect(capped == 256)

        // Tiny projected circle → at least minSegments.
        let floored = ArcSampling.segmentCount(
            arc: ViewportArc.circle(center: .zero, radius: 0.0001,
                                    xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
            mvp: matrix_identity_float4x4, viewportSize: SIMD2(10, 10),
            minSegments: 6
        )
        #expect(floored >= 6)
    }

    @Test("Behind-camera arcs fall back to a high segment count, never zero")
    func behindCameraFallback() {
        var mvp = matrix_identity_float4x4
        mvp.columns.3 = SIMD4(0, 0, 0, -1)  // forces clip.w < 0 for all points
        let n = ArcSampling.segmentCount(arc: Self.unitCircle, mvp: mvp,
                                         viewportSize: SIMD2(1000, 1000), maxSegments: 512)
        #expect(n >= 6)
    }

    // MARK: - Body integration

    @Test("ViewportBody carries arcs; default is empty (source-compatible)")
    func bodyArcsField() {
        let plain = ViewportBody(id: "a", vertexData: [], indices: [], edges: [], color: .one)
        #expect(plain.arcs.isEmpty)

        let withArc = ViewportBody(id: "b", vertexData: [], indices: [], edges: [],
                                   arcs: [Self.unitCircle], color: .one)
        #expect(withArc.arcs.count == 1)
    }
}
