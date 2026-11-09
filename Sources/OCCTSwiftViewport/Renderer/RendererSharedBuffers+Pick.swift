// RendererSharedBuffers+Pick.swift
// OCCTSwiftViewport
//
// The per-frame arc samples and the point-sprite vertices the GPU pick pass draws, built once for
// ViewportRenderer and OffscreenRenderer.

import Foundation
@preconcurrency import Metal
import simd

extension RendererSharedBuffers {

    /// One sampled arc of a frame: its vertex range in the frame's arc line vertices
    /// (`start`/`count`) and in its quad-strip vertices (`quadStart`/`quadCount`).
    struct SampledArcDraw {
        let body: ViewportBody
        /// The body's draw-order index, which its pick texels carry.
        let objectIndex: UInt32
        /// The arc's index in `body.arcs`, which an arc pick reports.
        let arcIndex: Int
        let start: Int
        let count: Int
        let quadStart: Int
        let quadCount: Int
    }

    /// A frame's arcs sampled to line segments, with the vertices to upload.
    struct SampledArcs {
        var draws: [SampledArcDraw] = []
        /// Native line vertices, 6 floats each (position, then a zeroed normal slot).
        var lineVertices: [Float] = []
        /// Quad-strip vertices, 9 floats each; empty unless quad expansion was asked for.
        var quadVertices: [Float] = []
    }

    /// Adaptively samples each body's `arcs` to line segments by their projected size, so
    /// circular feature edges stay smooth at any zoom independent of mesh density (#48).
    ///
    /// A body's arcs show under the edge pass's rule: when the display mode draws edges, or when
    /// the body has no mesh. Each arc becomes one draw, so the pick pass can stamp its index.
    ///
    /// - Parameters:
    ///   - bodies: The visible bodies in draw order, with their pick index and whether each has
    ///     a triangle mesh.
    ///   - displayMode: The frame's display mode.
    ///   - viewProjection: The frame's view-projection matrix.
    ///   - viewportSize: Render-target size in pixels.
    ///   - quadExpansion: Also expand the samples to quad strips (`EdgeLineConfiguration` width
    ///     and dashes).
    static func sampleArcs(
        bodies: [(body: ViewportBody, objectIndex: UInt32, hasMesh: Bool)],
        displayMode: DisplayMode,
        viewProjection: simd_float4x4,
        viewportSize: SIMD2<Float>,
        quadExpansion: Bool
    ) -> SampledArcs {
        var sampled = SampledArcs()
        for entry in bodies where !entry.body.arcs.isEmpty {
            guard displayMode.showsEdges || !entry.hasMesh else { continue }
            let mvp = viewProjection * entry.body.transform
            for (arcIndex, arc) in entry.body.arcs.enumerated() {
                let segments = ArcSampling.segmentCount(
                    arc: arc, mvp: mvp, viewportSize: viewportSize)
                let start = sampled.lineVertices.count / 6
                let points = sampledArcPolyline(arc, segmentCount: segments)
                for (previous, current) in zip(points, points.dropFirst()) {
                    sampled.lineVertices.append(contentsOf: [
                        previous.x, previous.y, previous.z, 0, 0, 0,
                        current.x, current.y, current.z, 0, 0, 0,
                    ])
                }
                let count = sampled.lineVertices.count / 6 - start
                let quadStart = sampled.quadVertices.count / 9
                if quadExpansion {
                    sampled.quadVertices += quadEdgeLineVertices(from: [points])
                }
                let quadCount = sampled.quadVertices.count / 9 - quadStart
                if count > 0 {
                    sampled.draws.append(
                        SampledArcDraw(
                            body: entry.body, objectIndex: entry.objectIndex, arcIndex: arcIndex,
                            start: start, count: count, quadStart: quadStart,
                            quadCount: quadCount))
                }
            }
        }
        return sampled
    }

    /// Uploads `vertices` as point-sprite pick vertices: position plus a zeroed normal, the
    /// stride of the mesh vertex buffer, so the interleaved pick vertex descriptor applies.
    ///
    /// - Returns: The buffer, or `nil` when `vertices` is empty.
    static func makePointPickBuffer(device: MTLDevice, vertices: [SIMD3<Float>]) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        var pointData: [Float] = []
        pointData.reserveCapacity(vertices.count * 6)
        for v in vertices {
            pointData.append(contentsOf: [v.x, v.y, v.z, 0, 0, 0])
        }
        return device.makeBuffer(
            bytes: pointData,
            length: pointData.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }
}
