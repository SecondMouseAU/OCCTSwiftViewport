// BenchHeightfieldScene.swift
// Issue #139: the field the benchmark draws and the edits it applies. The terrain generator and
// the edit regions are the ones the spike's own tests use, so numbers line up with its notes.

import OCCTSwiftViewport
import SwiftUI
import simd

enum BenchHeightfieldScene {

    static let fieldSize = 2000
    static let editSize = SIMD2(130, 120)

    // MARK: Terrain

    /// A hash in -1...1, the same for a cell every time.
    static func noise(_ x: Int, _ y: Int) -> Float {
        var h =
            UInt32(truncatingIfNeeded: x) &* 374_761_393 &+ UInt32(truncatingIfNeeded: y)
            &* 668_265_263
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 32_767.5 - 1
    }

    /// Rolling terrain with cell-scale roughness, in cells, so every level of detail has
    /// something different to represent.
    static func terrain(_ x: Int, _ y: Int) -> Float {
        40 * sin(Float(x) * 0.004) * cos(Float(y) * 0.005)
            + 15 * sin(Float(x) * 0.02 + Float(y) * 0.015) + 10 * noise(x, y)
    }

    static func terrainHeights(size: Int = fieldSize) -> [Float] {
        var heights = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size { heights[y * size + x] = terrain(x, y) }
        }
        return heights
    }

    // MARK: Field

    /// A colour ramp from blue through green to red; entry 0 is unused (attribute 0 = no colour).
    static let ramp: [SIMD4<Float>] = (0..<Heightfield.rampSize).map { i in
        let t = Float(i) / Float(Heightfield.rampSize - 1)
        let hue = (1 - t) * 0.66
        let c = simd_float3(
            abs(hue * 6 - 3) - 1, 2 - abs(hue * 6 - 2), 2 - abs(hue * 6 - 4)
        )
        let rgb = simd_clamp(c, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        return SIMD4(rgb.x, rgb.y, rgb.z, 1)
    }

    /// A field over `heights`. With `rampPainted`, every cell's attribute is its height quantised
    /// to 1...254, so the ramp shows as contour bands over the whole field.
    static func makeField(
        heights: [Float], size: Int = fieldSize, float16: Bool, rampPainted: Bool,
        tracksIDs: Bool
    ) throws -> Heightfield {
        var attributes: [UInt8]?
        if rampPainted {
            let lo = heights.min() ?? 0
            let span = max((heights.max() ?? 1) - lo, 1e-3)
            attributes = heights.map { UInt8(1 + min(253, Int((($0 - lo) / span) * 254))) }
        }
        // An id per 100 x 100 block, so a pick shows something other than 0.
        var ids: [UInt32]?
        if tracksIDs {
            var blocks = [UInt32](repeating: 0, count: size * size)
            for y in 0..<size {
                for x in 0..<size { blocks[y * size + x] = UInt32((y / 100) * 100 + x / 100) }
            }
            ids = blocks
        }
        // Throws HeightfieldError for a size outside 2...maximumDimension or a count mismatch.
        let field = try Heightfield(
            width: size, height: size, heights: heights, attributes: attributes, ids: ids,
            precision: float16 ? .float16 : .float32, tracksIDs: tracksIDs)
        field.ramp = ramp
        return field
    }

    static func body(_ field: Heightfield) -> ViewportBody {
        var body = ViewportBody(
            id: "field", vertexData: [], indices: [], edges: [], color: SIMD4(0.25, 0.65, 0.3, 1),
            heightfield: field)
        body.isPickable = true
        return body
    }

    // MARK: Camera

    /// The camera orbiting the field's centre, `frame` frames into the orbit.
    static func orbitCamera(frame: Int) -> CameraState {
        CameraState(
            rotation: simd_quatf(angle: Float(frame) * 0.03, axis: SIMD3(0, 0, 1))
                * simd_quatf(angle: 0.9, axis: SIMD3(1, 0, 0)),
            distance: 2600, pivot: SIMD3(1000, 1000, 0))
    }

    // MARK: Edits

    enum EditPattern: String, CaseIterable, Identifiable {
        /// Regions that each move one cell from the last, so almost all of each overlaps it.
        case sliding
        /// Regions that tile the field without overlapping.
        case disjoint

        var id: String { rawValue }
    }

    /// `count` regions of 130 x 120 cells per frame, with the payloads built up front so only
    /// `Heightfield.replace` is timed when they are applied. Two height payloads alternate
    /// frame to frame so every edit really changes the field.
    struct EditLoad {
        var regions: [HeightfieldRegion]
        var heights: [[[Float]]]
        var attributes: [[UInt8]]
        var ids: [[UInt32]]

        var count: Int { regions.count }

        init(count: Int, pattern: EditPattern, field: Heightfield) {
            let size = BenchHeightfieldScene.editSize
            var list: [HeightfieldRegion] = []
            switch pattern {
            case .sliding:
                list = (0..<count).map {
                    HeightfieldRegion(
                        x: 700 + $0 % 40, y: 800 + $0 / 40, width: size.x, height: size.y)
                }
            case .disjoint:
                var y = 0
                while y + size.y <= field.height, list.count < count {
                    var x = 0
                    while x + size.x <= field.width, list.count < count {
                        list.append(HeightfieldRegion(x: x, y: y, width: size.x, height: size.y))
                        x += size.x
                    }
                    y += size.y
                }
            }
            let regionList = list
            regions = regionList
            heights = [0, 1].map { variant in
                regionList.enumerated().map { index, region in
                    (0..<region.cellCount).map {
                        30 * BenchHeightfieldScene.noise(
                            $0 % region.width + (index + variant * 1000) * 7,
                            $0 / region.width + index + variant * 1000)
                            + Float((index + variant * 1000) % 13)
                    }
                }
            }
            attributes = regionList.enumerated().map { index, region in
                (0..<region.cellCount).map { UInt8(1 + (($0 / 5 + index) % 250)) }
            }
            ids = regionList.enumerated().map { index, region in
                [UInt32](repeating: UInt32(10_000 + index), count: region.cellCount)
            }
        }

        /// Applies every edit for `frame`.
        func apply(to field: Heightfield, frame: Int) {
            let variant = frame & 1
            for (index, region) in regions.enumerated() {
                field.replace(
                    region: region, heights: heights[variant][index],
                    attributes: attributes[index], ids: ids[index])
            }
        }
    }
}
