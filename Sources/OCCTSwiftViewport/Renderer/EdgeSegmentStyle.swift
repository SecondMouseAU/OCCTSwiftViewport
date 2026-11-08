// EdgeSegmentStyle.swift
// OCCTSwiftViewport
//
// Per-segment edge colour and visible range (`ViewportBody.edgeColors`, `edgeDrawRange`; #140),
// shared by ViewportRenderer and OffscreenRenderer.

import Foundation
@preconcurrency import Metal
import simd

/// Resolves and uploads a body's per-segment edge style.
///
/// Neither field touches the edge vertex buffers. The visible range becomes a `vertexStart` /
/// `vertexCount` slice of the existing buffer (the segments are laid out in order, a constant
/// number of vertices each), and the colours are a separate buffer one `SIMD4<Float>` per
/// segment, read in the fragment stage by `[[primitive_id]]`. So scrubbing the range uploads
/// nothing, and recolouring re-uploads only the 16 bytes per segment.
enum EdgeSegmentStyle {

    /// Vertices per segment in the native line buffer (`MTLPrimitiveType.line`).
    static let nativeVerticesPerSegment = 2
    /// Vertices per segment in the quad-strip buffer (four corners and two strip breaks).
    static let quadVerticesPerSegment = 6

    /// The segments to draw: `requested` clamped to `0..<segmentCount`, or all of them for `nil`.
    ///
    /// A range that lies wholly outside the segments, or an empty one, resolves to an empty range
    /// (nothing drawn); one that overhangs the end is cut at the last segment.
    static func drawnRange(_ requested: Range<Int>?, segmentCount: Int) -> Range<Int> {
        let count = max(segmentCount, 0)
        guard let requested else { return 0..<count }
        let lower = min(max(requested.lowerBound, 0), count)
        let upper = min(max(requested.upperBound, lower), count)
        return lower..<upper
    }

    /// Whether `colorCount` colours are drawn for a body with `segmentCount` segments.
    ///
    /// Only a non-empty array with exactly one colour per segment is used; any other count falls
    /// back to the body colour, the rule `vertexColors` follows for points.
    static func colorsMatch(colorCount: Int, segmentCount: Int) -> Bool {
        colorCount > 0 && colorCount == segmentCount
    }

    /// The `drawPrimitives` vertex slice of the native line buffer for `segments`.
    static func nativeVertexSlice(_ segments: Range<Int>) -> (start: Int, count: Int) {
        (segments.lowerBound * nativeVerticesPerSegment, segments.count * nativeVerticesPerSegment)
    }

    /// The `drawPrimitives` vertex slice of the quad-strip buffer for `segments`.
    ///
    /// A strip restarted at a segment boundary is still correct: each segment opens with a
    /// repeated vertex, so the triangles joining it to the previous one are degenerate anyway.
    static func quadVertexSlice(_ segments: Range<Int>) -> (start: Int, count: Int) {
        (segments.lowerBound * quadVerticesPerSegment, segments.count * quadVerticesPerSegment)
    }

    /// Uploads `colors` as one RGBA per segment, or returns `nil` when they cannot be used.
    ///
    /// `nil` when empty or when the count does not match `segmentCount` (the shader would read
    /// out of bounds); the edge pass then draws in the body colour.
    static func makeColorBuffer(
        device: MTLDevice, colors: [SIMD4<Float>], segmentCount: Int
    ) -> MTLBuffer? {
        guard colorsMatch(colorCount: colors.count, segmentCount: segmentCount) else { return nil }
        return colors.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
    }

    /// Binds what the `*_segment_fragment` shaders read: the colours at fragment buffer 3, and at
    /// buffer 4 the index of the draw's first segment and the colour space (0 sRGB, 1 linear).
    static func bindColors(
        _ encoder: MTLRenderCommandEncoder, colors: MTLBuffer, firstSegment: Int,
        colorSpace: AuthoredColorSpace
    ) {
        var params = SIMD2<UInt32>(UInt32(truncatingIfNeeded: firstSegment), colorSpace.shaderCode)
        encoder.setFragmentBuffer(colors, offset: 0, index: 3)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD2<UInt32>>.size, index: 4)
    }

    /// Sets the pipeline for an edge draw: `segmentVariant` bound to `colors` when the body has
    /// usable per-segment colours and the variant exists, otherwise the `plain` body-colour one.
    static func setPipeline(
        _ encoder: MTLRenderCommandEncoder,
        plain: MTLRenderPipelineState,
        segmentVariant: MTLRenderPipelineState?,
        colors: MTLBuffer?,
        firstSegment: Int,
        colorSpace: AuthoredColorSpace
    ) {
        if let segmentVariant, let colors {
            encoder.setRenderPipelineState(segmentVariant)
            bindColors(
                encoder, colors: colors, firstSegment: firstSegment, colorSpace: colorSpace)
        } else {
            encoder.setRenderPipelineState(plain)
        }
    }
}

extension AuthoredColorSpace {

    /// The value the segment shaders read for this space: 0 = sRGB, 1 = linear.
    var shaderCode: UInt32 {
        switch self {
        case .sRGB: 0
        case .linear: 1
        }
    }
}
