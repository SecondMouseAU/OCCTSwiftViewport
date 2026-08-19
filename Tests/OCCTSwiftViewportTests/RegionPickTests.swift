// RegionPickTests.swift
// OCCTSwiftViewport Tests
//
// Batched/region GPU pick readback (issue #90). `performRegionPick` blits an arbitrary
// screen-space rectangle from the private pick texture in one GPU round trip, then decodes
// and de-duplicates every primitive it touches. The GPU blit itself needs a live drawable to
// populate the pick texture (no headless pixel path, same caveat as the direct-mesh pick
// pass in DirectMeshRenderingTests), so these tests cover the two pieces that ARE pure
// functions: rectangle clamping (`clampRegionPickRect`) and raw-value decode/dedup
// (`decodeRegionPickResults`), plus the renderer-level early-out before any frame has drawn.

import Testing
import CoreGraphics
import simd
@testable import OCCTSwiftViewport

@Suite("Region pick rectangle clamping")
struct RegionPickClampTests {

    @Test("Rect fully inside the texture is returned unchanged")
    func fullyInside() {
        let r = ViewportRenderer.clampRegionPickRect(
            CGRect(x: 10, y: 20, width: 30, height: 40), textureWidth: 100, textureHeight: 100
        )
        #expect(r?.x == 10)
        #expect(r?.y == 20)
        #expect(r?.width == 30)
        #expect(r?.height == 40)
    }

    @Test("Negative origin is clamped to zero, size shrinks to match")
    func negativeOrigin() {
        let r = ViewportRenderer.clampRegionPickRect(
            CGRect(x: -5, y: -5, width: 15, height: 15), textureWidth: 100, textureHeight: 100
        )
        #expect(r?.x == 0)
        #expect(r?.y == 0)
        #expect(r?.width == 10)
        #expect(r?.height == 10)
    }

    @Test("Rect overflowing the far edge is clamped to the texture bounds")
    func overflowsFarEdge() {
        let r = ViewportRenderer.clampRegionPickRect(
            CGRect(x: 90, y: 90, width: 50, height: 50), textureWidth: 100, textureHeight: 100
        )
        #expect(r?.x == 90)
        #expect(r?.y == 90)
        #expect(r?.width == 10)
        #expect(r?.height == 10)
    }

    @Test("Rect entirely outside the texture returns nil")
    func entirelyOutside() {
        let r = ViewportRenderer.clampRegionPickRect(
            CGRect(x: 200, y: 200, width: 10, height: 10), textureWidth: 100, textureHeight: 100
        )
        #expect(r == nil)
    }

    @Test("Zero-size texture (no frame drawn yet) returns nil")
    func zeroSizeTexture() {
        let r = ViewportRenderer.clampRegionPickRect(
            CGRect(x: 0, y: 0, width: 10, height: 10), textureWidth: 0, textureHeight: 0
        )
        #expect(r == nil)
    }

    @Test("A single-point rect rounds outward to at least a 1x1 region")
    func fractionalRectRoundsOutward() {
        let r = ViewportRenderer.clampRegionPickRect(
            CGRect(x: 10.4, y: 10.4, width: 0.2, height: 0.2), textureWidth: 100, textureHeight: 100
        )
        #expect(r != nil)
        #expect((r?.width ?? 0) >= 1)
        #expect((r?.height ?? 0) >= 1)
    }
}

@Suite("Region pick row-stride alignment")
struct RegionPickAlignmentTests {

    @Test("A width whose byte count already lands on 256 is unchanged")
    func alreadyAligned() {
        // 64 pixels * 4 bytes = 256, exactly one alignment unit.
        #expect(ViewportRenderer.alignedBytesPerRow(forWidth: 64) == 256)
    }

    @Test("A narrow region still gets padded up to a full 256-byte row")
    func narrowRegionPadsToMinimum() {
        // 1 pixel * 4 bytes = 4, far short of 256.
        #expect(ViewportRenderer.alignedBytesPerRow(forWidth: 1) == 256)
    }

    @Test("A width just over an alignment boundary rounds up to the next one")
    func roundsUpPastBoundary() {
        // 65 pixels * 4 bytes = 260 -> next multiple of 256 is 512.
        #expect(ViewportRenderer.alignedBytesPerRow(forWidth: 65) == 512)
    }

    @Test("A wide region aligns without adding a spurious extra unit")
    func wideRegionAlignsExactly() {
        // 128 pixels * 4 bytes = 512, exactly two alignment units.
        #expect(ViewportRenderer.alignedBytesPerRow(forWidth: 128) == 512)
    }
}

@Suite("Region pick decode/dedup")
struct RegionPickDecodeTests {

    private static let map: [Int: String] = [0: "a", 5: "b", 7: "c"]

    @Test("Repeated pixels over the same primitive de-duplicate to one result")
    func dedupesRepeatedPrimitive() {
        // Same face on body 5, primitive 42, seen at every pixel in the region.
        let raw: UInt32 = (0 << 30) | (42 << 16) | 5
        let results = ViewportRenderer.decodeRegionPickResults(
            Array(repeating: raw, count: 9), indexMap: Self.map, layerMap: [:]
        )
        #expect(results.count == 1)
        #expect(results.first?.bodyID == "b")
        #expect(results.first?.triangleIndex == 42)
    }

    @Test("Sentinel (background) pixels are excluded")
    func excludesSentinel() {
        let hit: UInt32 = (0 << 30) | (1 << 16) | 0
        let values = [PickResult.sentinel, hit, PickResult.sentinel, PickResult.sentinel]
        let results = ViewportRenderer.decodeRegionPickResults(values, indexMap: Self.map, layerMap: [:])
        #expect(results.count == 1)
        #expect(results.first?.bodyID == "a")
    }

    @Test("An all-background region decodes to an empty array")
    func allBackgroundIsEmpty() {
        let results = ViewportRenderer.decodeRegionPickResults(
            Array(repeating: PickResult.sentinel, count: 25), indexMap: Self.map, layerMap: [:]
        )
        #expect(results.isEmpty)
    }

    @Test("Distinct primitives are preserved in order of first appearance")
    func preservesFirstAppearanceOrder() {
        let faceB: UInt32 = (0 << 30) | (1 << 16) | 5    // body b, face 1
        let edgeA: UInt32 = (1 << 30) | (2 << 16) | 0    // body a, edge 2
        let faceC: UInt32 = (0 << 30) | (3 << 16) | 7    // body c, face 3
        // faceB repeats later, so it must not shift its position or duplicate it.
        let values = [faceB, edgeA, faceB, faceC, edgeA]
        let results = ViewportRenderer.decodeRegionPickResults(values, indexMap: Self.map, layerMap: [:])
        #expect(results.map(\.bodyID) == ["b", "a", "c"])
        #expect(results.map(\.kind) == [.face, .edge, .face])
    }

    @Test("A raw value whose objectIndex has no map entry is dropped, not crashed on")
    func unknownObjectIndexDropped() {
        let unknown: UInt32 = (0 << 30) | (1 << 16) | 999
        let known: UInt32 = (0 << 30) | (1 << 16) | 0
        let results = ViewportRenderer.decodeRegionPickResults([unknown, known], indexMap: Self.map, layerMap: [:])
        #expect(results.count == 1)
        #expect(results.first?.bodyID == "a")
    }

    @Test("Results route through the same PickLayer map performPick uses")
    func respectsLayerMap() {
        let raw: UInt32 = (0 << 30) | (1 << 16) | 5
        let results = ViewportRenderer.decodeRegionPickResults(
            [raw], indexMap: Self.map, layerMap: ["b": .widget]
        )
        #expect(results.first?.pickLayer == .widget)
    }

    @Test("Region results compose with PickResultFilter exactly like a single performPick result")
    func composesWithPickResultFilter() {
        let face: UInt32 = (0 << 30) | (1 << 16) | 0
        let edge: UInt32 = (1 << 30) | (1 << 16) | 5
        let results = ViewportRenderer.decodeRegionPickResults([face, edge], indexMap: Self.map, layerMap: [:])
        let facesOnly = results.filter(PickResultFilter.faces.matches)
        #expect(facesOnly.count == 1)
        #expect(facesOnly.first?.kind == .face)
    }
}

@MainActor
@Suite("ViewportRenderer.performRegionPick")
struct RegionPickRendererTests {

    @Test("Before any frame has drawn, the pick texture is empty and the region pick completes with []")
    func emptyBeforeFirstDraw() {
        let controller = ViewportController()
        let bodies = [ViewportBody.box(id: "box")]
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }

        // performRegionPick's completion is @Sendable (it also fires from a Metal completion
        // handler off the main thread in the live-texture path), so a plain `var` can't be
        // mutated from it under strict concurrency even though this early-out path calls back
        // synchronously. A tiny reference box sidesteps that without weakening the real API.
        final class ResultBox: @unchecked Sendable {
            var value: [PickResult]?
        }
        let box = ResultBox()
        renderer.performRegionPick(rect: CGRect(x: 0, y: 0, width: 64, height: 64)) { results in
            box.value = results
        }
        #expect(box.value == [])
    }
}

@Suite("ViewportController selectionFilter routing for region picks")
struct RegionPickSelectionFilterTests {

    private static let map: [Int: String] = [0: "a", 5: "b"]

    @Test("No filter set passes every result through unchanged")
    func noFilterPassesThrough() {
        let face: UInt32 = (0 << 30) | (1 << 16) | 0
        let edge: UInt32 = (1 << 30) | (1 << 16) | 5
        let results = ViewportRenderer.decodeRegionPickResults([face, edge], indexMap: Self.map, layerMap: [:])
        let routed = ViewportController.applySelectionFilter(results, filter: nil)
        #expect(routed.count == 2)
    }

    @Test("A user-geometry result failing the filter is dropped")
    func filterDropsFailingUserGeometry() {
        let face: UInt32 = (0 << 30) | (1 << 16) | 0
        let edge: UInt32 = (1 << 30) | (1 << 16) | 5
        let results = ViewportRenderer.decodeRegionPickResults([face, edge], indexMap: Self.map, layerMap: [:])
        let routed = ViewportController.applySelectionFilter(results, filter: .faces)
        #expect(routed.map(\.kind) == [.face])
    }

    @Test("A widget-layer result bypasses the filter, mirroring handlePick(result:)")
    func widgetLayerBypassesFilter() {
        let widgetEdge: UInt32 = (1 << 30) | (1 << 16) | 5
        let layerMap: [String: PickLayer] = ["b": .widget]
        let results = ViewportRenderer.decodeRegionPickResults([widgetEdge], indexMap: Self.map, layerMap: layerMap)
        // .faces filter would normally reject an edge, but it's on the widget layer.
        let routed = ViewportController.applySelectionFilter(results, filter: .faces)
        #expect(routed.count == 1)
        #expect(routed.first?.pickLayer == .widget)
    }
}

@MainActor
@Suite("ViewportController.performRegionPick")
struct RegionPickControllerTests {

    /// Reference box for capturing results out of a @Sendable completion. See the note in
    /// `RegionPickRendererTests.emptyBeforeFirstDraw`.
    private final class ResultBox: @unchecked Sendable {
        var value: [PickResult]?
    }

    @Test("A controller with no attached renderer completes region picks with []")
    func noAttachedRendererIsEmpty() {
        let controller = ViewportController()
        let box = ResultBox()
        controller.performRegionPick(pixelRect: CGRect(x: 0, y: 0, width: 32, height: 32)) { results in
            box.value = results
        }
        #expect(box.value == [])
    }

    @Test("Constructing a ViewportRenderer attaches it to its controller (issue #90 wiring)")
    func rendererAttachesToController() {
        let controller = ViewportController()
        #expect(controller.attachedRenderer == nil)
        let bodies = [ViewportBody.box(id: "box")]
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(controller.attachedRenderer === renderer)
    }

    @Test("drawablePixelSize is .zero before any frame has drawn")
    func drawablePixelSizeZeroBeforeFirstDraw() {
        let controller = ViewportController()
        #expect(controller.drawablePixelSize == .zero)
        let bodies = [ViewportBody.box(id: "box")]
        guard ViewportRenderer(controller: controller, bodies: .constant(bodies)) != nil else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(controller.drawablePixelSize == .zero)
    }
}
