// UniformBufferSizeTests.swift
// OCCTSwiftViewport Tests
//
// The quad-edge pipelines bound 344 bytes of `EdgeUniforms` where `quad_edge_vertex` and
// `quad_edge_fragment` declare 352 (issue #231). Metal lays out a struct with 16-byte alignment, so
// its declared size is rounded up to a multiple of 16; Swift's `MemoryLayout.size` is not, and the
// encoders bind `.size` bytes. Metal's argument validation rejects a buffer shorter than the
// struct the function declares, so any edge draw aborted the process under `MTL_DEBUG_LAYER=1`;
// without the layer the shader read 8 bytes past the bound range, which is undefined behaviour that
// merely happens to work on current hardware.
//
// Three guards, because the abort only shows with API validation on, and that is an environment
// variable Metal reads when the process starts:
//
//  - the layout test pins `EdgeUniforms` at 352 bytes with size equal to stride.
//  - the reflection test builds the scene pipelines, asks Metal for the size each function declares
//    at its uniform buffers, and checks that what the renderers bind is at least that many bytes.
//    It does not depend on any struct keeping a particular size, so it keeps guarding the next
//    field someone appends on one side only.
//  - the render tests draw quad edges (plain, per-segment colour, picked) through both renderers.
//    CI runs the whole suite with `MTL_DEBUG_LAYER=1` (see .github/workflows/tests.yml), and so
//    can you:
//
//        MTL_DEBUG_LAYER=1 swift test --filter UniformBufferSizeTests

import Foundation
import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Bound uniform buffers cover the structs the shaders declare (#231)")
struct UniformBufferSizeTests {

    // MARK: - Layout

    @Test("EdgeUniforms is 352 bytes with size equal to stride, as the Metal struct is")
    func edgeUniformsLayout() {
        #expect(MemoryLayout<EdgeUniforms>.size == 352)
        #expect(MemoryLayout<EdgeUniforms>.stride == 352)
        #expect(MemoryLayout<EdgeUniforms>.alignment == 16)
        #expect(MemoryLayout<EdgeUniforms>.offset(of: \.edgeParams) == 240)
        #expect(MemoryLayout<EdgeUniforms>.offset(of: \.clipPlanes) == 256)
        #expect(MemoryLayout<EdgeUniforms>.offset(of: \.clipPlaneCount) == 320)
        #expect(MemoryLayout<EdgeUniforms>.offset(of: \.viewportSize) == 328)
        #expect(MemoryLayout<EdgeUniforms>.offset(of: \._pad2) == 344)
    }

    @Test("Every struct bound with setBytes has a size that is a multiple of its alignment")
    func boundStructsAreFullyPadded() {
        // `MemoryLayout.size` short of `stride` is the signature of #231: the Metal struct rounds
        // up to its alignment and Swift's `size` does not.
        #expect(MemoryLayout<EdgeUniforms>.size == MemoryLayout<EdgeUniforms>.stride)
        #expect(MemoryLayout<Uniforms>.size == MemoryLayout<Uniforms>.stride)
        #expect(MemoryLayout<BodyUniforms>.size == MemoryLayout<BodyUniforms>.stride)
        #expect(MemoryLayout<AxisUniforms>.size == MemoryLayout<AxisUniforms>.stride)
        #expect(MemoryLayout<ShadowUniformsSwift>.size == MemoryLayout<ShadowUniformsSwift>.stride)
    }

    // MARK: - Reflection

    private enum Stage { case vertex, fragment }

    /// One pipeline of the scene passes and the bytes the renderers bind at its uniform buffers.
    private struct Case {
        let label: String
        let vertex: String
        let fragment: String
        let colorFormat: MTLPixelFormat
        let vertexDescriptor: MTLVertexDescriptor
        /// (stage, buffer index, struct name, bytes the renderers bind there).
        let bound: [(Stage, Int, String, Int)]
    }

    private static func cases() -> [Case] {
        let scene = ("Uniforms", MemoryLayout<Uniforms>.size)
        let body = ("BodyUniforms", MemoryLayout<BodyUniforms>.size)
        let edge = ("EdgeUniforms", MemoryLayout<EdgeUniforms>.size)
        let shadow = ("ShadowUniforms", MemoryLayout<ShadowUniformsSwift>.size)
        let axis = ("AxisUniforms", MemoryLayout<AxisUniforms>.size)
        let mesh = RendererSharedSetup.interleavedVertexDescriptor()
        let quad = RendererSharedSetup.quadEdgeVertexDescriptor()

        func pair(_ stage: Stage, _ index: Int, _ s: (String, Int)) -> (Stage, Int, String, Int) {
            (stage, index, s.0, s.1)
        }
        func sceneAndBody(
            _ vertex: String, _ fragment: String, label: String, _ format: MTLPixelFormat
        )
            -> Case
        {
            Case(
                label: label, vertex: vertex, fragment: fragment, colorFormat: format,
                vertexDescriptor: mesh,
                bound: [
                    pair(.vertex, 1, scene), pair(.fragment, 1, scene), pair(.fragment, 2, body),
                ])
        }
        func quadEdge(_ fragment: String, label: String, _ format: MTLPixelFormat = .bgra8Unorm)
            -> Case
        {
            Case(
                label: label, vertex: "quad_edge_vertex", fragment: fragment, colorFormat: format,
                vertexDescriptor: quad,
                bound: [pair(.vertex, 1, edge), pair(.fragment, 1, edge), pair(.fragment, 2, body)])
        }
        return [
            quadEdge("quad_edge_fragment", label: "quad_edge"),
            quadEdge("quad_edge_segment_fragment", label: "quad_edge_segment"),
            quadEdge("pick_quad_edge_fragment", label: "pick_quad_edge", .r32Uint),
            sceneAndBody("shaded_vertex", "shaded_fragment", label: "shaded", .bgra8Unorm),
            sceneAndBody("wireframe_vertex", "wireframe_fragment", label: "wireframe", .bgra8Unorm),
            sceneAndBody(
                "wireframe_vertex", "wireframe_segment_fragment", label: "wireframe_segment",
                .bgra8Unorm),
            sceneAndBody("pick_vertex", "pick_fragment", label: "pick_shaded", .r32Uint),
            sceneAndBody("pick_line_vertex", "pick_line_fragment", label: "pick_line", .r32Uint),
            sceneAndBody("pick_line_vertex", "pick_arc_fragment", label: "pick_arc", .r32Uint),
            Case(
                label: "depth_only", vertex: "depth_only_vertex",
                fragment: "depth_only_clip_fragment",
                colorFormat: .invalid, vertexDescriptor: mesh,
                bound: [pair(.vertex, 1, scene), pair(.fragment, 1, scene)]),
            Case(
                label: "shadow_map", vertex: "shadow_vertex", fragment: "shadow_clip_fragment",
                colorFormat: .invalid, vertexDescriptor: mesh,
                bound: [pair(.vertex, 1, shadow), pair(.fragment, 1, scene)]),
            Case(
                label: "axis", vertex: "axis_vertex", fragment: "axis_fragment",
                colorFormat: .bgra8Unorm,
                vertexDescriptor: RendererSharedSetup.axisVertexDescriptor(),
                bound: [pair(.vertex, 1, axis)]),
        ]
    }

    /// The bytes a pipeline's function declares at one buffer slot, or `nil` if it declares none.
    private static func declaredSize(_ bindings: [any MTLBinding], at index: Int) -> Int? {
        bindings.lazy.compactMap { $0 as? MTLBufferBinding }.first { $0.index == index }?
            .bufferDataSize
    }

    @Test("Each scene pipeline binds at least the bytes its functions declare")
    func boundUniformsCoverTheDeclaredStructs() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let library = RendererSharedSetup.loadLibrary(device: device)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        for testCase in Self.cases() {
            let descriptor = RendererSharedSetup.renderPipelineDescriptor(
                label: testCase.label, library: library, vertexFunction: testCase.vertex,
                fragmentFunction: testCase.fragment, colorPixelFormat: testCase.colorFormat,
                depthPixelFormat: .depth32Float_stencil8,
                stencilPixelFormat: .depth32Float_stencil8,
                vertexDescriptor: testCase.vertexDescriptor)
            let (_, reflection) = try device.makeRenderPipelineState(
                descriptor: descriptor, options: [.bindingInfo])
            let bindings = try #require(reflection, "\(testCase.label): no reflection")
            for (stage, index, name, bytes) in testCase.bound {
                let declared = Self.declaredSize(
                    stage == .vertex ? bindings.vertexBindings : bindings.fragmentBindings,
                    at: index)
                let expected = try #require(
                    declared, "\(testCase.label): \(stage) function declares no buffer \(index)")
                #expect(
                    bytes >= expected,
                    "\(testCase.label): binds \(bytes) B of \(name) at \(stage) buffer \(index) where the function declares \(expected) B"
                )
            }
        }
    }

    @Test("The Swift EdgeUniforms size equals what the quad-edge functions declare")
    func edgeUniformsMatchesTheDeclaredStruct() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let library = RendererSharedSetup.loadLibrary(device: device)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        let descriptor = RendererSharedSetup.renderPipelineDescriptor(
            label: "quad_edge", library: library, vertexFunction: "quad_edge_vertex",
            fragmentFunction: "quad_edge_fragment", colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: .depth32Float_stencil8, stencilPixelFormat: .depth32Float_stencil8,
            vertexDescriptor: RendererSharedSetup.quadEdgeVertexDescriptor())
        let (_, reflection) = try device.makeRenderPipelineState(
            descriptor: descriptor, options: [.bindingInfo])
        let bindings = try #require(reflection)
        #expect(
            Self.declaredSize(bindings.vertexBindings, at: 1) == MemoryLayout<EdgeUniforms>.size)
        #expect(
            Self.declaredSize(bindings.fragmentBindings, at: 1) == MemoryLayout<EdgeUniforms>.size)
    }

    // MARK: - Rendering

    /// A horizontal edge-only body with one segment, so it draws through the quad-edge pipeline.
    private static func wire(segmentColor: Bool) -> ViewportBody {
        var body = ViewportBody(
            id: "wire", vertexData: [], indices: [],
            edges: [[SIMD3(-4, 0, 0), SIMD3(4, 0, 0)]], color: SIMD4(1, 1, 1, 1))
        body.edgeIndices = [0]  // makes the edge pickable
        if segmentColor { body.edgeColors = [SIMD4(1, 0.2, 0.2, 1)] }
        return body
    }

    private static let size = 128

    private static func isLit(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let i = (y * size + x) * 4
        return max(pixels[i], pixels[i + 1], pixels[i + 2]) > 100
    }

    @Test(
        "Quad edges render offscreen, plain and per-segment coloured, and under MTL_DEBUG_LAYER=1",
        arguments: [false, true])
    func offscreenQuadEdges(segmentColor: Bool) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        var options = ParityRender.options(displayMode: .shadedWithEdges)
        options.edgeLineConfiguration = EdgeLineConfiguration(width: 5)
        let image = try ParityRender.render(
            [Self.wire(segmentColor: segmentColor)], options, renderer: renderer)
        let row = Self.size / 2
        let lit = (0..<Self.size).filter { Self.isLit(image.pixels, x: $0, y: row) }.count
        #expect(lit > 60, "the quad edge drew \(lit) lit pixels along its row")
    }

    @Test("Quad edges render live and pick, under MTL_DEBUG_LAYER=1")
    func liveQuadEdgesAndPick() async throws {
        var config = ViewportConfiguration()
        config.initialCameraState = ParityRender.frontCamera
        config.edgeLineConfiguration = EdgeLineConfiguration(width: 9)
        config.backgroundColor = SIMD4(0, 0, 0, 1)
        config.pickingConfiguration = PickingConfiguration(isEnabled: true)
        let controller = ViewportController(configuration: config)
        controller.displayMode = .shadedWithEdges
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        for segmentColor in [false, true] {
            guard
                let live = ViewportRenderer(
                    controller: controller,
                    bodies: .constant([Self.wire(segmentColor: segmentColor)]))
            else {
                Issue.record("Metal device unavailable")
                return
            }
            let pixels = try #require(
                live.renderHeadlessBGRA(
                    width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1)))
            let row = Self.size / 2
            let lit = (0..<Self.size).filter { Self.isLit(pixels, x: $0, y: row) }.count
            #expect(lit > 60, "the quad edge drew \(lit) lit pixels along its row")

            let hit: PickResult? = await withCheckedContinuation { continuation in
                live.performPick(at: SIMD2(Self.size / 2 + 20, Self.size / 2 + 3)) {
                    continuation.resume(returning: $0)
                }
            }
            #expect(hit?.kind == .edge, "no edge pick through the quad-edge pick pipeline")
        }
    }
}
