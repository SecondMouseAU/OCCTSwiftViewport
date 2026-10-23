// TessellationManager.swift
// OCCTSwiftViewport
//
// Manages GPU hardware tessellation: PN triangle patch preprocessing,
// per-frame adaptive tessellation factor computation, and pipeline states.

@preconcurrency import Metal
import simd

/// Per-body tessellation buffers cached alongside BodyBuffers.
struct TessellationBuffers {
    let patchDataBuffer: MTLBuffer  // PNPatchData per patch
    let tessFactorBuffer: MTLBuffer  // MTLTriangleTessellationFactorsHalf per patch
    let patchCount: Int
}

/// Manages PN triangle tessellation compute pipelines and per-body patch data.
@MainActor
final class TessellationManager {

    private let device: MTLDevice
    private let pnPatchPipeline: MTLComputePipelineState
    private let tessFactorPipeline: MTLComputePipelineState

    /// Latches once the first tessellation diagnostic has been logged, so it prints per run
    /// rather than per frame.
    var didLogDiagnostic = false

    init?(device: MTLDevice, library: MTLLibrary) {
        self.device = device

        guard let pnFunc = library.makeFunction(name: "compute_pn_patches"),
            let tfFunc = library.makeFunction(name: "compute_tess_factors"),
            let pnPipeline = try? device.makeComputePipelineState(function: pnFunc),
            let tfPipeline = try? device.makeComputePipelineState(function: tfFunc)
        else {
            return nil
        }

        self.pnPatchPipeline = pnPipeline
        self.tessFactorPipeline = tfPipeline
    }

    /// Builds the PN-triangle control points a mesh needs before it can be tessellated.
    ///
    /// Runs once per geometry change, not per frame: the patch data depends only on the mesh,
    /// while the per-frame work is `updateTessFactors`. Needs only the mesh: B-Rep face indices
    /// play no part, so bodies without `faceIndices` (STL/OBJ imports, `Primitives`) are
    /// tessellated too (#161). Returns `nil` when there are no triangles or when any buffer
    /// allocation fails.
    ///
    /// - Parameters:
    ///   - vertexBuffer: Interleaved vertex buffer (stride 6 floats)
    ///   - indexBuffer: Triangle index buffer (UInt32)
    ///   - triangleCount: Number of triangles
    ///   - creaseAngle: Radians; an edge whose end normals differ by more stays flat (no PN
    ///     bulge). The renderers pass `normalSmoothingCreaseAngle`.
    ///   - commandQueue: Command queue for synchronous dispatch
    /// - Returns: TessellationBuffers with patch data and pre-allocated factor buffer
    func buildPatches(
        vertexBuffer: MTLBuffer,
        indexBuffer: MTLBuffer,
        triangleCount: Int,
        creaseAngle: Float,
        commandQueue: MTLCommandQueue
    ) -> TessellationBuffers? {
        guard triangleCount > 0 else { return nil }

        let patchBufferSize = triangleCount * Self.patchStride

        guard
            let patchBuffer = device.makeBuffer(
                length: patchBufferSize, options: .storageModeShared)
        else {
            return nil
        }

        // Tessellation factor buffer (pre-allocated, updated per-frame)
        // MTLTriangleTessellationFactorsHalf: 3 half edges + 1 half inside = 8 bytes.
        let factorStride = 8
        guard
            let factorBuffer = device.makeBuffer(
                length: triangleCount * factorStride,
                options: .storageModeShared
            )
        else { return nil }

        // Dispatch compute to build patches
        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
            let encoder = cmdBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(pnPatchPipeline)
        encoder.setBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setBuffer(indexBuffer, offset: 0, index: 1)
        encoder.setBuffer(patchBuffer, offset: 0, index: 2)

        var triCount = UInt32(triangleCount)
        encoder.setBytes(&triCount, length: MemoryLayout<UInt32>.size, index: 3)
        var creaseCos = Self.creaseCosine(creaseAngle)
        encoder.setBytes(&creaseCos, length: MemoryLayout<Float>.size, index: 4)

        let threadsPerGroup = min(pnPatchPipeline.maxTotalThreadsPerThreadgroup, 256)
        let threadgroups = (triangleCount + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(
            MTLSize(width: threadgroups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
        )
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        return TessellationBuffers(
            patchDataBuffer: patchBuffer,
            tessFactorBuffer: factorBuffer,
            patchCount: triangleCount
        )
    }

    /// Byte stride of one `PNPatchData` in Shaders.metal.
    ///
    /// 13 `packed_float3` control points and normals, 13 × 12 bytes. Must match the Metal struct.
    nonisolated static let patchStride = 156

    /// Cosine of a crease angle clamped to `0...π`; a non-finite angle uses the 30° default.
    nonisolated static func creaseCosine(_ angle: Float) -> Float {
        guard angle.isFinite else { return cos(Float.pi / 6) }
        return cos(min(max(angle, 0), .pi))
    }

    /// Clamps a requested tessellation factor to what a tessellated pipeline accepts.
    ///
    /// Metal caps `MTLRenderPipelineDescriptor.maxTessellationFactor` at 64, and the
    /// `.fractionalEven` partition mode these pipelines use requires an even value. A value
    /// outside those rules makes pipeline creation fail, which silently disables tessellation,
    /// so this clamps to `2...64` and rounds an odd value up to the next even one.
    nonisolated static func clampedMaxFactor(_ requested: Int) -> Int {
        let clamped = min(max(requested, 2), 64)
        return clamped.isMultiple(of: 2) ? clamped : clamped + 1
    }

    /// Target projected edge length, in pixels, for adaptive tessellation.
    nonisolated static let adaptiveTargetEdgePixels: Float = 4.0

    /// Builds the factor-kernel parameters for one body.
    ///
    /// The patch control points are in the body's local space, so the kernel projects them
    /// with `viewProjection * modelMatrix`; passing the body's real transform is what makes the
    /// screen-space factors right for moved or scaled bodies.
    ///
    /// - Parameters:
    ///   - modelMatrix: The body's local-to-world transform (`ViewportBody.transform`)
    ///   - viewProjection: Current camera view-projection matrix
    ///   - viewportSize: Viewport dimensions in pixels
    ///   - adaptive: `true` sizes factors by projected edge length and curvature; `false`
    ///     tessellates every patch uniformly at `maxFactor`
    ///   - maxFactor: Maximum (and, when not adaptive, the uniform) tessellation factor
    /// - Returns: The parameters bound at buffer index 2 of `compute_tess_factors`
    nonisolated static func factorParams(
        modelMatrix: simd_float4x4,
        viewProjection: simd_float4x4,
        viewportSize: SIMD2<Float>,
        adaptive: Bool,
        maxFactor: Float
    ) -> TessFactorParamsSwift {
        TessFactorParamsSwift(
            viewProjectionMatrix: viewProjection * modelMatrix,
            viewportSize: viewportSize,
            targetEdgePixels: adaptiveTargetEdgePixels,
            maxFactor: maxFactor,
            uniformFactor: adaptive ? 0 : maxFactor
        )
    }

    /// Recomputes how finely each visible body is subdivided for the current camera.
    ///
    /// Called once per frame, since the factors depend on projected edge length: `maxFactor`
    /// caps the subdivision so a body filling the screen cannot run away with the triangle
    /// budget. The caller owns the encoder's lifetime.
    ///
    /// - Parameters:
    ///   - tessBuffers: Array of (tessellation buffers, model matrix) for visible bodies
    ///   - viewProjectionMatrix: Current camera VP matrix
    ///   - viewportSize: Viewport dimensions in pixels
    ///   - adaptive: Adaptive (screen-space) or uniform tessellation, see `factorParams`
    ///   - maxFactor: Maximum tessellation factor
    ///   - encoder: Compute command encoder (caller manages begin/end)
    func updateTessFactors(
        tessBuffers: [(TessellationBuffers, simd_float4x4)],
        viewProjectionMatrix: simd_float4x4,
        viewportSize: SIMD2<Float>,
        adaptive: Bool,
        maxFactor: Float,
        encoder: MTLComputeCommandEncoder
    ) {
        encoder.setComputePipelineState(tessFactorPipeline)

        let shouldLog = !didLogDiagnostic
        if shouldLog { didLogDiagnostic = true }

        for (tess, modelMatrix) in tessBuffers {
            var params = Self.factorParams(
                modelMatrix: modelMatrix,
                viewProjection: viewProjectionMatrix,
                viewportSize: viewportSize,
                adaptive: adaptive,
                maxFactor: maxFactor
            )

            encoder.setBuffer(tess.patchDataBuffer, offset: 0, index: 0)
            encoder.setBuffer(tess.tessFactorBuffer, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<TessFactorParamsSwift>.stride, index: 2)

            var patchCount = UInt32(tess.patchCount)
            encoder.setBytes(&patchCount, length: MemoryLayout<UInt32>.size, index: 3)

            let threadsPerGroup = min(tessFactorPipeline.maxTotalThreadsPerThreadgroup, 256)
            let threadgroups = (tess.patchCount + threadsPerGroup - 1) / threadsPerGroup
            encoder.dispatchThreadgroups(
                MTLSize(width: threadgroups, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
            )
        }
    }
}

// Swift-side mirror of TessFactorParams (must match shader struct layout)
struct TessFactorParamsSwift {
    var viewProjectionMatrix: simd_float4x4
    var viewportSize: SIMD2<Float>
    var targetEdgePixels: Float
    var maxFactor: Float
    /// When > 0, every patch is tessellated uniformly at this factor (adaptive off).
    var uniformFactor: Float
    var _pad0: Float = 0
    var _pad1: Float = 0
    var _pad2: Float = 0
}
