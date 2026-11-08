// RendererVertexColors.swift
// OCCTSwiftViewport
//
// Per-vertex colours for mesh bodies (issue #142): the GPU buffer, and the state the shaded
// vertex stages need bound on every draw. Shared by ViewportRenderer and OffscreenRenderer.

@preconcurrency import Metal

// MARK: - Buffer

extension RendererSharedBuffers {

    /// Uploads a mesh body's per-vertex colours (stride 16) for the shaded pass, or `nil`.
    ///
    /// Returns `nil` when the body ignores its vertex colours (`vertexColorMode == .ignored`),
    /// has none, or has a count that doesn't match `vertexCount`, the shaded surface's vertex
    /// count. The shaded pass then uses the body colour, and never reads out of bounds.
    ///
    /// - Parameters:
    ///   - device: Device to allocate on.
    ///   - body: The body whose `vertexColors` and `vertexColorMode` are read.
    ///   - vertexCount: Vertices in the uploaded mesh (`MeshBuffers.vertexCount`).
    /// - Returns: The uploaded colours, or `nil` when the shaded pass should use the body colour.
    static func makeMeshColorBuffer(
        device: MTLDevice, body: ViewportBody, vertexCount: Int
    ) -> MTLBuffer? {
        guard body.vertexColorMode != .ignored else { return nil }
        return makePointColorBuffer(
            device: device, vertexColors: body.vertexColors, vertexCount: vertexCount)
    }
}

// MARK: - Colour space

extension AuthoredColorSpace {

    /// The value the point-cloud shader reads (`PointParams.vertexColorSpace`): 0 for sRGB display
    /// values, 1 for linear light.
    var shaderValue: UInt32 { self == .linear ? 1 : 0 }
}

// MARK: - Binding

extension RendererSharedSetup {

    /// The per-vertex colour state one shaded draw binds (issue #142).
    ///
    /// Every shaded vertex stage (`shaded_vertex`, `tessellated_vertex`, `meshlet_mesh`) takes the
    /// colour buffer and a mode word, so both are bound on every shaded draw. A body without usable
    /// colours binds mode 0 and a placeholder buffer, which the shader never reads.
    struct VertexColorBinding {
        /// Per-vertex RGBA (stride 16), or a placeholder that is never read when `mode` is 0.
        let colors: MTLBuffer
        /// The mode word the shader reads (see `packedMode`); 0 when the body has no usable colours.
        let mode: UInt32
        /// The body's triangle indices, read by the tessellated vertex stage.
        ///
        /// It takes each patch's three corners from them; patch `k` is triangle `k`.
        let indices: MTLBuffer

        /// The shader's mode word: bits 0 and 1 hold `VertexColorMode.rawValue` and bit 2 is set
        /// when the colours are linear light.
        ///
        /// Always 0 for `.ignored`, so a body that ignores its colours shades exactly as before
        /// whatever its colour space.
        ///
        /// - Parameters:
        ///   - mode: The body's `vertexColorMode`.
        ///   - space: The body's `vertexColorSpace`.
        /// - Returns: The mode word, 0 when the body ignores its vertex colours.
        static func packedMode(mode: VertexColorMode, space: AuthoredColorSpace) -> UInt32 {
            guard mode != .ignored else { return 0 }
            return mode.rawValue | (space == .linear ? 4 : 0)
        }

        /// - Parameters:
        ///   - mode: The body's `vertexColorMode`.
        ///   - space: The body's `vertexColorSpace`.
        ///   - colorBuffer: The uploaded colours, or `nil` when the body has none to use. Forces
        ///     the mode to ignored.
        ///   - placeholder: Any buffer, bound where there are no colours.
        ///   - indices: The body's triangle index buffer.
        init(
            mode: VertexColorMode, space: AuthoredColorSpace, colorBuffer: MTLBuffer?,
            placeholder: MTLBuffer, indices: MTLBuffer
        ) {
            self.colors = colorBuffer ?? placeholder
            self.mode = colorBuffer == nil ? 0 : Self.packedMode(mode: mode, space: space)
            self.indices = indices
        }
    }

    /// Vertex-stage buffer slot of the colours for `shaded_vertex` and `tessellated_vertex`.
    ///
    /// Slots 0 to 2 are taken by the vertex data, the scene uniforms and the direct-mesh normals.
    static let vertexColorBufferSlot = 3

    /// Vertex-stage slot of the mode word (a `uint`, set with `setVertexBytes`).
    static let vertexColorModeSlot = 4

    /// Binds the colour state for a `shaded_vertex` draw (standard and direct-mesh bodies).
    static func encodeVertexColors(
        encoder: MTLRenderCommandEncoder, binding: VertexColorBinding
    ) {
        var mode = binding.mode
        encoder.setVertexBuffer(binding.colors, offset: 0, index: vertexColorBufferSlot)
        encoder.setVertexBytes(&mode, length: MemoryLayout<UInt32>.size, index: vertexColorModeSlot)
    }
}
