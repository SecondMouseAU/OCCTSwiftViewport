// ViewportModifierKeys.swift
// ViewportKit
//
// Platform-neutral keyboard-modifier abstraction for input interpretation —
// an Aspect_VKey analogue.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Platform-neutral keyboard-modifier state used to interpret viewport input.
///
/// This is the OCCTSwiftViewport analogue of OCCT's `Aspect_VKeyFlags`: it
/// decouples gesture interpretation from `NSEvent.ModifierFlags` (AppKit) and
/// `UIKeyModifierFlags` (UIKit) so the same mapping logic can be driven by any
/// input source — AppKit, UIKit, or (future) visionOS / synthetic input.
///
/// Bridge from a platform type with the `init(_:)` overloads, then resolve an
/// action via `GestureConfiguration.dragAction(for:)`.
public struct ViewportModifierKeys: OptionSet, Sendable, Hashable {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Shift key.
    public static let shift = ViewportModifierKeys(rawValue: 1 << 0)

    /// Control key.
    public static let control = ViewportModifierKeys(rawValue: 1 << 1)

    /// Option / Alt key.
    public static let option = ViewportModifierKeys(rawValue: 1 << 2)

    /// Command / Meta key.
    public static let command = ViewportModifierKeys(rawValue: 1 << 3)
}

#if canImport(AppKit)
extension ViewportModifierKeys {

    /// Bridges AppKit modifier flags into the portable representation.
    public init(_ flags: NSEvent.ModifierFlags) {
        var keys: ViewportModifierKeys = []
        if flags.contains(.shift) { keys.insert(.shift) }
        if flags.contains(.control) { keys.insert(.control) }
        if flags.contains(.option) { keys.insert(.option) }
        if flags.contains(.command) { keys.insert(.command) }
        self = keys
    }
}
#endif

#if canImport(UIKit)
import UIKit

extension ViewportModifierKeys {

    /// Bridges UIKit key-modifier flags into the portable representation.
    public init(_ flags: UIKeyModifierFlags) {
        var keys: ViewportModifierKeys = []
        if flags.contains(.shift) { keys.insert(.shift) }
        if flags.contains(.control) { keys.insert(.control) }
        if flags.contains(.alternate) { keys.insert(.option) }
        if flags.contains(.command) { keys.insert(.command) }
        self = keys
    }
}
#endif
