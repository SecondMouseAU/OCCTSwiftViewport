// PickingConfiguration.swift
// ViewportKit
//
// Configuration for GPU-accelerated picking.

import Foundation

/// Configuration for the GPU pick ID buffer system.
public struct PickingConfiguration: Sendable {

    /// Whether the pick pass runs at all.
    ///
    /// When `false` the pick texture is never allocated and the second colour attachment goes
    /// unused, so turning picking off costs nothing in memory or bandwidth rather than merely
    /// discarding the results.
    public var isEnabled: Bool

    /// Pick tolerance radius in pixels for `performPick(at:)`.
    ///
    /// When > 0, the pick samples a square neighborhood of size `(2 * radius + 1)²` around
    /// the target pixel and returns the best non-background hit, preferring edges/vertices
    /// over faces when multiple primitives fall in range. This makes clicking thin edges
    /// and small vertices much easier without requiring pixel-perfect precision.
    ///
    /// Default is 0 (exact pixel pick). Values above 32 are clamped to 32 to bound
    /// GPU readback size; a value of 2–4 is recommended for CAD interaction.
    public var pickRadius: Int

    /// Whether what the pick pass writes follows the display mode.
    ///
    /// `true` (the default) writes faces only when the mode shows surfaces and a mesh body's
    /// edges and arcs only when it shows edges, so geometry the user can't see never wins a pick
    /// (the 1.3.0 behaviour). `false` writes every kind a body carries in every display mode:
    /// `.wireframe` picks faces and `.shaded` picks edges. Only the pick pass changes; nothing
    /// is drawn differently. See `docs/reference/Picking.md`.
    public var followsDisplayMode: Bool

    /// Creates a picking configuration.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether picking is active. Defaults to `false`.
    ///   - pickRadius: Pixel radius for neighborhood pick. Defaults to 0 (exact pixel).
    ///   - followsDisplayMode: Whether the pick pass writes only what the display mode shows.
    ///     Defaults to `true`.
    public init(isEnabled: Bool = false, pickRadius: Int = 0, followsDisplayMode: Bool = true) {
        self.isEnabled = isEnabled
        self.pickRadius = min(max(0, pickRadius), 32)
        self.followsDisplayMode = followsDisplayMode
    }
}
