// BoundsKeyTests.swift
// OCCTSwiftViewport Tests
//
// Issue #237: caches of per-body bounds must key on `ViewportBody.boundsKey`, not `generation`,
// so a body whose content is edited in place through a shared handle is re-measured.

import Foundation
import Testing
import os
import simd

@testable import OCCTSwiftViewport

/// A stand-in for any in-place-mutable body content: a box whose top can be raised through the
/// shared handle without touching the body that references it.
private final class RaisableBlock: InPlaceBodyContent, @unchecked Sendable {
    private struct State {
        var top: Float
        var version: UInt64 = 1
    }
    private let state: OSAllocatedUnfairLock<State>

    init(top: Float) { state = OSAllocatedUnfairLock(initialState: State(top: top)) }

    func raise(to top: Float) {
        state.withLock {
            $0.top = top
            $0.version &+= 1
        }
    }

    var contentBounds: BoundingBox? {
        BoundingBox(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(2, 2, state.withLock(\.top)))
    }

    var boundsVersion: UInt64 { state.withLock(\.version) }
}

@Suite("Bounds key (#237)")
@MainActor
struct BoundsKeyTests {

    private func body(id: String, top: Float, layer: RenderLayer = .geometry) -> (
        ViewportBody, RaisableBlock
    ) {
        let block = RaisableBlock(top: top)
        var body = ViewportBody(
            id: id, vertexData: [], indices: [], edges: [], color: SIMD4<Float>(1, 1, 1, 1),
            renderLayer: layer)
        body.inPlaceContent = block
        return (body, block)
    }

    @Test("boundsKey follows generation for an ordinary body")
    func boundsKeyOfOrdinaryBody() {
        var a = ViewportBody.box(id: "a")
        let copy = a
        #expect(a.boundsKey == copy.boundsKey)
        a.indices = a.indices + [0]
        #expect(a.boundsKey != copy.boundsKey)
    }

    @Test("an in-place edit changes boundsKey but not generation")
    func inPlaceEditChangesBoundsKey() {
        let (body, block) = body(id: "block", top: 1)
        let generation = body.generation
        let key = body.boundsKey
        block.raise(to: 5)
        #expect(body.generation == generation)
        #expect(body.boundsKey != key)
        #expect(body.boundingBox?.max.z == 5)
    }

    @Test("an in-place body is bounded by its content alone")
    func contentBoundsReplaceMeshBounds() {
        var (body, _) = body(id: "block", top: 3)
        body.edges = [[SIMD3<Float>(-100, -100, -100), SIMD3<Float>(100, 100, 100)]]
        #expect(body.boundingBox == BoundingBox(min: .zero, max: SIMD3<Float>(2, 2, 3)))
    }

    @Test("PivotStrategy re-measures a body raised in place")
    func pivotStrategyRefreshesAfterInPlaceEdit() {
        let strategy = PivotStrategy()
        let (body, block) = body(id: "block", top: 1)
        #expect(strategy.sceneBounds(of: [body])?.max.z == 1)

        block.raise(to: 9)
        // Fails when the cache keys on `generation`: the body value is unchanged.
        #expect(strategy.sceneBounds(of: [body])?.max.z == 9)
    }

    @Test("PivotStrategy's raycast cache sees the raised box")
    func pivotStrategyRaycastBoxRefreshes() {
        let strategy = PivotStrategy()
        let (body, block) = body(id: "block", top: 1)
        _ = strategy.sceneBounds(of: [body])
        block.raise(to: 9)
        _ = strategy.sceneBounds(of: [body])
        #expect(strategy.boundingBoxCache["block"]?.max.z == 9)
    }

    @Test("the overlay bounds cache re-measures a body raised in place")
    func overlayBoundsCacheRefreshes() {
        let controller = ViewportController()
        let (body, block) = body(id: "widget", top: 1, layer: .overlay)
        #expect(controller.cachedOverlayBounds(of: body)?.max.z == 1)

        block.raise(to: 7)
        // Fails when the cache keys on `generation`.
        #expect(controller.cachedOverlayBounds(of: body)?.max.z == 7)
    }

    @Test("a replaced handle takes a new generation")
    func assigningContentChangesGeneration() {
        var (body, _) = body(id: "block", top: 1)
        let generation = body.generation
        body.inPlaceContent = RaisableBlock(top: 4)
        #expect(body.generation != generation)
    }
}
