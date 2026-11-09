// Heightfield.swift
// OCCTSwiftViewport
//
// A dynamic heightfield surface (issue #139 spike): a grid of cell heights plus an 8-bit attribute
// per cell, displaced in the vertex stage and updated in place by rectangle.

import Foundation
import os
import simd

/// A rectangle of cells: `x`, `y` is the first cell, `width` x `height` the extent.
public struct HeightfieldRegion: Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The number of cells the rectangle covers.
    public var cellCount: Int { max(width, 0) * max(height, 0) }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// One past the last column and row.
    var maxX: Int { x + width }
    var maxY: Int { y + height }

    /// The part of the rectangle inside a `width` x `height` field, or `nil` when none is.
    func clamped(toWidth fieldWidth: Int, height fieldHeight: Int) -> HeightfieldRegion? {
        let x0 = max(x, 0)
        let y0 = max(y, 0)
        let x1 = min(maxX, fieldWidth)
        let y1 = min(maxY, fieldHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        return HeightfieldRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// How a heightfield's heights are stored on the GPU.
public enum HeightfieldPrecision: Sendable, Hashable {
    /// 32-bit floats (`r32Float`). The default.
    case float32
    /// 16-bit floats (`r16Float`): half the memory and upload size, 11 bits of mantissa.
    case float16
}

/// A grid of cell heights drawn as a displaced surface, with a per-cell attribute that selects a
/// colour from a 256-entry ramp (attribute 0 = untouched, shaded as the body's ordinary material).
///
/// A heightfield is a handle, not a value: attach it to a ``ViewportBody`` with
/// ``ViewportBody/heightfield`` and change it in place with ``replace(region:heights:attributes:ids:)``.
/// Nothing in SwiftUI state has to change for the viewport to pick the edit up: each renderer
/// remembers the version it last drew and uploads only the tiles that changed since. The same
/// handle can be drawn by any number of renderers at once.
///
/// Heights are body-local Z. Cell `(i, j)` occupies `origin + (i, j) * cellSize` to one cell
/// further; the surface passes through the cell centres, so the drawn mesh spans half a cell
/// inside that rectangle on every side.
public final class Heightfield: @unchecked Sendable {

    /// Entries in the colour ramp (and distinct attribute values).
    public static let rampSize = 256

    /// Cells along X.
    public let width: Int
    /// Cells along Y.
    public let height: Int
    /// Body-local XY of the corner of cell (0, 0).
    public let origin: SIMD2<Float>
    /// Body-local size of one cell.
    public let cellSize: SIMD2<Float>
    /// GPU storage precision of the heights. The CPU mirror is always 32-bit.
    public let precision: HeightfieldPrecision
    /// Whether the field keeps an integer id per cell, returned by picks.
    public let tracksIDs: Bool

    /// Change-log entries retained before a renderer that fell behind re-uploads everything.
    static let logCapacity = 4096

    private struct State {
        var heights: [Float]
        var attributes: [UInt8]
        var ids: [UInt32]
        var version: UInt64 = 1
        var log: [(version: UInt64, region: HeightfieldRegion)] = []
        /// The version of the newest edit trimmed from `log`: the log holds every later edit.
        var logFloor: UInt64 = 0
        var minHeight: Float
        var maxHeight: Float
        /// Bumped when `minHeight`/`maxHeight` grow, so cached bounds can be invalidated.
        var boundsVersion: UInt64 = 1
        var ramp: [SIMD4<Float>]
        var rampSpace: AuthoredColorSpace = .sRGB
        var rampVersion: UInt64 = 1
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Creates a field with every cell at `initialHeight`, attribute 0 and id 0.
    public convenience init(
        width: Int, height: Int, origin: SIMD2<Float> = .zero,
        cellSize: SIMD2<Float> = SIMD2(1, 1), initialHeight: Float = 0,
        precision: HeightfieldPrecision = .float32, tracksIDs: Bool = false
    ) {
        self.init(
            width: width, height: height, origin: origin, cellSize: cellSize,
            heights: [Float](repeating: initialHeight, count: max(width, 1) * max(height, 1)),
            precision: precision, tracksIDs: tracksIDs)
    }

    /// Creates a field from row-major `heights` (`width * height` values, row 0 first).
    public init(
        width: Int, height: Int, origin: SIMD2<Float> = .zero,
        cellSize: SIMD2<Float> = SIMD2(1, 1), heights: [Float],
        attributes: [UInt8]? = nil, ids: [UInt32]? = nil,
        precision: HeightfieldPrecision = .float32, tracksIDs: Bool = false
    ) {
        let w = max(width, 1)
        let h = max(height, 1)
        precondition(heights.count == w * h, "heights must hold width * height values")
        self.width = w
        self.height = h
        self.origin = origin
        self.cellSize = cellSize
        self.precision = precision
        let tracks = tracksIDs || ids != nil
        self.tracksIDs = tracks
        var lo = Float.infinity
        var hi = -Float.infinity
        for value in heights {
            lo = min(lo, value)
            hi = max(hi, value)
        }
        var ramp = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: Self.rampSize)
        for i in 1..<Self.rampSize {
            // A neutral default ramp so a freshly attributed cell is visible before the caller
            // supplies its own.
            let t = Float(i) / Float(Self.rampSize - 1)
            ramp[i] = SIMD4(t, 0.35 + 0.4 * (1 - t), 1 - t, 1)
        }
        self.state = OSAllocatedUnfairLock(
            initialState: State(
                heights: heights,
                attributes: attributes.flatMap { $0.count == w * h ? $0 : nil }
                    ?? [UInt8](repeating: 0, count: w * h),
                ids: tracks
                    ? (ids.flatMap { $0.count == w * h ? $0 : nil }
                        ?? [UInt32](repeating: 0, count: w * h)) : [],
                minHeight: lo, maxHeight: hi, ramp: ramp))
    }

    // MARK: - Reading

    /// Incremented by every ``replace(region:heights:attributes:ids:)`` and ramp change.
    public var version: UInt64 { state.withLock { $0.version } }

    /// The lowest and highest height the field has held.
    ///
    /// Running bounds: they grow with every edit and never shrink, so they can exceed the current
    /// extremes. ``recomputeHeightRange()`` makes them exact.
    public var heightRange: ClosedRange<Float> {
        state.withLock { $0.minHeight...$0.maxHeight }
    }

    /// Bumped whenever ``heightRange`` grows; a cached bounding box is stale when it changes.
    public var boundsVersion: UInt64 { state.withLock { $0.boundsVersion } }

    /// The body-local box of the surface.
    public var localBounds: BoundingBox {
        let range = heightRange
        return BoundingBox(
            min: SIMD3(origin.x, origin.y, range.lowerBound),
            max: SIMD3(
                origin.x + Float(width) * cellSize.x, origin.y + Float(height) * cellSize.y,
                range.upperBound))
    }

    /// The cell at `(x, y)`: its height, its attribute, and its id when ``tracksIDs``.
    public func sample(x: Int, y: Int) -> (height: Float, attribute: UInt8, id: UInt32?)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return state.withLock { s in
            let i = y * width + x
            return (s.heights[i], s.attributes[i], s.ids.isEmpty ? nil : s.ids[i])
        }
    }

    /// The cell containing the body-local point `(x, y)`, or `nil` outside the field.
    public func cell(atLocal point: SIMD2<Float>) -> SIMD2<Int>? {
        let c = (point - origin) / cellSize
        let ix = Int(c.x.rounded(.down))
        let iy = Int(c.y.rounded(.down))
        guard c.x >= 0, c.y >= 0, ix < width, iy < height else { return nil }
        return SIMD2(ix, iy)
    }

    // MARK: - Ramp

    /// The 256-entry colour ramp attributes index into, in ``rampColorSpace``. Entry 0 is never
    /// used: attribute 0 shades with the body's material.
    public var ramp: [SIMD4<Float>] {
        get { state.withLock { $0.ramp } }
        set {
            state.withLock { s in
                var padded = newValue
                if padded.count < Self.rampSize {
                    padded += [SIMD4<Float>](
                        repeating: padded.last ?? SIMD4(1, 1, 1, 1),
                        count: Self.rampSize - padded.count)
                }
                s.ramp = Array(padded.prefix(Self.rampSize))
                s.rampVersion &+= 1
                s.version &+= 1
            }
        }
    }

    /// The colour space of ``ramp``: sRGB display values (the default) or linear light.
    public var rampColorSpace: AuthoredColorSpace {
        get { state.withLock { $0.rampSpace } }
        set {
            state.withLock { s in
                s.rampSpace = newValue
                s.rampVersion &+= 1
                s.version &+= 1
            }
        }
    }

    // MARK: - Writing

    /// Replaces a rectangle of cells in place.
    ///
    /// `heights` is row-major with `region.width` values per row. `attributes` and `ids` are the
    /// same shape and `nil` leaves that channel as it was; `ids` is ignored unless ``tracksIDs``.
    /// A region that reaches past the field is clipped. The edit is cheap: it copies the rows
    /// into the CPU mirror and logs the rectangle; the GPU upload happens at the next draw, per
    /// 64 x 64 tile, however many edits piled up.
    public func replace(
        region: HeightfieldRegion, heights: [Float], attributes: [UInt8]? = nil,
        ids: [UInt32]? = nil
    ) {
        guard !region.isEmpty else { return }
        precondition(
            heights.count == region.cellCount, "heights must hold region.width * region.height")
        precondition(
            attributes == nil || attributes!.count == region.cellCount,
            "attributes must match the region")
        precondition(ids == nil || ids!.count == region.cellCount, "ids must match the region")
        guard let clipped = region.clamped(toWidth: width, height: height) else { return }
        let stride = region.width
        let fieldWidth = width
        let tracks = tracksIDs
        state.withLock { s in
            var lo = s.minHeight
            var hi = s.maxHeight
            for row in 0..<clipped.height {
                let src = (clipped.y - region.y + row) * stride + (clipped.x - region.x)
                let dst = (clipped.y + row) * fieldWidth + clipped.x
                heights.withUnsafeBufferPointer { h in
                    s.heights.withUnsafeMutableBufferPointer { m in
                        for i in 0..<clipped.width {
                            let v = h[src + i]
                            m[dst + i] = v
                            lo = min(lo, v)
                            hi = max(hi, v)
                        }
                    }
                }
                if let attributes {
                    attributes.withUnsafeBufferPointer { a in
                        s.attributes.withUnsafeMutableBufferPointer { m in
                            (m.baseAddress! + dst).update(
                                from: a.baseAddress! + src, count: clipped.width)
                        }
                    }
                }
                if tracks, let ids {
                    ids.withUnsafeBufferPointer { a in
                        s.ids.withUnsafeMutableBufferPointer { m in
                            (m.baseAddress! + dst).update(
                                from: a.baseAddress! + src, count: clipped.width)
                        }
                    }
                }
            }
            if lo < s.minHeight || hi > s.maxHeight { s.boundsVersion &+= 1 }
            s.minHeight = lo
            s.maxHeight = hi
            s.version &+= 1
            s.log.append((s.version, clipped))
            if s.log.count > Self.logCapacity * 2 {
                s.logFloor = s.log[Self.logCapacity - 1].version
                s.log.removeFirst(Self.logCapacity)
            }
        }
    }

    /// Recomputes ``heightRange`` from the current heights (O(cells)).
    public func recomputeHeightRange() {
        state.withLock { s in
            var lo = Float.infinity
            var hi = -Float.infinity
            for v in s.heights {
                lo = min(lo, v)
                hi = max(hi, v)
            }
            if lo != s.minHeight || hi != s.maxHeight { s.boundsVersion &+= 1 }
            s.minHeight = lo
            s.maxHeight = hi
        }
    }

    // MARK: - Renderer access

    /// What a renderer that last drew version `seen` must upload.
    enum Changes {
        case none
        case regions([HeightfieldRegion])
        case full
    }

    /// The edits after version `seen`, or `.full` when the log no longer reaches back to it.
    func changes(since seen: UInt64) -> (version: UInt64, changes: Changes, rampVersion: UInt64) {
        state.withLock { s in
            if seen == s.version { return (s.version, .none, s.rampVersion) }
            // Never drawn, or the edits since `seen` were trimmed from the log.
            guard seen > 0, seen >= s.logFloor else { return (s.version, .full, s.rampVersion) }
            let regions = s.log.filter { $0.version > seen }.map(\.region)
            return (s.version, regions.isEmpty ? .none : .regions(regions), s.rampVersion)
        }
    }

    /// Runs `body` over the CPU mirrors under the lock.
    func withMirrors<R>(
        _ body: (UnsafeBufferPointer<Float>, UnsafeBufferPointer<UInt8>) -> R
    ) -> R {
        state.withLockUnchecked { s in
            s.heights.withUnsafeBufferPointer { h in
                s.attributes.withUnsafeBufferPointer { a in body(h, a) }
            }
        }
    }

    /// The ramp, its colour space and its version, as the renderer uploads them.
    func rampSnapshot() -> (ramp: [SIMD4<Float>], space: AuthoredColorSpace, version: UInt64) {
        state.withLock { ($0.ramp, $0.rampSpace, $0.rampVersion) }
    }
}
