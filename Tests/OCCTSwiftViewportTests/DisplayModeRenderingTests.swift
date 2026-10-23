// DisplayModeRenderingTests.swift
// OCCTSwiftViewport Tests
//
// Issue #136 (M2, L6): `.flat` and `.xray` used to render exactly like `.shaded` and
// `.shadedWithEdges`, and the pick pass stamped faces and edges the display mode hid. These tests
// pin the implemented behaviour in both renderers: `.flat` is faceted, `.xray` is see-through
// with edges, `.rendered` matches `.shaded`, and pick content follows what the mode shows.

import CoreGraphics
import Foundation
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Pure logic

@Suite("DisplayMode drawing rules")
struct DisplayModeRuleTests {

    @Test("Only .xray caps surface opacity, and only from above")
    func surfaceOpacity() {
        for mode in DisplayMode.allCases where mode != .xray {
            #expect(mode.surfaceOpacity(forMaterialOpacity: 1) == 1)
            #expect(mode.surfaceOpacity(forMaterialOpacity: 0.7) == 0.7)
        }
        let cap = DisplayMode.xraySurfaceOpacity
        #expect(cap > 0 && cap < 1)
        #expect(DisplayMode.xray.surfaceOpacity(forMaterialOpacity: 1) == cap)
        #expect(DisplayMode.xray.surfaceOpacity(forMaterialOpacity: cap / 2) == cap / 2)
    }

    @Test("Edges draw when the mode shows them, and always for an edge-only body")
    func drawsEdges() {
        for mode in DisplayMode.allCases {
            #expect(mode.drawsEdges(bodyHasMesh: false))
            #expect(mode.drawsEdges(bodyHasMesh: true) == mode.showsEdges)
        }
    }

    @Test("Uniforms pack the shading mode: 0 smooth, 1 unlit, 2 faceted; unlit wins")
    func shadingModePacking() {
        func packed(_ mode: DisplayMode) -> UInt32 {
            Uniforms(
                viewProjection: matrix_identity_float4x4, viewMatrix: matrix_identity_float4x4,
                cameraPosition: .zero, nearPlane: 0.1, farPlane: 100, lighting: .threePoint,
                lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
                shadowParams2: .zero, unlit: mode == .unlit,
                flatShading: !mode.usesSmoothShading
            ).unlit
        }
        #expect(packed(.flat) == 2)
        #expect(packed(.unlit) == 1)
        for mode in [DisplayMode.shaded, .shadedWithEdges, .xray, .rendered, .wireframe] {
            #expect(packed(mode) == 0)
        }
        let unlitAndFlat = Uniforms(
            viewProjection: matrix_identity_float4x4, viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero, nearPlane: 0.1, farPlane: 100, lighting: .threePoint,
            lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
            shadowParams2: .zero, unlit: true, flatShading: true)
        #expect(unlitAndFlat.unlit == 1)
    }
}

// MARK: - Shared scene helpers

enum DisplayModeScenes {

    /// Camera on +Z looking down -Z at the origin.
    static func camera() -> CameraState {
        CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10, pivot: .zero)
    }

    /// Lighting with shadows off, so per-pixel variation comes from normals only.
    static func noShadowLighting() -> LightingConfiguration {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        return lighting
    }

    /// A camera-facing quad at depth `z`, half-size `half`, with an optional horizontal edge
    /// across it, a little above the middle (off the pixel-row boundary at the image centre).
    static func panel(
        id: String, z: Float, half: Float, color: SIMD4<Float>, opacity: Float = 1,
        middleEdge: Bool = false
    ) -> ViewportBody {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, z, 0, 0, 1] }
        let verts = v(-half, -half) + v(half, -half) + v(half, half) + v(-half, half)
        let edges: [[SIMD3<Float>]] =
            middleEdge
            ? [[SIMD3<Float>(-half, 0.3, z + 0.01), SIMD3<Float>(half, 0.3, z + 0.01)]] : []
        var body = ViewportBody(
            id: id, vertexData: verts, indices: [0, 1, 2, 0, 2, 3], edges: edges, color: color)
        if opacity < 1 {
            body.material = PBRMaterial(
                baseColor: SIMD3<Float>(color.x, color.y, color.z), metallic: 0, roughness: 0.5,
                opacity: opacity)
        }
        return body
    }

    /// Red panel in front of a green panel, both covering the image centre.
    static func stackedPanels() -> [ViewportBody] {
        [
            panel(id: "front", z: 1, half: 2, color: SIMD4<Float>(0.9, 0.1, 0.1, 1)),
            panel(id: "back", z: -1, half: 3, color: SIMD4<Float>(0.1, 0.9, 0.1, 1)),
        ]
    }

    /// (r, g, b) at a pixel of a row-major BGRA buffer, 0–255.
    static func rgb(_ bgra: [UInt8], width: Int, x: Int, y: Int) -> SIMD3<Int> {
        let i = (y * width + x) * 4
        return SIMD3<Int>(Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i]))
    }

    /// Row-major BGRA bytes of a CGImage.
    static func bgra(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let info =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
            {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return buffer
    }

    /// A camera-facing quad whose vertex normals splay outward by about 40°, like a patch of a
    /// curved face: smooth shading varies across each triangle, face-normal shading doesn't.
    static func curvedPatch() -> ViewportBody {
        let half: Float = 3
        func v(_ x: Float, _ y: Float) -> [Float] {
            let n = simd_normalize(SIMD3<Float>(x * 0.85, y * 0.85, 1))
            return [x * half, y * half, 0, n.x, n.y, n.z]
        }
        let verts = v(-1, -1) + v(1, -1) + v(1, 1) + v(-1, 1)
        return ViewportBody(
            id: "patch", vertexData: verts, indices: [0, 1, 2, 0, 2, 3], edges: [],
            color: SIMD4<Float>(0.7, 0.7, 0.72, 1))
    }

    /// Largest channel difference between two pixels inside the patch's lower-right triangle
    /// (vertices 0, 1, 2), far apart from each other.
    static func patchTriangleSpread(_ bgra: [UInt8], size: Int) -> Int {
        let a = rgb(bgra, width: size, x: size * 78 / 100, y: size * 55 / 100)
        let b = rgb(bgra, width: size, x: size * 45 / 100, y: size * 78 / 100)
        return max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
    }

    /// A coarse sphere, for comparing whole renders.
    static func coarseSphere() -> ViewportBody {
        ViewportBody.sphere(
            id: "sphere", radius: 1.2, segments: 10, rings: 8,
            color: SIMD4<Float>(0.6, 0.6, 0.65, 1))
    }
}

// MARK: - OffscreenRenderer

@MainActor
@Suite("Display modes — OffscreenRenderer")
struct OffscreenDisplayModeTests {

    private let bg = SIMD4<Float>(0, 0, 0, 1)

    private func render(
        _ bodies: [ViewportBody], mode: DisplayMode, camera: CameraState, size: Int = 96
    ) -> [UInt8]? {
        guard let renderer = OffscreenRenderer() else { return nil }
        let options = OffscreenRenderOptions(
            width: size, height: size, cameraState: camera, displayMode: mode,
            lightingConfiguration: DisplayModeScenes.noShadowLighting(), backgroundColor: bg,
            msaaSampleCount: 1)
        return renderer.render(bodies: bodies, options: options).map(DisplayModeScenes.bgra)
    }

    @Test(".flat gives a near-constant colour across a curved face's triangle; .shaded doesn't")
    func flatIsFaceted() throws {
        let camera = DisplayModeScenes.camera()
        let patch = DisplayModeScenes.curvedPatch()
        guard let flat = render([patch], mode: .flat, camera: camera),
            let smooth = render([patch], mode: .shaded, camera: camera)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        // Only the per-pixel view vector still varies under a face normal.
        let flatSpread = DisplayModeScenes.patchTriangleSpread(flat, size: 96)
        let smoothSpread = DisplayModeScenes.patchTriangleSpread(smooth, size: 96)
        #expect(flatSpread <= 8, "flat should be constant across the triangle, Δ \(flatSpread)")
        #expect(
            smoothSpread > 3 * max(flatSpread, 5),
            "shaded should vary across the triangle: shaded Δ \(smoothSpread), flat Δ \(flatSpread)"
        )
    }

    @Test(".xray shows the body behind another; .shadedWithEdges doesn't")
    func xrayShowsHiddenBody() throws {
        let camera = DisplayModeScenes.camera()
        let bodies = DisplayModeScenes.stackedPanels()
        guard let xray = render(bodies, mode: .xray, camera: camera),
            let opaque = render(bodies, mode: .shadedWithEdges, camera: camera)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let x = DisplayModeScenes.rgb(xray, width: 96, x: 48, y: 48)
        let o = DisplayModeScenes.rgb(opaque, width: 96, x: 48, y: 48)
        // Opaque: the red front panel hides the green one. X-ray: green shows through.
        #expect(o.y < 60, "opaque centre should be red-dominated, got \(o)")
        #expect(
            x.y > o.y + 20, "x-ray centre should let the green back panel through: \(x) vs \(o)")
        #expect(x.x > 40, "x-ray centre should still carry the red front panel, got \(x)")
    }

    @Test("A translucent body keeps its edges in .shadedWithEdges, and .xray draws them")
    func translucentBodyKeepsEdges() throws {
        // Tilted: a head-on camera puts the near plane exactly on a flat panel's bounding box,
        // which would clip an edge lying just in front of it.
        var camera = DisplayModeScenes.camera()
        camera.rotation = simd_quatf(angle: 0.3, axis: SIMD3<Float>(1, 0, 0))
        func glass(edge: Bool) -> ViewportBody {
            DisplayModeScenes.panel(
                id: "glass", z: 0, half: 3, color: SIMD4<Float>(0.2, 0.4, 0.9, 1), opacity: 0.5,
                middleEdge: edge)
        }
        for mode in [DisplayMode.shadedWithEdges, .xray] {
            guard let with = render([glass(edge: true)], mode: mode, camera: camera),
                let without = render([glass(edge: false)], mode: mode, camera: camera)
            else {
                Issue.record("Metal device unavailable; skipping")
                return
            }
            // The edge is the only difference between the two renders.
            var maxDelta = 0
            for i in 0..<with.count where i % 4 != 3 {
                maxDelta = max(maxDelta, abs(Int(with[i]) - Int(without[i])))
            }
            #expect(maxDelta > 30, "\(mode): edge not drawn on translucent body (Δ \(maxDelta))")
        }
    }

    @Test(".rendered draws exactly like .shaded")
    func renderedMatchesShaded() throws {
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
        let bodies = [ViewportBody.box(id: "box"), DisplayModeScenes.coarseSphere()]
        guard let rendered = render(bodies, mode: .rendered, camera: camera),
            let shaded = render(bodies, mode: .shaded, camera: camera)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(rendered == shaded)
    }
}

// MARK: - ViewportRenderer (live draw path, headless)

@MainActor
@Suite("Display modes — ViewportRenderer")
struct LiveDisplayModeTests {

    static let size = 96

    /// Renders one frame and returns the pixels plus the renderer (kept for picking).
    private func render(
        _ bodies: [ViewportBody], mode: DisplayMode, camera: CameraState,
        selected: Set<String> = []
    ) -> (pixels: [UInt8], renderer: ViewportRenderer, controller: ViewportController)? {
        let controller = ViewportController(
            configuration: ViewportConfiguration(
                initialCameraState: camera,
                pickingConfiguration: PickingConfiguration(isEnabled: true)))
        controller.displayMode = mode
        controller.lightingConfiguration = DisplayModeScenes.noShadowLighting()
        controller.showGrid = false
        controller.showAxes = false
        controller.selectedBodyIDs = selected
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            let pixels = renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        else { return nil }
        return (pixels, renderer, controller)
    }

    private func pickAll(_ renderer: ViewportRenderer) async -> [PickResult] {
        let rect = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        return await withCheckedContinuation { continuation in
            renderer.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
    }

    @Test(".flat is faceted in the live renderer too")
    func flatIsFaceted() throws {
        let camera = DisplayModeScenes.camera()
        let patch = DisplayModeScenes.curvedPatch()
        guard let flat = render([patch], mode: .flat, camera: camera),
            let smooth = render([patch], mode: .shaded, camera: camera)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let flatSpread = DisplayModeScenes.patchTriangleSpread(flat.pixels, size: Self.size)
        let smoothSpread = DisplayModeScenes.patchTriangleSpread(smooth.pixels, size: Self.size)
        #expect(flatSpread <= 8, "flat should be constant across the triangle, Δ \(flatSpread)")
        #expect(
            smoothSpread > 3 * max(flatSpread, 5),
            "shaded should vary across the triangle: shaded Δ \(smoothSpread), flat Δ \(flatSpread)"
        )
    }

    @Test(".xray shows the body behind another in the live renderer")
    func xrayShowsHiddenBody() throws {
        let camera = DisplayModeScenes.camera()
        let bodies = DisplayModeScenes.stackedPanels()
        guard let xray = render(bodies, mode: .xray, camera: camera),
            let opaque = render(bodies, mode: .shadedWithEdges, camera: camera)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let x = DisplayModeScenes.rgb(xray.pixels, width: Self.size, x: 48, y: 48)
        let o = DisplayModeScenes.rgb(opaque.pixels, width: Self.size, x: 48, y: 48)
        #expect(
            x.y > o.y + 20, "x-ray centre should let the green back panel through: \(x) vs \(o)")
    }

    @Test(
        "A selected translucent body gets an outline ring, not a filled silhouette",
        arguments: [(DisplayMode.xray, Float(1)), (DisplayMode.shaded, Float(0.5))])
    func translucentSelectionIsOutlineNotFill(mode: DisplayMode, opacity: Float) throws {
        let camera = DisplayModeScenes.camera()
        let bodies = [
            DisplayModeScenes.panel(
                id: "p", z: 0, half: 2, color: SIMD4<Float>(0.9, 0.1, 0.1, 1), opacity: opacity)
        ]
        guard let selected = render(bodies, mode: mode, camera: camera, selected: ["p"]) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        // Without a stencil write in the translucent pass, the outline pass painted the whole
        // silhouette outline-blue; with it, the red body (lightly tinted) shows through.
        let s = DisplayModeScenes.rgb(selected.pixels, width: Self.size, x: 48, y: 48)
        #expect(s.x > s.z, "\(mode): selected translucent body filled with outline blue: \(s)")
    }

    // MARK: Picking follows the display mode (L6)

    /// A box whose 12 edges are edge-pickable.
    private func pickableBox() -> ViewportBody {
        var box = ViewportBody.box(id: "box", width: 2, height: 2, depth: 2)
        box.edgeIndices = (0..<Int32(box.edges.count)).map { $0 }
        return box
    }

    private func pickCamera() -> CameraState {
        var camera = CameraState(
            rotation: simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3<Float>(1, 1, 0))),
            distance: 8, pivot: .zero)
        camera.isOrthographic = false
        return camera
    }

    @Test(".wireframe stamps no faces into the pick buffer, only the visible edges")
    func wireframeHasNoFacePicks() async throws {
        guard let frame = render([pickableBox()], mode: .wireframe, camera: pickCamera()) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let kinds = Set(await pickAll(frame.renderer).map(\.kind))
        #expect(!kinds.contains(.face), "hidden faces are pickable in .wireframe")
        #expect(kinds.contains(.edge), "visible edges should stay pickable in .wireframe")
    }

    @Test(".shaded stamps no edges into the pick buffer, only the faces")
    func shadedHasNoEdgePicks() async throws {
        guard let frame = render([pickableBox()], mode: .shaded, camera: pickCamera()) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let kinds = Set(await pickAll(frame.renderer).map(\.kind))
        #expect(kinds.contains(.face))
        #expect(!kinds.contains(.edge), "hidden edges are pickable in .shaded")
    }

    @Test(".shadedWithEdges and .xray stamp both faces and edges")
    func edgeModesPickBoth() async throws {
        for mode in [DisplayMode.shadedWithEdges, .xray] {
            guard let frame = render([pickableBox()], mode: mode, camera: pickCamera()) else {
                Issue.record("Metal device unavailable; skipping")
                return
            }
            let kinds = Set(await pickAll(frame.renderer).map(\.kind))
            #expect(kinds.contains(.face), "\(mode): faces should be pickable")
            #expect(kinds.contains(.edge), "\(mode): edges should be pickable")
        }
    }
}
