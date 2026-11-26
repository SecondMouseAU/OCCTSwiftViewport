// HeightfieldLattice.swift
// OCCTSwiftViewport
//
// The lattice of a heightfield, drawn in `.wireframe` in place of its surface (#254) and in
// `.shadedWithEdges` over it (#263): the pitch of its lines, the uniforms and draw calls that put
// them on screen, and the main-pass loop both renderers share. The shaders are the "Heightfield
// lattice" section of Shaders.metal.

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
        guard ratio.isFinite else { return maxLatticeLevel }
        let wanted = ratio <= 1 ? 0 : Int(log2(ratio).rounded(.up))
        return min(maxLatticeLevel, max(meshLevel, wanted))
    }

    /// The lattice borders of the tile at column `tx`, row `ty`: one bit per edge (-X, +X, -Y, +Y,
    /// from bit 0) that is set when this tile draws a line on that border for its neighbour.
    ///
    /// A border is on a multiple of the tile size, so a tile with a pitch of 64 cells or more
    /// draws its lines on its borders, half of each in each of the two tiles that meet there. When
    /// the neighbour across a border draws a line there but this tile's coarser pitch does not
    /// reach it, that line would be drawn by the neighbour alone, half as wide as any other. The
    /// bit of that edge is then set, so this tile draws its half of the line too.
    ///
    /// `pitches` is every tile's pitch (`HeightfieldTileLevels.lattice`), row-major, culled tiles
    /// included: a neighbour that is not drawn is off screen or clipped away, with its half of the
    /// line, so this tile's half is drawn either way.
    static func latticeBorders(tx: Int, ty: Int, cols: Int, rows: Int, pitches: [UInt8]) -> UInt32 {
        let own = Int(pitches[ty * cols + tx])
        // A pitch of 64 cells or less divides every border, so this tile draws all of them.
        guard own > tileCells.trailingZeroBitCount else { return 0 }
        var borders: UInt32 = 0
        // Edges in the order the shader reads them: -X, +X, -Y, +Y.
        for (slot, (dx, dy)) in [(-1, 0), (1, 0), (0, -1), (0, 1)].enumerated() {
            let nx = tx + dx
            let ny = ty + dy
            guard nx >= 0, ny >= 0, nx < cols, ny < rows else { continue }
            // The border's grid position along the axis the edge is across.
            let border = (dx != 0 ? max(tx, nx) : max(ty, ny)) * tileCells
            let neighbour = Int(pitches[ny * cols + nx])
            if border % (1 << neighbour) == 0, border % (1 << own) != 0 { borders |= 1 << slot }
        }
        return borders
    }
}

extension HeightfieldDrawSet {

    /// Whether `displayMode` draws (and, unless the pick stamps every kind in every mode, picks)
    /// the field as a lattice in place of its surface.
    ///
    /// The modes that show edges but not surfaces do, which today is `.wireframe`. A mode that
    /// shows both draws the surface and, for a heightfield, which has no edge geometry, adds the
    /// lattice over it, see ``drawsLatticeOverSurface(in:)``.
    static func drawsLattice(in displayMode: DisplayMode) -> Bool {
        displayMode.showsEdges && !displayMode.showsSurfaces
    }

    /// Whether `displayMode` draws the lattice over the shaded surface, as a mesh's edges are.
    ///
    /// The modes that show both surfaces and edges, except `.xray`, whose surfaces write no depth
    /// for the lines to be hidden behind. Today that is `.shadedWithEdges` (#263).
    static func drawsLatticeOverSurface(in displayMode: DisplayMode) -> Bool {
        displayMode.showsEdges && displayMode.showsSurfaces && !displayMode.usesTransparency
    }

    /// Whether the frame's tile plan carries a lattice pitch: the lattice is drawn, in place of
    /// the surface or over it.
    static func plansLattice(in displayMode: DisplayMode) -> Bool {
        drawsLattice(in: displayMode) || drawsLatticeOverSurface(in: displayMode)
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
    /// of one field never knock each other out. The surface itself is not drawn here: in
    /// `.wireframe` it is not drawn at all, and in `.shadedWithEdges` (`HeightfieldPipelines.
    /// latticeOverSurface` as `pipeline`) the caller has drawn it, and it hides the lines behind a
    /// ridge.
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
