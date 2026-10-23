// EdgeDashRenderingTests.swift
// OCCTSwiftViewport Tests
//
// Dash patterns on edge lines (issue #119). Headless render of a horizontal edge polyline,
// counting the lit runs along it: a solid line is one run, a dashed line is several. Covers both
// an edge-only body (wire / sketch), which the quad edge shader used to return from before the
// dash test so it always drew solid, and the edges of a meshed body.

import CoreGraphics
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Edge dash rendering")
struct EdgeDashRenderingTests {

    // Camera at +Z looking down -Z at the origin, orthographic so world units map evenly to pixels.
    private let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
        distance: 10,
        pivot: .zero,
        orthographicScale: 10,
        isOrthographic: true
    )

    private let line: [SIMD3<Float>] = [SIMD3(-4, 0, 0), SIMD3(4, 0, 0)]
    private let dashes = EdgeLineDashPattern(kind: .dashed, dashLength: 1, gapLength: 1)

    /// An edge-only body: no mesh, just the polyline.
    private func wire() -> ViewportBody {
        ViewportBody(
            id: "wire", vertexData: [], indices: [], edges: [line],
            color: SIMD4<Float>(1, 1, 1, 1))
    }

    /// A meshed body whose edge lies in front of its mesh.
    ///
    /// The small dark quad sits well away from the line, so the line's row is background except
    /// where the edge is drawn, and at z = -1, behind the line. Before issue #135 the near plane
    /// was fitted to the mesh alone and clipped the edge.
    private func meshedBody() -> ViewportBody {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, -1, 0, 0, 1] }
        let verts = v(-1, 3) + v(1, 3) + v(1, 4) + v(-1, 4)
        return ViewportBody(
            id: "meshed", vertexData: verts, indices: [0, 1, 2, 0, 2, 3], edges: [line],
            color: SIMD4<Float>(0.1, 0.1, 0.1, 1))
    }

    @Test("A solid edge-only line renders as one unbroken run")
    func solidWireIsOneRun() throws {
        let runs = try litRuns(body: wire(), pattern: .solid)
        #expect(runs == 1, "expected one run, got \(runs)")
    }

    @Test("A dashed pattern breaks an edge-only line into dashes")
    func dashedWireIsBroken() throws {
        // 8 world units of line at 1 on / 1 off is four dashes.
        let runs = try litRuns(body: wire(), pattern: dashes)
        #expect(runs >= 3, "expected several dashes on an edge-only body, got \(runs) run(s)")
    }

    @Test("A solid edge in front of its body's mesh is drawn, not near-clipped (#135)")
    func edgeInFrontOfMeshIsDrawn() throws {
        let runs = try litRuns(body: meshedBody(), pattern: .solid)
        #expect(runs == 1, "expected one run, got \(runs)")
    }

    @Test("A dashed pattern breaks the edges of a meshed body into dashes")
    func dashedMeshEdgeIsBroken() throws {
        let runs = try litRuns(body: meshedBody(), pattern: dashes)
        #expect(runs >= 3, "expected several dashes on a meshed body's edge, got \(runs) run(s)")
    }

    // MARK: - Helpers

    private struct RenderUnavailable: Error {}

    /// Renders `body` and counts the runs of lit pixels along the line's row.
    private func litRuns(body: ViewportBody, pattern: EdgeLineDashPattern) throws -> Int {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw RenderUnavailable()
        }
        let options = OffscreenRenderOptions(
            width: 128, height: 128, cameraState: camera,
            displayMode: .shadedWithEdges,
            backgroundColor: SIMD4<Float>(0, 0, 0, 1), appearance: .light, showGrid: false, showAxes: false,
            edgeLineConfiguration: EdgeLineConfiguration(width: 3, dashPattern: pattern))
        guard let image = renderer.render(bodies: [body], options: options) else {
            Issue.record("renderer returned nil image")
            throw RenderUnavailable()
        }

        let (buffer, width, height) = readBGRA(image)
        let row = height / 2
        var runs = 0
        var inRun = false
        for x in 0..<width {
            let i = (row * width + x) * 4
            let lit = max(buffer[i], buffer[i + 1], buffer[i + 2]) > 100
            if lit && !inRun { runs += 1 }
            inRun = lit
        }
        return runs
    }

    private func readBGRA(_ image: CGImage) -> ([UInt8], Int, Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return (buffer, width, height)
    }
}
