// HeightfieldTypeTests.swift
// OCCTSwiftViewport Tests
//
// The CPU side of `Heightfield`: validation and its documented maximum, the running height range
// and how it is reset, and the settings that steer the GPU path.

import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Heightfield type (#139)")
struct HeightfieldTypeTests {

    // MARK: Validation

    @Test("A side under 2 cells throws before anything is allocated")
    func tooSmallThrows() {
        #expect(throws: HeightfieldError.sizeTooSmall(width: 1, height: 10)) {
            try Heightfield(width: 1, height: 10)
        }
        #expect(throws: HeightfieldError.sizeTooSmall(width: 10, height: 0)) {
            try Heightfield(width: 10, height: 0)
        }
        #expect(throws: HeightfieldError.sizeTooSmall(width: -4, height: 3)) {
            try Heightfield(width: -4, height: 3)
        }
    }

    @Test("A side over the maximum throws, however large, without allocating")
    func tooLargeThrows() {
        let maximum = Heightfield.maximumDimension
        #expect(
            throws: HeightfieldError.sizeExceedsMaximum(
                width: maximum + 1, height: 2, maximum: maximum)
        ) {
            try Heightfield(width: maximum + 1, height: 2)
        }
        // Would overflow `width * height` or exhaust memory if it were multiplied first.
        #expect(throws: HeightfieldError.self) {
            try Heightfield(width: 1 << 40, height: 1 << 40)
        }
        #expect(throws: HeightfieldError.self) {
            try Heightfield(width: 4, height: maximum + 1, heights: [])
        }
    }

    @Test("The maximum is exactly the widest field whose padded height texture fits 16,384 texels")
    func maximumMatchesTextureLimit() throws {
        func paddedSide(_ cells: Int) -> Int {
            (HeightfieldLayout.drawTileCount(cells: cells) + 1) * HeightfieldLayout.tileCells
        }
        let maximum = Heightfield.maximumDimension
        #expect(paddedSide(maximum) <= 16_384)
        #expect(paddedSide(maximum + 1) > 16_384)

        let widest = try Heightfield(width: maximum, height: 2)
        #expect(widest.width == maximum)
    }

    @Test("Arrays that do not hold one value per cell throw, naming the array")
    func countMismatchThrows() {
        #expect(throws: HeightfieldError.countMismatch(name: "heights", expected: 12, actual: 11)) {
            try Heightfield(width: 4, height: 3, heights: [Float](repeating: 0, count: 11))
        }
        #expect(
            throws: HeightfieldError.countMismatch(name: "attributes", expected: 12, actual: 5)
        ) {
            try Heightfield(
                width: 4, height: 3, heights: [Float](repeating: 0, count: 12),
                attributes: [UInt8](repeating: 0, count: 5))
        }
        #expect(throws: HeightfieldError.countMismatch(name: "ids", expected: 12, actual: 13)) {
            try Heightfield(
                width: 4, height: 3, heights: [Float](repeating: 0, count: 12),
                ids: [UInt32](repeating: 0, count: 13))
        }
    }

    @Test("A cell size that is not finite and positive throws")
    func invalidCellSizeThrows() {
        for size in [SIMD2<Float>(0, 1), SIMD2(1, -1), SIMD2(.infinity, 1), SIMD2(1, .nan)] {
            #expect(throws: HeightfieldError.self) {
                try Heightfield(width: 4, height: 4, cellSize: size)
            }
        }
    }

    @Test("Errors describe themselves")
    func errorDescriptions() {
        let text = HeightfieldError.sizeExceedsMaximum(width: 20_000, height: 4, maximum: 16_321)
            .description
        #expect(text.contains("20000"))
        #expect(text.contains("16321"))
    }

    // MARK: Height range

    @Test("A replace that lowers the surface leaves the running range; recompute makes it exact")
    func rangeAfterLowering() throws {
        let field = try Heightfield(width: 100, height: 100, initialHeight: 10)
        field.replace(
            region: HeightfieldRegion(x: 40, y: 40, width: 20, height: 20),
            heights: [Float](repeating: 30, count: 400))
        #expect(field.heightRange == 10...30)

        // Lower the raised block back down: the running range does not shrink.
        field.replace(
            region: HeightfieldRegion(x: 40, y: 40, width: 20, height: 20),
            heights: [Float](repeating: 2, count: 400))
        #expect(field.heightRange == 2...30)
        #expect(field.localBounds.max.z == 30)

        let before = field.boundsVersion
        field.recomputeHeightRange()
        #expect(field.heightRange == 2...10)
        #expect(field.localBounds.max.z == 10)
        #expect(field.boundsVersion != before)
    }

    @Test("Recomputing an already exact range leaves boundsVersion alone")
    func recomputeWithoutChange() throws {
        let field = try Heightfield(width: 8, height: 8, initialHeight: 3)
        let before = field.boundsVersion
        field.recomputeHeightRange()
        #expect(field.heightRange == 3...3)
        #expect(field.boundsVersion == before)
    }

    @Test("A cached scene box follows a field raised and then recomputed in place")
    func sceneBoundsFollowRangeChanges() throws {
        let field = try Heightfield(width: 64, height: 64, initialHeight: 1)
        let body = ViewportBody(
            id: "field", vertexData: [], indices: [], edges: [], color: SIMD4(1, 1, 1, 1),
            heightfield: field)
        let strategy = PivotStrategy()
        let generation = body.generation
        #expect(strategy.sceneBounds(of: [body])?.max.z == 1)

        field.replace(
            region: HeightfieldRegion(x: 10, y: 10, width: 8, height: 8),
            heights: [Float](repeating: 25, count: 64))
        #expect(body.generation == generation)
        #expect(strategy.sceneBounds(of: [body])?.max.z == 25)

        field.replace(
            region: HeightfieldRegion(x: 10, y: 10, width: 8, height: 8),
            heights: [Float](repeating: 1, count: 64))
        field.recomputeHeightRange()
        #expect(strategy.sceneBounds(of: [body])?.max.z == 1)
    }

    @Test("A heightfield body is bounded by the field, not its mesh arrays")
    func bodyBoundsAreTheField() throws {
        let field = try Heightfield(
            width: 10, height: 20, origin: SIMD2(5, -5), cellSize: SIMD2(2, 3), initialHeight: 4)
        var body = ViewportBody(
            id: "field", vertexData: [], indices: [], edges: [[SIMD3(-99, -99, -99)]],
            color: SIMD4(1, 1, 1, 1), heightfield: field)
        #expect(
            body.boundingBox
                == BoundingBox(min: SIMD3(5, -5, 4), max: SIMD3(25, 55, 4)))
        let generation = body.generation
        body.heightfield = nil
        #expect(body.generation != generation)
        #expect(body.heightfield == nil)
    }

    // MARK: GPU settings

    @Test("Half-float heights fall back to 32-bit where the platform cannot write them")
    func halfFloatFallsBack() {
        #expect(HeightfieldGPU.storageFormat(for: .float16, supportsHalf: true) == .r16Float)
        #expect(HeightfieldGPU.storageFormat(for: .float16, supportsHalf: false) == .r32Float)
        #expect(HeightfieldGPU.storageFormat(for: .float32, supportsHalf: true) == .r32Float)
        #expect(HeightfieldGPU.storageFormat(for: .float32, supportsHalf: false) == .r32Float)
        #if arch(arm64)
            #expect(HeightfieldGPU.supportsHalf)
        #else
            #expect(!HeightfieldGPU.supportsHalf)
        #endif
    }

    @Test("The mesh cell target defaults to 4 px and is exposed on both configurations")
    func meshCellPixelsSetting() {
        #expect(Heightfield.defaultMeshCellPixels == 4)
        #expect(ViewportConfiguration().heightfieldMeshCellPixels == 4)
        #expect(OffscreenRenderOptions().heightfieldMeshCellPixels == 4)

        var config = ViewportConfiguration()
        config.heightfieldMeshCellPixels = 6
        let controller = ViewportController(configuration: config)
        let options = OffscreenRenderOptions(matching: controller, width: 16, height: 16)
        #expect(options.heightfieldMeshCellPixels == 6)
    }
}
