// TAAResolveTargetTests.swift
// OCCTSwiftViewport Tests
//
// Issue #244: with `enableTAA` on and the SSAO/silhouette composite not running (no SSAO, no
// silhouettes, or an unlit / wireframe display mode), the main pass resolved into the TAA input
// texture and the TAA output was only ever consumed by that composite. Nothing wrote the frame's
// final target, so the drawable held whatever it held before (uninitialised memory headless).

import Foundation
import Metal
import MetalKit
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("TAA resolve reaches the final target")
struct TAAResolveTargetTests {

    private static let size = 96
    private static let background = SIMD4<Float>(0, 0, 0, 1)

    private struct RenderUnavailable: Error {}

    /// A lit grey box, filling roughly the middle half of the frame from +Z.
    private static func box() -> ViewportBody {
        .box(id: "box", width: 2, height: 2, depth: 2, color: SIMD4(0.8, 0.8, 0.8, 1))
    }

    private struct Scene {
        var taa: Bool
        var silhouettes = false
        var ssao = false
        var displayMode: DisplayMode = .shaded
        var progressive = false
    }

    private func makeLive(_ scene: Scene) throws -> (ViewportController, ViewportRenderer) {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = scene.ssao
        let camera = CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 8, pivot: .zero)
        let configuration = ViewportConfiguration(
            initialCameraState: camera, displayMode: scene.displayMode,
            lightingConfiguration: lighting, showAxes: false, showGrid: false,
            backgroundColor: Self.background, enableSilhouettes: scene.silhouettes)
        let controller = ViewportController(configuration: configuration)
        controller.displayMode = scene.displayMode
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = scene.taa
        controller.enableProgressiveAccumulation = scene.progressive
        guard
            let renderer = ViewportRenderer(
                controller: controller, bodies: .constant([Self.box()]))
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw RenderUnavailable()
        }
        return (controller, renderer)
    }

    private func render(_ scene: Scene, frames: Int) throws -> [UInt8] {
        let pair = try makeLive(scene)
        guard
            let pixels = pair.1.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: Self.background,
                frameCount: frames)
        else {
            Issue.record("headless render returned nil")
            throw RenderUnavailable()
        }
        return pixels
    }

    /// The BGR channels of the pixel at `(x, y)`.
    private static func bgr(_ pixels: [UInt8], x: Int, y: Int) -> [Int] {
        let i = (y * size + x) * 4
        return [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
    }

    /// Largest per-channel difference between the same pixel of two frames.
    private static func channelDelta(_ a: [UInt8], _ b: [UInt8], x: Int, y: Int) -> Int {
        zip(bgr(a, x: x, y: y), bgr(b, x: x, y: y)).map { abs($0 - $1) }.max() ?? 0
    }

    /// Checks `scene` against the same scene with TAA off: the box interior (flat shading, away
    /// from every edge TAA could soften) and the empty corner must agree.
    private func expectMatchesWithoutTAA(
        _ scene: Scene, frames: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        var reference = scene
        reference.taa = false
        let off = try render(reference, frames: 1)
        let on = try render(scene, frames: frames)
        let mid = Self.size / 2
        let box = Self.channelDelta(off, on, x: mid, y: mid)
        let corner = Self.channelDelta(off, on, x: 4, y: 4)
        let described = "\(scene), \(frames) frame(s)"
        #expect(
            box <= 12, "box interior differs by \(box) from the TAA-off render (\(described))",
            sourceLocation: sourceLocation)
        #expect(
            corner <= 12,
            "empty corner differs by \(corner) from the TAA-off render (\(described))",
            sourceLocation: sourceLocation)
        #expect(
            Self.bgr(on, x: mid, y: mid).max()! > 60, "box is dark (\(described))",
            sourceLocation: sourceLocation)
    }

    @Test(
        "A mesh body keeps its colour with TAA on, on the first frame and after several",
        arguments: [
            (silhouettes: false, ssao: false),
            (silhouettes: true, ssao: false),
            (silhouettes: false, ssao: true),
            (silhouettes: true, ssao: true),
        ],
        [1, 6])
    func meshBodyRendersWithTAA(config: (silhouettes: Bool, ssao: Bool), frames: Int) throws {
        try expectMatchesWithoutTAA(
            Scene(taa: true, silhouettes: config.silhouettes, ssao: config.ssao), frames: frames)
    }

    @Test("Progressive accumulation also reaches the final target", arguments: [1, 6])
    func progressiveAccumulationRenders(frames: Int) throws {
        try expectMatchesWithoutTAA(
            Scene(taa: true, progressive: true), frames: frames)
    }

    @Test(
        "Display modes that skip the composite still reach the final target with TAA on",
        arguments: [DisplayMode.unlit, .wireframe], [1, 4])
    func compositeFreeDisplayModes(mode: DisplayMode, frames: Int) throws {
        let scene = Scene(taa: true, silhouettes: true, displayMode: mode)
        var reference = scene
        reference.taa = false
        let off = try render(reference, frames: 1)
        let on = try render(scene, frames: frames)
        // Wireframe edges move with the TAA jitter, so compare coverage rather than pixels.
        func covered(_ pixels: [UInt8]) -> Int {
            var count = 0
            for i in stride(from: 0, to: pixels.count, by: 4)
            where max(pixels[i], pixels[i + 1], pixels[i + 2]) > 20 { count += 1 }
            return count
        }
        let expected = covered(off)
        let actual = covered(on)
        #expect(expected > 0, "premise: \(mode) draws something with TAA off")
        #expect(
            Double(actual) > Double(expected) * 0.6 && Double(actual) < Double(expected) * 1.6,
            "\(mode) with TAA covers \(actual) pixels, \(expected) without (\(frames) frame(s))")
    }

    // MARK: - Live (MTKView) path

    /// Drives `encodeFrame` with the descriptor and drawable texture of a real, off-screen
    /// `MTKView` - the objects `draw(in:)` hands the renderer - and reads the drawable back.
    @Test("The live MTKView drawable receives the frame with TAA on and no composite")
    func liveViewDrawableReceivesFrame() throws {
        let pair = try makeLive(Scene(taa: true))
        let renderer = pair.1
        let view = MTKView(
            frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size),
            device: renderer.metalDevice)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        view.sampleCount = 4
        view.framebufferOnly = false
        view.drawableSize = CGSize(width: Self.size, height: Self.size)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let drawable = view.currentDrawable else {
            Issue.record("an off-screen MTKView gave no drawable; skipping the live-view check")
            return
        }
        for _ in 0..<3 {
            guard let descriptor = view.currentRenderPassDescriptor else { return }
            renderer.encodeFrame(
                into: FrameRenderTargets(
                    mainPassDescriptor: descriptor, finalColorTexture: drawable.texture,
                    size: view.drawableSize, presentable: nil))
        }

        let bytesPerRow = Self.size * 4
        let byteCount = bytesPerRow * Self.size
        guard
            let buffer = renderer.metalDevice.makeBuffer(
                length: byteCount, options: .storageModeShared),
            let commandBuffer = renderer.renderCommandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw RenderUnavailable() }
        blit.copy(
            from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: Self.size, height: Self.size, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let raw = buffer.contents().bindMemory(to: UInt8.self, capacity: byteCount)
        let pixels = Array(UnsafeBufferPointer(start: raw, count: byteCount))

        let mid = Self.size / 2
        let centre = Self.bgr(pixels, x: mid, y: mid)
        let corner = Self.bgr(pixels, x: 4, y: 4)
        #expect(centre.max()! > 60 && centre.max()! < 240, "live drawable box centre is \(centre)")
        #expect(corner.max()! < 20, "live drawable corner is \(corner), expected the clear colour")
    }
}
