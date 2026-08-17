// ViewportRendererHeadlessTests.swift
// OCCTSwiftViewport Tests
//
// Permanent differential-render harness for `ViewportRenderer`'s own draw path (issue #103).
//
// `ViewportRenderer.renderHeadlessBGRA(...)` drives the exact `encodeFrame(into:)` the live
// `MTKView` path drives — shadow map, skybox, grid, axes, opaque + transparent surfaces, arcs,
// point clouds, per-triangle highlights, selection outline, overlays, the R32Uint pick pass, TAA
// resolve and the SSAO/silhouette/tone-map composite. Hashing a fixed battery of deterministic
// scenes therefore pins the live renderer's real output, which previously could only be eyeballed
// on a device (see PR #102's "what was not verified" section).
//
// Cross-branch use (what #103 exists for):
//
//   VIEWPORT_HEADLESS_DUMP_DIR=/tmp/base swift test --filter ViewportRendererHeadlessTests
//   git checkout <other-branch>
//   VIEWPORT_HEADLESS_DUMP_DIR=/tmp/head swift test --filter ViewportRendererHeadlessTests
//   diff /tmp/base/hashes.json /tmp/head/hashes.json
//
// Each dump directory also gets one raw `<scene>.bgra` per scene, so a hash mismatch can be
// quantified (max channel delta, differing pixel count) instead of just flagged.

import CryptoKit
import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Scene battery

/// One deterministic scene in the differential-render battery.
struct HeadlessRenderScene: Sendable {
    let name: String
    let configuration: ViewportConfiguration
    let bodies: [ViewportBody]
    let displayMode: DisplayMode
    let lighting: LightingConfiguration
    let showGrid: Bool
    let showAxes: Bool
    let enableTAA: Bool
    let selectedBodyIDs: Set<String>
    /// Frames encoded before readback.
    ///
    /// More than one warms up TAA history.
    let frameCount: Int
    let width: Int
    let height: Int
}

/// Builds the scene battery and renders it through the headless entry point.
enum ViewportRenderBattery {

    static let width = 160
    static let height = 120

    // MARK: Geometry helpers

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    /// Box + sphere pair used by most scenes, at fixed transforms so the framing never drifts.
    static func standardBodies() -> [ViewportBody] {
        var box = ViewportBody.box(
            id: "box", width: 1.2, height: 0.8, depth: 1.0,
            color: SIMD4<Float>(0.85, 0.45, 0.20, 1))
        box.transform = translation(-0.7, 0, 0)
        var sphere = ViewportBody.sphere(
            id: "sphere", radius: 0.6, color: SIMD4<Float>(0.25, 0.55, 0.9, 1))
        sphere.transform = translation(0.8, 0.15, -0.3)
        return [box, sphere]
    }

    /// The standard pair with a wide, thin slab underneath to catch cast shadows.
    static func shadowBodies() -> [ViewportBody] {
        var ground = ViewportBody.box(
            id: "ground", width: 6, height: 0.2, depth: 6,
            color: SIMD4<Float>(0.75, 0.75, 0.78, 1))
        ground.transform = translation(0, -1.0, 0)
        return standardBodies() + [ground]
    }

    /// The standard sphere rebuilt from de-interleaved position/normal arrays (direct-mesh path).
    static func directMeshBodies() -> [ViewportBody] {
        let interleaved = ViewportBody.sphere(
            id: "sphere", radius: 0.8, color: SIMD4<Float>(0.4, 0.7, 0.95, 1))
        var positions: [Float] = []
        var normals: [Float] = []
        let vd = interleaved.vertexData
        positions.reserveCapacity(vd.count / 2)
        normals.reserveCapacity(vd.count / 2)
        var i = 0
        while i + 5 < vd.count {
            positions.append(contentsOf: [vd[i], vd[i + 1], vd[i + 2]])
            normals.append(contentsOf: [vd[i + 3], vd[i + 4], vd[i + 5]])
            i += 6
        }
        return [
            ViewportBody.directMesh(
                id: "direct", positions: positions, normals: normals,
                indices: interleaved.indices, color: SIMD4<Float>(0.4, 0.7, 0.95, 1))
        ]
    }

    /// A 200-point cloud on a deterministic lattice, with per-point colours.
    static func pointCloudBodies() -> [ViewportBody] {
        var points: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        points.reserveCapacity(200)
        colors.reserveCapacity(200)
        for i in 0..<200 {
            let t = Float(i) / 200.0
            let angle = t * 12.0
            let radius = 0.4 + t * 0.8
            points.append(
                SIMD3<Float>(cos(angle) * radius, t * 1.6 - 0.8, sin(angle) * radius))
            colors.append(SIMD4<Float>(t, 1 - t, 0.5, 1))
        }
        return [
            ViewportBody(
                id: "cloud", vertexData: [], indices: [], edges: [],
                vertices: points, vertexColors: colors,
                color: SIMD4<Float>(0.9, 0.9, 0.2, 1),
                pointRadius: 0.05, primitiveKind: .point)
        ]
    }

    /// Two overlapping translucent bodies plus one opaque body behind them.
    static func transparentBodies() -> [ViewportBody] {
        var opaque = ViewportBody.box(
            id: "opaque", width: 1.4, height: 1.4, depth: 0.2,
            color: SIMD4<Float>(0.2, 0.2, 0.25, 1))
        opaque.transform = translation(0, 0, -1.2)
        var front = ViewportBody.sphere(
            id: "front", radius: 0.7, color: SIMD4<Float>(0.9, 0.3, 0.3, 1))
        front.material = PBRMaterial(
            baseColor: SIMD3<Float>(0.9, 0.3, 0.3), metallic: 0, roughness: 0.4, opacity: 0.45)
        front.transform = translation(-0.35, 0, 0.4)
        var back = ViewportBody.sphere(
            id: "back", radius: 0.7, color: SIMD4<Float>(0.3, 0.9, 0.4, 1))
        back.material = PBRMaterial(
            baseColor: SIMD3<Float>(0.3, 0.9, 0.4), metallic: 0, roughness: 0.4, opacity: 0.55)
        back.transform = translation(0.35, 0, -0.2)
        return [opaque, front, back]
    }

    // MARK: Lighting helpers

    /// `.threePoint` with the shadow pass forced on and darkened, so cast shadows are obvious.
    static func shadowLighting() -> LightingConfiguration {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = true
        lighting.shadowIntensity = 0.6
        return lighting
    }

    /// `.threePoint` with SSAO explicitly on or off, isolating it from the silhouette pass.
    static func lighting(ssao: Bool) -> LightingConfiguration {
        var lighting = LightingConfiguration.threePoint
        lighting.enableSSAO = ssao
        lighting.shadowsEnabled = false
        return lighting
    }

    // MARK: Camera helpers

    /// A fixed three-quarter view fitted to `bodies`, so framing depends only on the geometry.
    static func fittedCamera(for bodies: [ViewportBody]) -> CameraState {
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 1, 0))
        if let fitted = camera.fit(
            to: bodies, aspectRatio: Float(width) / Float(height), padding: 1.35)
        {
            camera = fitted
        }
        return camera
    }

    /// A camera at an exact distance, used by the grid scenes to select spacing levels.
    static func gridCamera(distance: Float) -> CameraState {
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))
        camera.distance = distance
        camera.pivot = SIMD3<Float>(0.3, 0, -0.2)
        return camera
    }

    // MARK: Grid scenes

    /// Camera distances the grid scenes sample, chosen to straddle spacing-level boundaries.
    static let gridDistances: [Float] = [0.5, 3, 20, 200]

    /// A grid scene at one camera distance and subdivision factor.
    ///
    /// `subdivisions` is the knob whose two hardcoded values diverged between the live and headless
    /// renderers before #101/#102; parameterizing it lets the battery double as a sensitivity check
    /// that the grid pass really does respond to it.
    static func gridScene(distance: Float, subdivisions: Int = 10) -> HeadlessRenderScene {
        let label = String(format: "%g", distance).replacingOccurrences(of: ".", with: "_")
        let configuration = ViewportConfiguration(
            initialCameraState: gridCamera(distance: distance),
            showGrid: true,
            gridSubdivisions: subdivisions
        )
        return HeadlessRenderScene(
            name: "grid-d\(label)",
            configuration: configuration,
            bodies: standardBodies(),
            displayMode: .shaded,
            lighting: .threePoint,
            showGrid: true,
            showAxes: false,
            enableTAA: false,
            selectedBodyIDs: [],
            frameCount: 1,
            width: width,
            height: height
        )
    }

    // MARK: Scene battery

    static func makeScenes() -> [HeadlessRenderScene] {
        var scenes: [HeadlessRenderScene] = []

        func scene(
            _ name: String,
            bodies: [ViewportBody],
            camera: CameraState? = nil,
            displayMode: DisplayMode = .shaded,
            lighting: LightingConfiguration = .threePoint,
            showGrid: Bool = false,
            showAxes: Bool = false,
            enableTAA: Bool = false,
            enableSilhouettes: Bool = true,
            pickingEnabled: Bool = false,
            selectedBodyIDs: Set<String> = [],
            frameCount: Int = 1
        ) {
            let resolved = camera ?? fittedCamera(for: bodies)
            let configuration = ViewportConfiguration(
                initialCameraState: resolved,
                displayMode: displayMode,
                lightingConfiguration: lighting,
                showAxes: showAxes,
                showGrid: showGrid,
                enableSilhouettes: enableSilhouettes,
                pickingConfiguration: PickingConfiguration(isEnabled: pickingEnabled),
                enableTAA: enableTAA
            )
            scenes.append(
                HeadlessRenderScene(
                    name: name,
                    configuration: configuration,
                    bodies: bodies,
                    displayMode: displayMode,
                    lighting: lighting,
                    showGrid: showGrid,
                    showAxes: showAxes,
                    enableTAA: enableTAA,
                    selectedBodyIDs: selectedBodyIDs,
                    frameCount: frameCount,
                    width: width,
                    height: height
                ))
        }

        // --- The 12-scene set PR #102's transient OffscreenRenderer harness used ---
        scene("shaded", bodies: standardBodies())
        scene("shaded-with-edges", bodies: standardBodies(), displayMode: .shadedWithEdges)
        scene("wireframe", bodies: standardBodies(), displayMode: .wireframe)
        scene("unlit", bodies: standardBodies(), displayMode: .unlit)
        scene("transparency", bodies: transparentBodies(), displayMode: .shadedWithEdges)
        scene("direct-mesh", bodies: directMeshBodies())
        scene("point-cloud", bodies: pointCloudBodies())
        scene("shadows", bodies: shadowBodies(), lighting: shadowLighting())
        scene("axes", bodies: standardBodies(), showAxes: true)
        scene("flat-lighting", bodies: standardBodies(), lighting: .flat)
        scene("ortho-pan", bodies: standardBodies(), camera: orthoPanCamera())
        scenes.append(contentsOf: gridDistances.map { gridScene(distance: $0) })

        // --- Variants the transient harness could not cover ---
        scene(
            "ssao-only", bodies: standardBodies(), lighting: lighting(ssao: true),
            enableSilhouettes: false)
        scene(
            "silhouettes-only", bodies: standardBodies(), lighting: lighting(ssao: false),
            enableSilhouettes: true)
        scene("picking-on", bodies: standardBodies(), pickingEnabled: true)
        scene("selection-outline", bodies: standardBodies(), selectedBodyIDs: ["sphere"])
        scene("taa-on", bodies: standardBodies(), enableTAA: true, frameCount: 8)

        return scenes
    }

    /// Orthographic camera with a screen-space pan applied, mirroring the headless ortho+pan scene.
    static func orthoPanCamera() -> CameraState {
        var camera = fittedCamera(for: standardBodies())
        camera.isOrthographic = true
        camera.orthographicScale = 2.4
        camera.panOffset = SIMD2<Float>(0.35, -0.2)
        return camera
    }

    // MARK: Rendering

    /// Builds a controller + renderer pair configured for `scene`.
    ///
    /// A fresh pair is built per scene so no per-frame state (TAA history, buffer caches, resolved
    /// textures) can leak between scenes and make results order-dependent. The controller is
    /// returned alongside the renderer because the renderer only holds it weakly.
    @MainActor
    static func makeRenderer(
        for scene: HeadlessRenderScene
    ) -> (controller: ViewportController, renderer: ViewportRenderer)? {
        let controller = ViewportController(configuration: scene.configuration)
        controller.displayMode = scene.displayMode
        controller.lightingConfiguration = scene.lighting
        controller.showGrid = scene.showGrid
        controller.showAxes = scene.showAxes
        controller.enableTAA = scene.enableTAA
        controller.selectedBodyIDs = scene.selectedBodyIDs

        guard
            let renderer = ViewportRenderer(
                controller: controller, bodies: .constant(scene.bodies))
        else { return nil }
        return (controller, renderer)
    }

    /// Renders one scene through the renderer's off-screen path.
    @MainActor
    static func render(_ scene: HeadlessRenderScene) -> [UInt8]? {
        guard let pair = makeRenderer(for: scene) else { return nil }
        return pair.renderer.renderHeadlessBGRA(
            width: scene.width,
            height: scene.height,
            backgroundColor: scene.configuration.backgroundColor,
            frameCount: scene.frameCount
        )
    }

    /// SHA-256 of a raw BGRA buffer, as lowercase hex.
    static func digest(_ pixels: [UInt8]) -> String {
        SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()
    }

    /// Largest single-channel difference between two equally sized buffers, plus the pixel count
    /// that differs at all.
    static func compare(_ a: [UInt8], _ b: [UInt8]) -> (maxChannelDelta: Int, differingPixels: Int)
    {
        guard a.count == b.count else { return (255, max(a.count, b.count) / 4) }
        var maxDelta = 0
        var differing = 0
        for p in stride(from: 0, to: a.count, by: 4) {
            var pixelDiffers = false
            for c in 0..<4 {
                let d = abs(Int(a[p + c]) - Int(b[p + c]))
                if d > 0 { pixelDiffers = true }
                maxDelta = max(maxDelta, d)
            }
            if pixelDiffers { differing += 1 }
        }
        return (maxDelta, differing)
    }
}

// MARK: - Tests

@MainActor
@Suite("ViewportRenderer headless frame rendering")
struct ViewportRendererHeadlessTests {

    /// Renders the whole battery once, returning `nil` when Metal is unavailable.
    private func renderBattery() -> [(scene: HeadlessRenderScene, pixels: [UInt8])]? {
        let scenes = ViewportRenderBattery.makeScenes()
        var out: [(HeadlessRenderScene, [UInt8])] = []
        for scene in scenes {
            guard let pixels = ViewportRenderBattery.render(scene) else { return nil }
            out.append((scene, pixels))
        }
        return out
    }

    @Test("Off-screen targets are built to the live view's specification")
    func targetsMatchLiveViewSpecification() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let targets = HeadlessRenderTargets(device: device)
        #expect(targets.ensure(width: 64, height: 48, sampleCount: 4))
        #expect(targets.colorTexture?.pixelFormat == .bgra8Unorm)
        #expect(targets.colorTexture?.sampleCount == 4)
        #expect(targets.depthStencilTexture?.pixelFormat == .depth32Float_stencil8)
        #expect(targets.depthStencilTexture?.sampleCount == 4)
        #expect(targets.resolveTexture?.sampleCount == 1)

        let desc = try #require(targets.makeMainPassDescriptor(clearColor: MTLClearColor()))
        #expect(desc.colorAttachments[0].storeAction == .multisampleResolve)
        #expect(desc.colorAttachments[0].resolveTexture === targets.resolveTexture)
        #expect(desc.depthAttachment.texture === targets.depthStencilTexture)
        #expect(desc.stencilAttachment.texture === targets.depthStencilTexture)

        // At 1x sample the drawable itself is the render target, so colour == resolve.
        let single = HeadlessRenderTargets(device: device)
        #expect(single.ensure(width: 64, height: 48, sampleCount: 1))
        #expect(single.colorTexture === single.resolveTexture)
        let singleDesc = try #require(single.makeMainPassDescriptor(clearColor: MTLClearColor()))
        #expect(singleDesc.colorAttachments[0].storeAction == .store)
    }

    @Test("Every battery scene renders a full-size frame")
    func everySceneRenders() throws {
        guard let results = renderBattery() else {
            Issue.record("Metal device unavailable; skipping headless render battery")
            return
        }
        #expect(results.count >= 17, "battery shrank — scenes should only be added, not removed")
        for (scene, pixels) in results {
            #expect(
                pixels.count == scene.width * scene.height * 4,
                "\(scene.name): unexpected buffer size")
            let allSame = pixels.allSatisfy { $0 == pixels[0] }
            #expect(!allSame, "\(scene.name): frame is a flat fill — nothing was drawn")
        }
    }

    @Test("Rendering is deterministic, so hashes are a valid regression signal")
    func renderingIsDeterministic() throws {
        let scenes = ViewportRenderBattery.makeScenes()
        for scene in scenes {
            guard let first = ViewportRenderBattery.render(scene) else {
                Issue.record("Metal device unavailable; skipping determinism check")
                return
            }
            guard let second = ViewportRenderBattery.render(scene) else {
                Issue.record("second render returned nil for \(scene.name)")
                return
            }
            let delta = ViewportRenderBattery.compare(first, second)
            #expect(
                delta.maxChannelDelta == 0,
                """
                \(scene.name): renderer is not deterministic \
                (max channel delta \(delta.maxChannelDelta) over \(delta.differingPixels) pixels)
                """)
        }
    }

    @Test("Battery hashes, optionally dumped for cross-branch comparison")
    func captureHashes() throws {
        guard let results = renderBattery() else {
            Issue.record("Metal device unavailable; skipping hash capture")
            return
        }

        var hashes: [String: String] = [:]
        for (scene, pixels) in results {
            hashes[scene.name] = ViewportRenderBattery.digest(pixels)
        }
        for name in hashes.keys.sorted() {
            print("[headless-battery] \(name) \(hashes[name] ?? "")")
        }

        guard let dir = ProcessInfo.processInfo.environment["VIEWPORT_HEADLESS_DUMP_DIR"],
            !dir.isEmpty
        else { return }

        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(hashes).write(to: url.appendingPathComponent("hashes.json"))
        for (scene, pixels) in results {
            try Data(pixels).write(to: url.appendingPathComponent("\(scene.name).bgra"))
        }
    }

    @Test("The live grid pass tracks ViewportConfiguration.gridSubdivisions")
    func gridTracksSubdivisions() throws {
        // Negative control for the battery's four grid scenes: if the grid pass ignored the
        // subdivision factor (or the grid were not drawn at all), "grid hashes unchanged" across
        // two branches would be vacuous. #101/#102 fixed exactly this knob diverging between the
        // live and headless renderers, so pin that the live pass responds to it.
        var divergentDistances: [Float] = []
        for distance in ViewportRenderBattery.gridDistances {
            guard
                let tens = ViewportRenderBattery.render(
                    ViewportRenderBattery.gridScene(distance: distance, subdivisions: 10)),
                let fives = ViewportRenderBattery.render(
                    ViewportRenderBattery.gridScene(distance: distance, subdivisions: 5))
            else {
                Issue.record("Metal device unavailable; skipping grid sensitivity check")
                return
            }
            if ViewportRenderBattery.compare(tens, fives).differingPixels > 0 {
                divergentDistances.append(distance)
            }
        }
        print("[grid-sensitivity] subdivisions 10 vs 5 diverge at distances \(divergentDistances)")
        #expect(
            !divergentDistances.isEmpty,
            "grid output never changed with gridSubdivisions — the grid scenes prove nothing")
    }

    @Test("A headless frame populates the GPU pick texture")
    func headlessFramePopulatesPickTexture() async throws {
        let scenes = ViewportRenderBattery.makeScenes()
        guard let pickScene = scenes.first(where: { $0.name == "picking-on" }) else {
            Issue.record("picking-on scene missing from the battery")
            return
        }
        guard let pair = ViewportRenderBattery.makeRenderer(for: pickScene) else {
            Issue.record("Metal device unavailable; skipping pick-texture check")
            return
        }
        let pixels = pair.renderer.renderHeadlessBGRA(
            width: pickScene.width,
            height: pickScene.height,
            backgroundColor: pickScene.configuration.backgroundColor
        )
        #expect(pixels != nil)

        // Region-pick the whole frame. Before headless mode this was unreachable without a live
        // drawable, so RegionPickTests could only cover the pure clamp/decode helpers.
        let rect = CGRect(x: 0, y: 0, width: pickScene.width, height: pickScene.height)
        let results: [PickResult] = await withCheckedContinuation { continuation in
            pair.renderer.performRegionPick(rect: rect) { results in
                continuation.resume(returning: results)
            }
        }
        let hitIDs = Set(results.map(\.bodyID))
        #expect(hitIDs.contains("box"), "box missing from the pick texture")
        #expect(hitIDs.contains("sphere"), "sphere missing from the pick texture")
    }

    @Test("TAA-enabled frames accumulate history without changing resource shape")
    func taaPathExecutes() throws {
        let scenes = ViewportRenderBattery.makeScenes()
        guard let taaScene = scenes.first(where: { $0.name == "taa-on" }) else {
            Issue.record("taa-on scene missing from the battery")
            return
        }
        guard let warm = ViewportRenderBattery.render(taaScene) else {
            Issue.record("Metal device unavailable; skipping TAA check")
            return
        }
        #expect(warm.count == taaScene.width * taaScene.height * 4)

        // A single TAA frame has no history to blend, so it must differ from the warmed-up
        // 8-frame result — proof the accumulation path actually ran rather than no-oping.
        var singleFrame = taaScene
        singleFrame = HeadlessRenderScene(
            name: taaScene.name,
            configuration: taaScene.configuration,
            bodies: taaScene.bodies,
            displayMode: taaScene.displayMode,
            lighting: taaScene.lighting,
            showGrid: taaScene.showGrid,
            showAxes: taaScene.showAxes,
            enableTAA: taaScene.enableTAA,
            selectedBodyIDs: taaScene.selectedBodyIDs,
            frameCount: 1,
            width: taaScene.width,
            height: taaScene.height
        )
        guard let cold = ViewportRenderBattery.render(singleFrame) else {
            Issue.record("single-frame TAA render returned nil")
            return
        }
        let delta = ViewportRenderBattery.compare(cold, warm)
        #expect(delta.differingPixels > 0, "TAA history never accumulated across frames")
    }
}
