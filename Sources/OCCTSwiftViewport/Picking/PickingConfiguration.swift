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

    /// Creates a picking configuration.
    ///
    /// - Parameter isEnabled: Whether picking is active. Defaults to `false`.
    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }
}
