// OffscreenPickMap.swift
// OCCTSwiftViewport
//
// The result of an OffscreenRenderer GPU pick pass: the whole pick texture on the CPU, with the
// same decoding ViewportRenderer.performPick and performRegionPick apply to theirs.

import CoreGraphics
import Foundation

/// The pick texture of one offscreen render, read back to the CPU.
///
/// `OffscreenRenderer.renderPickMap(bodies:options:)` runs the same GPU pick pass a live viewport
/// does and returns this: one texel per pixel, naming the body, primitive and kind under it.
/// Picking from it is then a lookup, so any number of pixels, neighbourhoods and regions cost one
/// render.
///
/// `pick(at:)` and `pickRegion(_:)` mirror `ViewportRenderer.performPick(at:completion:)` and
/// `performRegionPick(rect:completion:)`, and decode through the same functions, so for the same
/// scene and camera they return the same `PickResult`s. Pixel coordinates are in render pixels,
/// origin at the top left, as `performPick` takes drawable pixels.
public struct OffscreenPickMap: Sendable {

    /// Width in pixels; the render's `OffscreenRenderOptions.width`.
    public let width: Int

    /// Height in pixels; the render's `OffscreenRenderOptions.height`.
    public let height: Int

    /// The tolerance radius `pick(at:)` samples with, from `OffscreenRenderOptions.pickRadius`.
    public let pickRadius: Int

    /// The filter picks pass through, from `OffscreenRenderOptions.selectionFilter`.
    public let selectionFilter: PickResultFilter?

    /// The RG32Uint pick texels, row-major, each as `G << 32 | R` (see `PickEncoding`).
    let texels: [UInt64]

    /// Body ID by draw-order index, over the visible bodies the render was given.
    let indexMap: [Int: String]

    /// Pick layer by body ID.
    let layerMap: [String: PickLayer]

    /// The heightfield handle of each heightfield body the render drew, by body ID, so a pick on
    /// one carries its cell data.
    let heightfields: [String: Heightfield]

    /// What is under `pixel`: the body, primitive and kind a live `performPick` reports there, or
    /// `nil` for background.
    ///
    /// With `pickRadius` 0 this reads the exact pixel, clamped to the render. Above 0 it reads the
    /// `(2 * pickRadius + 1)` square around it and returns the best hit: a vertex over an edge
    /// over a face, the nearest of equals. A result the `selectionFilter` rejects is a miss,
    /// except a `PickLayer.widget` hit, which bypasses it as live.
    public func pick(at pixel: SIMD2<Int>) -> PickResult? {
        let result: PickResult?
        if pickRadius <= 0 {
            result = exactPick(at: pixel)
        } else {
            result = neighborhoodPick(at: pixel, radius: min(pickRadius, 32))
        }
        return ViewportController.applySelectionFilter(result, filter: selectionFilter)
    }

    /// Every distinct primitive under `rect`, in scan order of first appearance.
    ///
    /// `rect` is in render pixels and is clamped to the render; one that misses it, and background,
    /// give `[]`. As `performRegionPick(rect:completion:)` returns, filtered by `selectionFilter`
    /// with the widget bypass.
    public func pickRegion(_ rect: CGRect) -> [PickResult] {
        guard
            let region = ViewportRenderer.clampRegionPickRect(
                rect, textureWidth: width, textureHeight: height)
        else { return [] }
        let results = ViewportRenderer.decodeRegionPickResults(
            texels(in: region), indexMap: indexMap, layerMap: layerMap,
            heightfields: heightfields)
        return ViewportController.applySelectionFilter(results, filter: selectionFilter)
    }

    // MARK: - Private

    private func exactPick(at pixel: SIMD2<Int>) -> PickResult? {
        guard width > 0, height > 0 else { return nil }
        let x = max(0, min(pixel.x, width - 1))
        let y = max(0, min(pixel.y, height - 1))
        return PickResult(
            pickValue: texels[y * width + x], indexMap: indexMap, layerMap: layerMap,
            heightfields: heightfields)
    }

    private func neighborhoodPick(at pixel: SIMD2<Int>, radius: Int) -> PickResult? {
        guard
            let region = ViewportRenderer.clampPickNeighborhood(
                around: pixel, radius: radius, textureWidth: width, textureHeight: height)
        else { return nil }
        return ViewportRenderer.bestNeighborhoodPickResult(
            texels(in: region), width: region.width,
            center: SIMD2(pixel.x - region.x, pixel.y - region.y),
            indexMap: indexMap, layerMap: layerMap, heightfields: heightfields)
    }

    /// The texels of `region` as one flat row-major array.
    private func texels(in region: (x: Int, y: Int, width: Int, height: Int)) -> [UInt64] {
        var values: [UInt64] = []
        values.reserveCapacity(region.width * region.height)
        for row in region.y..<(region.y + region.height) {
            let start = row * width + region.x
            values.append(contentsOf: texels[start..<(start + region.width)])
        }
        return values
    }
}
