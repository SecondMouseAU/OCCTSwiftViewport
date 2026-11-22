// HeightfieldLattice.swift
// OCCTSwiftViewport
//
// The `.wireframe` lattice of a heightfield (#254): the pitch of its lines, the uniforms and draw
// calls that put them on screen, and the main-pass loop both renderers share. The shaders are the
// "Heightfield lattice" section of Shaders.metal.

import Foundation
@preconcurrency import Metal
import simd

extension HeightfieldLayout {
    /// The coarsest lattice pitch, as a power of two of cells.
    ///
    /// 2^14 = 16,384 is past the longest side a field can have (`Heightfield.maximumDimension`),
    /// so a field seen from very far draws a line or two. The shader reads the level from 4 bits.
    static let maxLatticeLevel = 14

    /// The pitch, as a power of two of cells, of a tile's `.wireframe` lattice lines.
    ///
    /// The smallest power of two of cells that spans at least `latticePixels` on screen, but never
    /// finer than the tile's own mesh cell (`meshLevel`): there are no mesh edges between, so a
    /// line there would cut across triangles. Powers of two nest, so neighbouring tiles whose
    /// pitches differ by one level share every second line.
    static func latticeLevel(cellPixels: Float, latticePixels: Float, meshLevel: Int) -> Int {
        guard cellPixels > 0, latticePixels > 0 else { return maxLatticeLevel }
        let ratio = latticePixels / cellPixels
        let wanted = ratio <= 1 ? 0 : Int(log2(ratio).rounded(.up))
        return min(maxLatticeLevel, max(meshLevel, wanted))
    }
}

extension HeightfieldDrawSet {

    /// Whether `displayMode` draws (and picks) the field as a lattice.
    ///
    /// The modes that show edges but not surfaces do, which today is `.wireframe`. Every other
    /// mode draws the surface, or, for a heightfield, which has no edge geometry, nothing more.
    static func drawsLattice(in displayMode: DisplayMode) -> Bool {
        displayMode.showsEdges && !displayMode.showsSurfaces
    }

    /// The uniforms of a lattice draw: the edge configuration's width and dash pattern.
    ///
    /// With quad expansion off, whose native lines are one pixel wide and solid, so is the
    /// lattice. `width` overrides the configured width (a pick's footprint).
    static func latticeEdgeUniforms(
        uniforms: Uniforms, configuration: EdgeLineConfiguration, viewportSize: SIMD2<Float>,
        width: Float? = nil
    ) -> EdgeUniforms {
        var configuration = configuration
        if !configuration.useQuadExpansion {
            configuration.width = 1
            configuration.dashPattern = .solid
        }
        return EdgeUniforms(
            uniforms: uniforms, configuration: configuration, viewportSize: viewportSize,
            width: width)
    }

    /// Draws the planned tiles as the `.wireframe` lattice: the surface's triangles through the
    /// lattice pipeline, which keeps only the fragments on a line.
    ///
    /// `edgeUniforms` carries the edge configuration (width, dash), the clip planes and the body's
    /// `modelMatrix`; the caller sets the depth-stencil state and cull mode. With the lattice
    /// pick pipeline (`encodePick` of the pick pass) the same call stamps the lines' cells.
    func encodeLattice(
        encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
        edgeUniforms: inout EdgeUniforms, bodyUniforms: inout BodyUniforms
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
        encoder.setFragmentBytes(&edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
        encoder.setFragmentBytes(&bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
        encoder.setVertexTexture(heights, index: 0)
        encodeDraws(encoder: encoder, setFragmentParams: true)
    }

    /// Draws the lattice of every geometry-layer heightfield of `entries` into the main pass.
    ///
    /// Both renderers call this. The lines are tested against the depth already drawn (`depthState`,
    /// `.lessEqual` without writes) so a nearer opaque body hides them, and write none, so the lines
    /// of one field never knock each other out; the surface itself is not drawn.
    ///
    /// `objectIndex` gives the pick index a body's draw carries (the live renderer's draw-order
    /// ordinal; 0 offscreen, where the main pass never reads it), and `restoreDepthState` is the
    /// state the caller's next draw expects.
    @MainActor
    static func encodeLatticePass(
        encoder: MTLRenderCommandEncoder, entries: [HeightfieldRenderCache.Entry],
        pipeline: MTLRenderPipelineState, edgeConfiguration: EdgeLineConfiguration,
        viewportSize: SIMD2<Float>, makeUniforms: () -> Uniforms,
        depthState: MTLDepthStencilState, restoreDepthState: MTLDepthStencilState,
        objectIndex: (HeightfieldRenderCache.Entry) -> UInt32
    ) {
        for entry in entries where entry.body.renderLayer == .geometry {
            var uniforms = makeUniforms()
            uniforms.modelMatrix = entry.body.transform
            var edgeUniforms = latticeEdgeUniforms(
                uniforms: uniforms, configuration: edgeConfiguration, viewportSize: viewportSize)
            var bodyUniforms = BodyUniforms(
                body: entry.body, objectIndex: objectIndex(entry), isSelected: 0)
            encoder.setCullMode(.none)
            encoder.setDepthStencilState(depthState)
            entry.draw.encodeLattice(
                encoder: encoder, pipeline: pipeline, edgeUniforms: &edgeUniforms,
                bodyUniforms: &bodyUniforms)
        }
        encoder.setDepthStencilState(restoreDepthState)
    }
}
