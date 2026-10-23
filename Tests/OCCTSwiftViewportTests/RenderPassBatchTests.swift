// RenderPassBatchTests.swift
// OCCTSwiftViewport Tests
//
// Regression tests for the overlay, translucent, highlight, outline and tessellation passes:
// #170 (overlay layer), #171 (highlights on translucent bodies), #177 (outline over occluders),
// #187 (translucent surfaces punched holes in the image alpha) and #161 (silent quality
// fallbacks). Each scene is rendered by both the live renderer (headless) and
// `OffscreenRenderer` wherever the behaviour exists in both.

import CoreGraphics
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Shared scene helpers

@MainActor
enum PassScene {

    static let size = 128

    /// Lighting with shadows and SSAO off, so pixel values depend only on what is tested.
    static var plainLighting: LightingConfiguration { ParityRender.plainLighting }

    /// Renders `bodies` through `OffscreenRenderer` with the front orthographic camera.
    static func offscreen(
        _ bodies: [ViewportBody],
        mode: DisplayMode = .shaded,
        lighting: LightingConfiguration = plainLighting,
        selected: Set<String> = [],
        outline: SelectionOutlineStyle? = nil
    ) -> (pixels: [UInt8], image: CGImage)? {
        guard let renderer = OffscreenRenderer() else { return nil }
        var options = ParityRender.options(displayMode: mode)
        options.lightingConfiguration = lighting
        options.selectedBodyIDs = selected
        if let outline { options.selectionOutline = outline }
        guard let image = renderer.render(bodies: bodies, options: options) else { return nil }
        return (ParityRender.bgra(image).0, image)
    }

    /// Renders `bodies` through the live renderer, headless, with the front orthographic camera.
    static func live(
        _ bodies: [ViewportBody],
        mode: DisplayMode = .shaded,
        lighting: LightingConfiguration = plainLighting,
        selected: Set<String> = [],
        outline: SelectionOutlineStyle? = nil
    ) -> (pixels: [UInt8], renderer: ViewportRenderer)? {
        var config = ViewportConfiguration(
            initialCameraState: ParityRender.frontCamera, displayMode: mode,
            lightingConfiguration: lighting, showGrid: false,
            backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false,
            pickingConfiguration: PickingConfiguration(isEnabled: true))
        if let outline { config.selectionOutline = outline }
        let controller = ViewportController(configuration: config)
        controller.showAxes = false
        controller.selectedBodyIDs = selected
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            let pixels = renderer.renderHeadlessBGRA(
                width: size, height: size, backgroundColor: SIMD4(0, 0, 0, 1))
        else { return nil }
        return (pixels, renderer)
    }

    /// Every pick hit over the whole frame the renderer last drew.
    static func pickAll(_ renderer: ViewportRenderer) async -> [PickResult] {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return await withCheckedContinuation { continuation in
            renderer.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
    }

    static func rgb(_ pixels: [UInt8], x: Int, y: Int) -> SIMD3<Int> {
        ParityRender.rgb(pixels, width: size, x: x, y: y)
    }

    static func count(_ pixels: [UInt8], where match: (SIMD3<Int>) -> Bool) -> Int {
        ParityRender.count(pixels, width: size, height: size, where: match)
    }

    /// An edge-only overlay body: a square polyline of half-size `half` in the plane `z`.
    static func overlayRing(id: String, half: Float, z: Float, color: SIMD4<Float>) -> ViewportBody
    {
        let corners: [SIMD3<Float>] = [
            SIMD3(-half, -half, z), SIMD3(half, -half, z), SIMD3(half, half, z),
            SIMD3(-half, half, z), SIMD3(-half, -half, z),
        ]
        return ViewportBody(
            id: id, vertexData: [], indices: [], edges: [corners], color: color,
            renderLayer: .overlay)
    }

    /// An overlay body with no mesh and one analytic circle of `radius` in the plane `z`.
    static func overlayCircle(id: String, radius: Float, z: Float, color: SIMD4<Float>)
        -> ViewportBody
    {
        ViewportBody(
            id: id, vertexData: [], indices: [], edges: [],
            arcs: [
                .circle(
                    center: SIMD3(0, 0, z), radius: radius, xAxis: SIMD3(1, 0, 0),
                    yAxis: SIMD3(0, 1, 0))
            ],
            color: color, renderLayer: .overlay)
    }

    /// Opaque blue panel at `z` covering the whole view.
    static func bluePanel(z: Float) -> ViewportBody {
        ParityRender.quad(id: "panel", x0: -8, y0: -8, x1: 8, y1: 8, z: z, color: SIMD4(0, 0, 1, 1))
    }

    static func isRed(_ c: SIMD3<Int>) -> Bool { c.x > 120 && c.x > c.z + 60 && c.x > c.y + 60 }
}

// MARK: - #170 Overlay layer

@Suite("Overlay layer (#170)")
@MainActor
struct OverlayLayerTests {

    private func overlayQuad() -> ViewportBody {
        var quad = ParityRender.quad(
            id: "gizmo", x0: -2, y0: -2, x1: 2, y1: 2, z: 0, color: SIMD4(0, 1, 0, 1))
        quad.renderLayer = .overlay
        return quad
    }

    @Test("Overlay surfaces still draw in .wireframe, in both renderers")
    func overlaySurfacesDrawInWireframe() throws {
        guard let live = PassScene.live([overlayQuad()], mode: .wireframe),
            let offscreen = PassScene.offscreen([overlayQuad()], mode: .wireframe)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        let green: (SIMD3<Int>) -> Bool = { $0.y > 100 && $0.y > $0.x + 40 }
        #expect(PassScene.count(live.pixels, where: green) > 200, "live hid the gizmo")
        #expect(PassScene.count(offscreen.pixels, where: green) > 200, "offscreen hid the gizmo")
    }

    @Test("A .wireframe overlay surface wins the pick, as it is drawn")
    func overlaySurfacePickedInWireframe() async throws {
        let panel = PassScene.bluePanel(z: 2)
        guard let live = PassScene.live([panel, overlayQuad()], mode: .wireframe) else {
            Issue.record("Metal device unavailable")
            return
        }
        let hits = await PassScene.pickAll(live.renderer)
        #expect(hits.contains { $0.bodyID == "gizmo" && $0.kind == .face })
    }

    @Test("Overlay arcs draw on top of nearer geometry, in both renderers")
    func overlayArcsDrawOnTop() throws {
        let bodies = [
            PassScene.bluePanel(z: 2),
            PassScene.overlayCircle(id: "ring", radius: 3, z: -2, color: SIMD4(1, 0, 0, 1)),
        ]
        guard let live = PassScene.live(bodies), let offscreen = PassScene.offscreen(bodies)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(
            PassScene.count(live.pixels, where: PassScene.isRed) > 20,
            "live depth-tested the overlay arc")
        #expect(
            PassScene.count(offscreen.pixels, where: PassScene.isRed) > 20,
            "offscreen depth-tested the overlay arc")
    }

    @Test("Overlay edges and arcs win picks over nearer geometry, without edgeIndices")
    func overlayEdgesAndArcsArePickable() async throws {
        let bodies = [
            PassScene.bluePanel(z: 2),
            PassScene.overlayRing(id: "square", half: 4, z: -2, color: SIMD4(1, 1, 0, 1)),
            PassScene.overlayCircle(id: "circle", radius: 2, z: -2, color: SIMD4(1, 0, 0, 1)),
        ]
        guard let live = PassScene.live(bodies) else {
            Issue.record("Metal device unavailable")
            return
        }
        let hits = await PassScene.pickAll(live.renderer)
        #expect(hits.contains { $0.bodyID == "square" && $0.kind == .edge })
        #expect(hits.contains { $0.bodyID == "circle" && $0.kind == .edge })
    }

    @Test("Only in-view overlays widen the near/far fit")
    func clipFitTakesInViewOverlaysOnly() {
        let camera = ParityRender.frontCamera
        let view = RendererSharedSetup.wideViewFrustum(cameraState: camera, aspectRatio: 1)
        let model = BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, -0.9))
        var near = overlayQuad()
        near.transform.columns.3 = SIMD4(0, 0, 4, 1)
        var offScreen = overlayQuad()
        offScreen.transform.columns.3 = SIMD4(300, 0, 300, 1)
        let widened = RendererSharedSetup.clipFitBounds(
            model, includingOverlaysOf: [near], in: view)
        let untouched = RendererSharedSetup.clipFitBounds(
            model, includingOverlaysOf: [offScreen], in: view)
        #expect(widened?.max.z == 4, "an in-view gizmo in front of the model must widen the fit")
        #expect(untouched == model, "an off-screen gizmo must not stretch the fit")
    }

    @Test("Scene geometry casts no shadow onto an overlay surface, in both renderers")
    func overlaySurfacesReceiveNoShadows() throws {
        var lighting = ParityRender.plainLighting
        lighting.shadowsEnabled = true
        lighting.shadowIntensity = 1
        // A caster between the key light and the gizmo, and a receiver behind it, so the shadow
        // map's frustum (fitted to geometry only) covers the gizmo.
        let toLight = -simd_normalize(lighting.keyLight.direction)
        var caster = ViewportBody.box(
            id: "caster", width: 3, height: 3, depth: 3, color: SIMD4(0.5, 0.5, 0.5, 1))
        caster.transform = simd_float4x4(
            columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                SIMD4(toLight * 4, 1)
            ))
        let receiver = ParityRender.quad(
            id: "receiver", x0: -8, y0: -8, x1: 8, y1: 8, z: -1, color: SIMD4(0.5, 0.5, 0.5, 1))
        let gizmo = overlayQuad()

        guard let liveLit = PassScene.live([receiver, gizmo], lighting: lighting),
            let liveShadowed = PassScene.live([receiver, caster, gizmo], lighting: lighting),
            let offLit = PassScene.offscreen([receiver, gizmo], lighting: lighting),
            let offShadowed = PassScene.offscreen([receiver, caster, gizmo], lighting: lighting)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        let c = PassScene.size / 2
        #expect(
            PassScene.rgb(liveShadowed.pixels, x: c, y: c)
                == PassScene.rgb(liveLit.pixels, x: c, y: c),
            "live: the caster shadowed the gizmo")
        #expect(
            PassScene.rgb(offShadowed.pixels, x: c, y: c)
                == PassScene.rgb(offLit.pixels, x: c, y: c),
            "offscreen: the caster shadowed the gizmo")
    }
}

// MARK: - #187 Translucent surfaces keep the image opaque

@Suite("Translucent surfaces and image alpha (#187)")
@MainActor
struct TranslucentAlphaTests {

    private func glassSphere() -> ViewportBody {
        var sphere = ViewportBody.sphere(id: "glass", radius: 3, color: SIMD4(1, 1, 1, 1))
        sphere.material = .glass
        return sphere
    }

    @Test("PBRMaterial.glass over an opaque background leaves every pixel opaque (offscreen)")
    func offscreenGlassKeepsAlpha() throws {
        guard let frame = PassScene.offscreen([glassSphere()]),
            let data = frame.image.dataProvider?.data as Data?
        else {
            Issue.record("Metal device unavailable")
            return
        }
        // Raw premultiplied BGRA bytes. A translucent surface used to blend the alpha channel
        // by srcA² + dstA(1 − srcA), leaving ~64 % alpha under the glass with colour above it,
        // which un-premultiplies to a flat white disc.
        let bytesPerRow = frame.image.bytesPerRow
        var minAlpha: UInt8 = 255
        var maxExcess = 0
        for y in 0..<frame.image.height {
            for x in 0..<frame.image.width {
                let i = y * bytesPerRow + x * 4
                let a = data[i + 3]
                minAlpha = min(minAlpha, a)
                maxExcess = max(maxExcess, Int(data[i + 2]) - Int(a))
            }
        }
        #expect(minAlpha == 255, "glass lowered the image alpha to \(minAlpha)")
        #expect(maxExcess <= 0, "colour exceeds alpha by \(maxExcess): invalid premultiplied pixel")
    }

    @Test("PBRMaterial.glass leaves the live frame opaque too")
    func liveGlassKeepsAlpha() throws {
        guard let frame = PassScene.live([glassSphere()]) else {
            Issue.record("Metal device unavailable")
            return
        }
        let minAlpha = stride(from: 3, to: frame.pixels.count, by: 4).map { frame.pixels[$0] }.min()
        #expect(minAlpha == 255, "glass lowered the live frame's alpha to \(minAlpha ?? 0)")
    }

    @Test("Glass over a coloured body shows that body, not white")
    func glassShowsWhatIsBehind() throws {
        let red = ParityRender.quad(
            id: "red", x0: -8, y0: -8, x1: 8, y1: 8, z: -4, color: SIMD4(1, 0, 0, 1))
        guard let frame = PassScene.offscreen([red, glassSphere()]) else {
            Issue.record("Metal device unavailable")
            return
        }
        // Read through the image as a consumer would (un-premultiplied by CoreGraphics).
        let c = PassScene.rgb(frame.pixels, x: PassScene.size / 2, y: PassScene.size / 2)
        #expect(c.x > c.y + 40, "the red body behind the glass washed out to \(c)")
    }
}

// MARK: - #171 Highlights on translucent bodies

@Suite("Per-triangle highlights on translucent bodies (#171)")
@MainActor
struct TranslucentHighlightTests {

    /// A translucent grey box with the triangles whose normal points along `side` (+1 front,
    /// −1 back, seen from the +Z camera) highlighted red.
    private func box(highlighting side: Float) -> ViewportBody {
        var box = ViewportBody.box(
            id: "box", width: 4, height: 4, depth: 4, color: SIMD4(0.6, 0.6, 0.6, 0.5))
        let triangleCount = box.indices.count / 3
        box.triangleStyles = (0..<triangleCount).map { t in
            let v = Int(box.indices[t * 3])
            let nz = box.vertexData[v * 6 + 5]
            return nz * side > 0.5 ? TriangleStyle(color: SIMD4(1, 0, 0, 1)) : .none
        }
        return box
    }

    private func redness(_ c: SIMD3<Int>) -> Int { c.x - (c.y + c.z) / 2 }

    @Test("A far-wall highlight is seen through the near wall, in both renderers")
    func farWallHighlightIsBehindNearWall() throws {
        let c = PassScene.size / 2
        for renderer in ["live", "offscreen"] {
            func render(_ body: ViewportBody) -> [UInt8]? {
                renderer == "live"
                    ? PassScene.live([body])?.pixels : PassScene.offscreen([body])?.pixels
            }
            guard let front = render(box(highlighting: 1)), let back = render(box(highlighting: -1))
            else {
                Issue.record("Metal device unavailable")
                return
            }
            let f = redness(PassScene.rgb(front, x: c, y: c))
            let b = redness(PassScene.rgb(back, x: c, y: c))
            #expect(f > 150, "\(renderer): the front-wall highlight should be strong (\(f))")
            #expect(
                b < f - 60,
                "\(renderer): the far-wall highlight painted through the near wall (\(b) vs \(f))")
        }
    }

    @Test("A mirrored translucent body still draws its far wall first")
    func mirroredBodyKeepsFarWallFirst() throws {
        var mirrored = box(highlighting: -1)
        mirrored.transform = simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1))
        #expect(ViewportRenderer.translucentCullOrder(for: mirrored.transform) == [.front, .back])
        let c = PassScene.size / 2
        guard let live = PassScene.live([mirrored]), let off = PassScene.offscreen([mirrored])
        else {
            Issue.record("Metal device unavailable")
            return
        }
        for (name, pixels) in [("live", live.pixels), ("offscreen", off.pixels)] {
            let b = redness(PassScene.rgb(pixels, x: c, y: c))
            #expect(
                b < 150,
                "\(name): the mirrored far-wall highlight painted over the near wall (\(b))")
        }
    }

    @Test("An opaque body's highlight is seen through a translucent body in front")
    func opaqueHighlightIsBehindTranslucentBody() throws {
        var target = ParityRender.quad(
            id: "target", x0: -3, y0: -3, x1: 3, y1: 3, z: -2, color: SIMD4(0.6, 0.6, 0.6, 1))
        target.triangleStyles = [
            TriangleStyle(color: SIMD4(1, 0, 0, 1)), .init(color: SIMD4(1, 0, 0, 1)),
        ]
        let veil = ParityRender.quad(
            id: "veil", x0: -6, y0: -6, x1: 6, y1: 6, z: 2, color: SIMD4(1, 1, 1, 0.6))
        let c = PassScene.size / 2
        for renderer in ["live", "offscreen"] {
            func render(_ bodies: [ViewportBody]) -> [UInt8]? {
                renderer == "live"
                    ? PassScene.live(bodies)?.pixels : PassScene.offscreen(bodies)?.pixels
            }
            guard let bare = render([target]), let veiled = render([target, veil]) else {
                Issue.record("Metal device unavailable")
                return
            }
            let open = redness(PassScene.rgb(bare, x: c, y: c))
            let behind = redness(PassScene.rgb(veiled, x: c, y: c))
            #expect(
                behind < open - 60,
                "\(renderer): the highlight painted over the translucent veil (\(behind) vs \(open))"
            )
        }
    }
}

// MARK: - #177 Selection outline over nearer occluders

@Suite("Selection outline under occluders (#177)")
@MainActor
struct OutlineOcclusionTests {

    private let outline = SelectionOutlineStyle(color: SIMD3(1, 1, 0), width: 3)

    @Test("A selected body hidden behind a nearer body gets a ring, not a filled blob")
    func hiddenSelectedBodyIsRingedNotFilled() throws {
        // Smooth normals, so the screen-space expansion has a silhouette to push out (a box seen
        // face-on has only edge-on side faces, which expand to nothing).
        let hidden = ViewportBody.sphere(id: "hidden", radius: 2, color: SIMD4(0.8, 0.8, 0.8, 1))
        // The occluder is drawn first, so the selected body fails the depth test under it.
        let bodies = [PassScene.bluePanel(z: 3), hidden]
        guard
            let live = PassScene.live(bodies, selected: ["hidden"], outline: outline),
            let offscreen = PassScene.offscreen(bodies, selected: ["hidden"], outline: outline)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        let yellow: (SIMD3<Int>) -> Bool = { $0.x > 150 && $0.y > 150 && $0.z < 100 }
        let c = PassScene.size / 2
        for (name, pixels) in [("live", live.pixels), ("offscreen", offscreen.pixels)] {
            let centre = PassScene.rgb(pixels, x: c, y: c)
            #expect(
                centre.z > centre.x + 60, "\(name): outline colour over the occluder: \(centre)")
            // The ring itself is still drawn around the hidden body.
            #expect(PassScene.count(pixels, where: yellow) > 40, "\(name): no outline ring")
        }
    }
}

// MARK: - #161 Tessellation / mesh-shader fallbacks

@Suite("Rendering-quality fallbacks (#161)")
@MainActor
struct RenderingQualityFallbackTests {

    /// A curved mesh with no `faceIndices`, as an STL import or a primitive brings.
    private func sphereWithoutFaceIndices() -> ViewportBody {
        var body = ViewportBody.sphere(id: "s", radius: 1, color: SIMD4(1, 1, 1, 1))
        body.faceIndices = []
        return body
    }

    @Test(".enhanced tessellates a body without faceIndices")
    func tessellationNeedsNoFaceIndices() {
        var config = ViewportConfiguration()
        config.renderingQuality = .enhanced
        config.initialCameraState = ParityRender.frontCamera
        let controller = ViewportController(configuration: config)
        let body = sphereWithoutFaceIndices()
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant([body])),
            renderer.tessellationEnabled
        else { return }
        _ = renderer.renderHeadlessBGRA(width: 64, height: 64, backgroundColor: SIMD4(0, 0, 0, 1))
        let (batch, untessellated) = renderer.tessellationFactorBatch(for: [body])
        #expect(batch.count == 1, "the body got no PN patches")
        #expect(untessellated == 0)
    }

    @Test("Meshlets are built for a body without faceIndices")
    func meshletsNeedNoFaceIndices() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let body = sphereWithoutFaceIndices()
        let meshlets = MeshletBuilder.build(
            vertexData: body.vertexData, indices: body.indices, device: device)
        #expect((meshlets?.meshletCount ?? 0) > 0)
    }

    @Test("MeshletDescriptor matches the 80-byte Metal MeshletDesc")
    func meshletDescriptorLayout() {
        #expect(MemoryLayout<MeshletDescriptor>.stride == 80)
        #expect(MemoryLayout<MeshletDescriptor>.offset(of: \.triangleCount) == 64)
    }

    @Test(
        "effectiveRenderingQuality reports what the renderer runs, and the controller forwards it")
    func effectiveQualityIsQueryable() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        for requested in [RenderingQuality.standard, .enhanced, .maximum] {
            var config = ViewportConfiguration()
            config.renderingQuality = requested
            let controller = ViewportController(configuration: config)
            #expect(controller.effectiveRenderingQuality == nil)
            guard let renderer = ViewportRenderer(controller: controller, bodies: .constant([]))
            else {
                Issue.record("renderer creation failed")
                return
            }
            let expected: RenderingQuality =
                requested == .maximum && !device.supportsFamily(.apple9) ? .enhanced : requested
            #expect(renderer.effectiveRenderingQuality == expected, "requested \(requested)")
            #expect(controller.effectiveRenderingQuality == renderer.effectiveRenderingQuality)
        }
    }

    @Test("The fallback is explained, and quiet when the requested quality runs")
    func fallbackReason() {
        #expect(
            ViewportRenderer.renderingQualityFallbackReason(
                requested: .enhanced, tessellationEnabled: true, meshShadersEnabled: false,
                supportsMeshShaders: false, pipelineErrors: []) == nil)
        #expect(
            ViewportRenderer.renderingQualityFallbackReason(
                requested: .standard, tessellationEnabled: false, meshShadersEnabled: false,
                supportsMeshShaders: false, pipelineErrors: []) == nil)
        let noMesh = ViewportRenderer.renderingQualityFallbackReason(
            requested: .maximum, tessellationEnabled: true, meshShadersEnabled: false,
            supportsMeshShaders: false, pipelineErrors: [])
        #expect(noMesh?.contains(".enhanced") == true)
        #expect(noMesh?.contains("Apple9") == true)
        let failed = ViewportRenderer.renderingQualityFallbackReason(
            requested: .maximum, tessellationEnabled: true, meshShadersEnabled: false,
            supportsMeshShaders: true, pipelineErrors: ["mesh_shaded: boom"])
        #expect(failed?.contains("mesh_shaded: boom") == true)
        // The quality runs, but an auxiliary mesh pipeline failed: still reported.
        let auxiliary = ViewportRenderer.renderingQualityFallbackReason(
            requested: .maximum, tessellationEnabled: true, meshShadersEnabled: true,
            supportsMeshShaders: true, pipelineErrors: ["mesh_pick: boom"])
        #expect(auxiliary?.contains("mesh_pick: boom") == true)
    }
}

// MARK: - #202 Passes on the PN-tessellated surface

@Suite("Highlight, outline and crease on the tessellated surface (#202)")
@MainActor
struct TessellatedSurfacePassTests {

    /// A coarse sphere: neighbouring normals differ by 45-60°, so PN patches bulge only when the
    /// crease angle allows it.
    private func coarseSphere(highlighted: Bool = false) -> ViewportBody {
        var body = ViewportBody.sphere(
            id: "s", radius: 4, segments: 6, rings: 4, color: SIMD4(0.6, 0.6, 0.6, 1))
        if highlighted {
            body.triangleStyles = Array(
                repeating: TriangleStyle(color: SIMD4(1, 0, 0, 1)), count: body.indices.count / 3)
        }
        return body
    }

    private let outline = SelectionOutlineStyle(color: SIMD3(1, 1, 0), width: 3)

    private func offscreen(_ body: ViewportBody, crease: Float, selected: Bool) -> [UInt8]? {
        guard let renderer = OffscreenRenderer() else { return nil }
        var options = ParityRender.options(displayMode: .shaded)
        options.renderingQuality = .enhanced
        options.adaptiveTessellation = false
        options.uniformTessellationFactor = .fixed(16)
        options.normalSmoothingCreaseAngle = crease
        options.selectionOutline = outline
        if selected { options.selectedBodyIDs = [body.id] }
        guard let image = renderer.render(bodies: [body], options: options) else { return nil }
        return ParityRender.bgra(image).0
    }

    private func live(_ body: ViewportBody, crease: Float, selected: Bool) -> [UInt8]? {
        var config = ViewportConfiguration(
            initialCameraState: ParityRender.frontCamera, displayMode: .shaded,
            lightingConfiguration: ParityRender.plainLighting, showGrid: false,
            backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false,
            renderingQuality: .enhanced, adaptiveTessellation: false,
            uniformTessellationFactor: .fixed(16))
        config.normalSmoothingCreaseAngle = crease
        config.selectionOutline = outline
        let controller = ViewportController(configuration: config)
        controller.showAxes = false
        if selected { controller.selectedBodyIDs = [body.id] }
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant([body])),
            renderer.tessellationEnabled
        else { return nil }
        return renderer.renderHeadlessBGRA(
            width: PassScene.size, height: PassScene.size, backgroundColor: SIMD4(0, 0, 0, 1))
    }

    private func render(
        _ which: String, _ body: ViewportBody, crease: Float, selected: Bool = false
    ) -> [UInt8]? {
        which == "live"
            ? live(body, crease: crease, selected: selected)
            : offscreen(body, crease: crease, selected: selected)
    }

    /// About 92°: every edge of the coarse sphere bulges.
    private static let roundCrease: Float = 1.6

    private func isBody(_ c: SIMD3<Int>) -> Bool { c.x + c.y + c.z > 30 }

    @Test("normalSmoothingCreaseAngle sets the PN crease threshold, in both renderers")
    func creaseAngleRoundsCoarseMesh() throws {
        #expect(abs(TessellationManager.creaseCosine(.pi / 3) - 0.5) < 1e-5)
        #expect(TessellationManager.creaseCosine(-1) == 1)
        #expect(abs(TessellationManager.creaseCosine(.nan) - cos(Float.pi / 6)) < 1e-5)
        for which in ["live", "offscreen"] {
            guard let sharp = render(which, coarseSphere(), crease: 0.524),
                let round = render(which, coarseSphere(), crease: Self.roundCrease)
            else {
                Issue.record("Metal device unavailable")
                return
            }
            let sharpArea = PassScene.count(sharp, where: isBody)
            let roundArea = PassScene.count(round, where: isBody)
            #expect(
                roundArea > sharpArea + 150,
                "\(which): a 92° crease should round the coarse sphere (\(sharpArea) → \(roundArea))"
            )
        }
    }

    @Test("A per-triangle highlight covers the whole tessellated surface, in both renderers")
    func highlightCoversBulgedSurface() throws {
        for which in ["live", "offscreen"] {
            guard
                let pixels = render(
                    which, coarseSphere(highlighted: true), crease: Self.roundCrease)
            else {
                Issue.record("Metal device unavailable")
                return
            }
            let body = PassScene.count(pixels, where: isBody)
            let red = PassScene.count(pixels, where: PassScene.isRed)
            #expect(
                Double(red) > Double(body) * 0.9,
                "\(which): the flat highlight lost to the bulged surface (\(red) of \(body) red)")
        }
    }

    @Test("Overlay bodies stay out of the live tessellation-factor batch")
    func overlaysSkipFactorBatch() {
        var config = ViewportConfiguration()
        config.renderingQuality = .enhanced
        let controller = ViewportController(configuration: config)
        var gizmo = coarseSphere()
        gizmo.renderLayer = .overlay
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant([gizmo])),
            renderer.tessellationEnabled
        else {
            Issue.record("Metal device or tessellation unavailable")
            return
        }
        _ = renderer.renderHeadlessBGRA(width: 64, height: 64, backgroundColor: SIMD4(0, 0, 0, 1))
        let (batch, untessellated) = renderer.tessellationFactorBatch(for: [gizmo])
        #expect(batch.isEmpty, "factors were computed for an overlay that draws untessellated")
        #expect(untessellated == 0)
    }

    @Test("The selection outline rings the tessellated silhouette, in both renderers")
    func outlineRingsBulgedSilhouette() throws {
        let yellow: (SIMD3<Int>) -> Bool = { $0.x > 150 && $0.y > 150 && $0.z < 100 }
        for which in ["live", "offscreen"] {
            guard let plain = render(which, coarseSphere(), crease: Self.roundCrease),
                let selected = render(
                    which, coarseSphere(), crease: Self.roundCrease, selected: true)
            else {
                Issue.record("Metal device unavailable")
                return
            }
            // Ring pixels painted over the surface itself: a ring around the flat mesh's
            // silhouette lies inside the bulged one.
            var inside = 0
            var ring = 0
            for y in 0..<PassScene.size {
                for x in 0..<PassScene.size where yellow(PassScene.rgb(selected, x: x, y: y)) {
                    ring += 1
                    if isBody(PassScene.rgb(plain, x: x, y: y)) { inside += 1 }
                }
            }
            #expect(ring > 100, "\(which): no outline ring")
            #expect(
                inside * 5 < ring,
                "\(which): \(inside) of \(ring) ring pixels lie on the tessellated surface")
        }
    }
}
