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
    /// Default is 0 (exact pixel pick). A value of 2–4 is recommended for CAD interaction.
    public var pickRadius: Int

    /// Creates a picking configuration.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether picking is active. Defaults to `false`.
    ///   - pickRadius: Pixel radius for neighborhood pick. Defaults to 0 (exact pixel).
    public init(isEnabled: Bool = false, pickRadius: Int = 0) {
        self.isEnabled = isEnabled
        self.pickRadius = max(0, pickRadius)
    }
}
