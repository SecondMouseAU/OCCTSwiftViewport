// TessellationSettingsTests.swift
// OCCTSwiftViewport Tests
//
// Tessellation factor inputs (body transform, adaptive vs uniform, max-factor clamp) and the
// meshlet vertex-data selection for the `.enhanced` / `.maximum` rendering paths (issue #136).

import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

@Suite("Tessellation settings")
struct TessellationSettingsTests {

    // MARK: - Max-factor clamp

    @Test("clampedMaxFactor keeps the factor in 2...64 and even")
    func clampedMaxFactor() {
        #expect(TessellationManager.clampedMaxFactor(-5) == 2)
        #expect(TessellationManager.clampedMaxFactor(0) == 2)
        #expect(TessellationManager.clampedMaxFactor(1) == 2)
        #expect(TessellationManager.clampedMaxFactor(16) == 16)
        #expect(TessellationManager.clampedMaxFactor(32) == 32)
        #expect(TessellationManager.clampedMaxFactor(33) == 34)
        #expect(TessellationManager.clampedMaxFactor(63) == 64)
        #expect(TessellationManager.clampedMaxFactor(64) == 64)
        #expect(TessellationManager.clampedMaxFactor(65) == 64)
        #expect(TessellationManager.clampedMaxFactor(1000) == 64)
    }

    @Test("Out-of-range or odd tessellationMaxFactor no longer disables tessellation")
    @MainActor
    func outOfRangeMaxFactorKeepsTessellation() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        for requested in [100, 33] {
            var config = ViewportConfiguration()
            config.renderingQuality = .enhanced
            config.tessellationMaxFactor = requested
            let controller = ViewportController(configuration: config)
            guard
                let renderer = ViewportRenderer(
                    controller: controller, bodies: .constant([]))
            else {
                Issue.record("renderer creation failed")
                return
            }
            #expect(renderer.tessellationEnabled, "tessellationMaxFactor = \(requested)")
        }
    }

    // MARK: - Factor-kernel parameters

    @Test("TessFactorParams matches the 96-byte Metal struct")
    func paramsLayout() {
        #expect(MemoryLayout<TessFactorParamsSwift>.size == 96)
        #expect(MemoryLayout<TessFactorParamsSwift>.stride == 96)
    }

    @Test("factorParams projects with viewProjection * modelMatrix")
    func factorParamsUsesModelMatrix() {
        var model = matrix_identity_float4x4
        model.columns.0.x = 3
        model.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        let vp = simd_float4x4(diagonal: SIMD4<Float>(0.5, 0.25, 1, 1))
        let params = TessellationManager.factorParams(
            modelMatrix: model, viewProjection: vp,
            viewportSize: SIMD2<Float>(800, 600), adaptive: true, maxFactor: 32)
        #expect(params.viewProjectionMatrix == vp * model)
        #expect(params.viewportSize == SIMD2<Float>(800, 600))
        #expect(params.maxFactor == 32)
    }

    @Test("adaptive = false requests uniform tessellation at the max factor")
    func uniformWhenNotAdaptive() {
        let adaptive = TessellationManager.factorParams(
            modelMatrix: matrix_identity_float4x4, viewProjection: matrix_identity_float4x4,
            viewportSize: SIMD2<Float>(100, 100), adaptive: true, maxFactor: 24)
        let uniform = TessellationManager.factorParams(
            modelMatrix: matrix_identity_float4x4, viewProjection: matrix_identity_float4x4,
            viewportSize: SIMD2<Float>(100, 100), adaptive: false, maxFactor: 24)
        #expect(adaptive.uniformFactor == 0)
        #expect(uniform.uniformFactor == 24)
        // The adaptive target no longer changes with the flag.
        #expect(adaptive.targetEdgePixels == uniform.targetEdgePixels)
    }

    // MARK: - Renderer: transform reaches the factor kernel

    /// Renders `body` once at `.enhanced` and returns the renderer's factor batch plus the
    /// computed edge factors of every patch.
    @MainActor
    private static func renderFactors(
        body: ViewportBody, camera: CameraState, adaptive: Bool = true, maxFactor: Int = 32
    ) -> (batch: [(TessellationBuffers, simd_float4x4)], factors: [Float])? {
        var config = ViewportConfiguration()
        config.renderingQuality = .enhanced
        config.adaptiveTessellation = adaptive
        config.tessellationMaxFactor = maxFactor
        config.initialCameraState = camera
        let controller = ViewportController(configuration: config)
        controller.showGrid = false
        controller.showAxes = false
        guard
            let renderer = ViewportRenderer(controller: controller, bodies: .constant([body])),
            renderer.tessellationEnabled,
            renderer.renderHeadlessBGRA(
                width: 160, height: 120, backgroundColor: SIMD4<Float>(0, 0, 0, 1)) != nil
        else { return nil }
        let batch = renderer.tessellationFactorBatch(for: [body]).batch
        guard let tess = batch.first?.0 else { return (batch, []) }
        let halves = tess.tessFactorBuffer.contents().bindMemory(
            to: Float16.self, capacity: tess.patchCount * 4)
        var factors: [Float] = []
        for p in 0..<tess.patchCount {
            for e in 0..<3 { factors.append(Float(halves[p * 4 + e])) }
        }
        return (batch, factors)
    }

    private static func fixedCamera() -> CameraState {
        var camera = CameraState()
        camera.pivot = .zero
        camera.distance = 4
        return camera
    }

    @Test("Factor batch carries each body's transform, not identity")
    @MainActor
    func batchCarriesBodyTransform() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var body = ViewportBody.sphere(id: "s", radius: 0.5, color: SIMD4<Float>(1, 1, 1, 1))
        var transform = matrix_identity_float4x4
        transform.columns.0.x = 0.25
        transform.columns.1.y = 0.25
        transform.columns.2.z = 0.25
        transform.columns.3 = SIMD4<Float>(0.3, -0.2, 0.1, 1)
        body.transform = transform
        guard let result = Self.renderFactors(body: body, camera: Self.fixedCamera()) else {
            Issue.record("headless tessellated render failed")
            return
        }
        #expect(result.batch.count == 1)
        #expect(result.batch.first?.1 == transform)
    }

    @Test("A scaled-down body gets smaller adaptive tessellation factors")
    @MainActor
    func scaledBodyGetsSmallerFactors() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let base = ViewportBody.box(
            id: "b", width: 1, height: 1, depth: 1, color: SIMD4<Float>(1, 1, 1, 1))
        var scaled = base
        scaled.transform = simd_float4x4(diagonal: SIMD4<Float>(0.1, 0.1, 0.1, 1))
        let camera = Self.fixedCamera()
        guard let full = Self.renderFactors(body: base, camera: camera),
            let small = Self.renderFactors(body: scaled, camera: camera),
            !full.factors.isEmpty, full.factors.count == small.factors.count
        else {
            Issue.record("headless tessellated render failed")
            return
        }
        let fullSum = full.factors.reduce(0, +)
        let smallSum = small.factors.reduce(0, +)
        #expect(smallSum < fullSum * 0.5, "full \(fullSum) vs scaled \(smallSum)")
    }

    @Test("adaptiveTessellation = false tessellates every patch at the max factor")
    @MainActor
    func uniformFactorsOnGPU() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let body = ViewportBody.box(
            id: "b", width: 1, height: 1, depth: 1, color: SIMD4<Float>(1, 1, 1, 1))
        guard
            let result = Self.renderFactors(
                body: body, camera: Self.fixedCamera(), adaptive: false, maxFactor: 8),
            !result.factors.isEmpty
        else {
            Issue.record("headless tessellated render failed")
            return
        }
        #expect(result.factors.allSatisfy { $0 == 8 }, "factors: \(Set(result.factors))")
    }

    // MARK: - Meshlet source data

    @Test("Meshlets are built from the auto-smoothed data when smoothing ran")
    func meshletSourcePrefersSmoothed() {
        let body = ViewportBody.box(
            id: "b", width: 1, height: 1, depth: 1, color: SIMD4<Float>(1, 1, 1, 1))
        var smoothed = body.vertexData
        smoothed[3] = 0.123
        #expect(
            ViewportRenderer.meshletSourceVertexData(for: body, smoothedVertexData: smoothed)
                == smoothed)
        #expect(
            ViewportRenderer.meshletSourceVertexData(for: body, smoothedVertexData: nil)
                == body.vertexData)
    }

    @Test("Direct-mesh and triangle-less bodies get no meshlets")
    func meshletSourceSkipsDirectAndEmpty() {
        let direct = ViewportBody.directMesh(
            id: "d", positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            indices: [0, 1, 2], color: SIMD4<Float>(1, 1, 1, 1))
        #expect(
            ViewportRenderer.meshletSourceVertexData(for: direct, smoothedVertexData: nil) == nil)
        let edgeOnly = ViewportBody(
            id: "e", vertexData: [], indices: [], edges: [[.zero, SIMD3<Float>(1, 0, 0)]],
            color: SIMD4<Float>(1, 1, 1, 1))
        #expect(
            ViewportRenderer.meshletSourceVertexData(for: edgeOnly, smoothedVertexData: nil) == nil)
    }

    /// Counts non-background pixels of `body` rendered at `quality`.
    @MainActor
    private static func coverage(_ body: ViewportBody, quality: RenderingQuality) -> Int? {
        var config = ViewportConfiguration()
        config.renderingQuality = quality
        config.initialCameraState = fixedCamera()
        let controller = ViewportController(configuration: config)
        controller.showGrid = false
        controller.showAxes = false
        guard
            let renderer = ViewportRenderer(controller: controller, bodies: .constant([body])),
            let pixels = renderer.renderHeadlessBGRA(
                width: 160, height: 120, backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        else { return nil }
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4)
        where pixels[i] > 10 || pixels[i + 1] > 10 || pixels[i + 2] > 10 {
            count += 1
        }
        return count
    }

    @Test(".maximum draws a rotated, single-sided cap like .standard (meshlet culling)")
    @MainActor
    func meshShaderCullingHonoursTransform() {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple9) else {
            return
        }
        // The -Z cap of a sphere: a narrow normal cone facing away from the camera in local
        // space, rotated 180 degrees so it faces the camera in world space.
        let sphere = ViewportBody.sphere(id: "s", radius: 1.5, color: SIMD4<Float>(1, 1, 1, 1))
        var capIndices: [UInt32] = []
        for k in stride(from: 0, to: sphere.indices.count, by: 3) {
            let tri = sphere.indices[k..<k + 3]
            if tri.allSatisfy({ sphere.vertexData[Int($0) * 6 + 5] < -0.8 }) {
                capIndices.append(contentsOf: tri)
            }
        }
        var cap = ViewportBody(
            id: "cap", vertexData: sphere.vertexData, indices: capIndices, edges: [],
            faceIndices: [Int32](repeating: 0, count: capIndices.count / 3),
            color: SIMD4<Float>(1, 1, 1, 1))
        for transform in [
            matrix_identity_float4x4,
            simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))),
        ] {
            cap.transform = transform
            guard let standard = Self.coverage(cap, quality: .standard),
                let maximum = Self.coverage(cap, quality: .maximum)
            else {
                Issue.record("headless render failed")
                return
            }
            #expect(standard > 0)
            #expect(maximum == standard, "standard \(standard) vs maximum \(maximum)")
        }
    }

    @Test(".maximum with autoSmoothNormals renders through the mesh-shader path")
    @MainActor
    func maximumRendersWithSmoothing() {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple9) else {
            return
        }
        var config = ViewportConfiguration()
        config.renderingQuality = .maximum
        config.autoSmoothNormals = true
        config.initialCameraState = Self.fixedCamera()
        let controller = ViewportController(configuration: config)
        let body = ViewportBody.sphere(id: "s", radius: 0.5, color: SIMD4<Float>(1, 1, 1, 1))
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant([body]))
        else {
            Issue.record("renderer creation failed")
            return
        }
        #expect(renderer.meshShadersEnabled)
        let pixels = renderer.renderHeadlessBGRA(
            width: 160, height: 120, backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        #expect(pixels != nil)
    }
}
