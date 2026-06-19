// DisplayMode.swift
// ViewportKit
//
// Display modes for rendering geometry.

import Foundation

/// Display mode for rendering geometry in the viewport.
///
/// Different display modes provide different visual representations
/// of 3D content, from simple wireframes to fully lit shaded views.
public enum DisplayMode: String, CaseIterable, Sendable {

    /// Wireframe rendering - edges only.
    case wireframe

    /// Shaded rendering with lighting.
    case shaded

    /// Shaded with visible edges overlay.
    case shadedWithEdges

    /// Flat shading without smooth interpolation.
    case flat

    /// Unlit / flat-colour rendering — each body drawn in its constant base colour
    /// with no lighting, ambient, shadows, fresnel, or tone mapping. Intended for
    /// diagnostic / debug renders where faithful, distinguishable per-body colours
    /// matter more than realistic shading (issue #77).
    case unlit

    /// X-ray mode - transparent with visible internal edges.
    case xray

    /// Rendered with materials and textures.
    case rendered

    // MARK: - Properties

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .wireframe: return "Wireframe"
        case .shaded: return "Shaded"
        case .shadedWithEdges: return "Shaded + Edges"
        case .flat: return "Flat"
        case .unlit: return "Unlit"
        case .xray: return "X-Ray"
        case .rendered: return "Rendered"
        }
    }

    /// Whether this mode shows surface shading.
    public var showsSurfaces: Bool {
        switch self {
        case .wireframe:
            return false
        case .shaded, .shadedWithEdges, .flat, .unlit, .xray, .rendered:
            return true
        }
    }

    /// Whether this mode shows edges.
    public var showsEdges: Bool {
        switch self {
        case .wireframe, .shadedWithEdges, .xray:
            return true
        case .shaded, .flat, .unlit, .rendered:
            return false
        }
    }

    /// Whether this mode uses smooth shading.
    public var usesSmoothShading: Bool {
        switch self {
        case .flat:
            return false
        case .wireframe, .shaded, .shadedWithEdges, .unlit, .xray, .rendered:
            return true
        }
    }

    /// Whether this mode shows transparency.
    public var usesTransparency: Bool {
        self == .xray
    }

    /// Keyboard shortcut for this mode.
    public var keyboardShortcut: Character? {
        switch self {
        case .wireframe: return "w"
        case .shaded: return "s"
        case .shadedWithEdges: return "e"
        case .xray: return "x"
        default: return nil
        }
    }
}
