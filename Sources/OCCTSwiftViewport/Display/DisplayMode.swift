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

    /// Faceted shading: lit like `.shaded`, but each triangle uses its own face normal, so the
    /// tessellation's facets show instead of being smoothed by the vertex normals.
    case flat

    /// Unlit / flat-colour rendering, with each body drawn in its constant base colour
    /// with no lighting, ambient, shadows, fresnel, or tone mapping. Intended for
    /// diagnostic / debug renders where faithful, distinguishable per-body colours
    /// matter more than realistic shading (issue #77).
    case unlit

    /// X-ray mode: see-through surfaces with edges.
    ///
    /// Every geometry-layer surface is drawn in the translucent pass at no more than the x-ray
    /// opacity setting (`ViewportController.xrayOpacity` / `OffscreenRenderOptions.xrayOpacity`,
    /// default ``defaultXRayOpacity``), without writing depth, so bodies and edges behind it show
    /// through.
    case xray

    /// Rendered: currently draws exactly like `.shaded`.
    ///
    /// `.shaded` is already the full physically based path (PBR materials, image-based lighting,
    /// shadows, SSAO, TAA), and each of those is switched by `LightingConfiguration` and
    /// `ViewportController` settings, not by the display mode. `.rendered` is kept as its own case
    /// so apps can label a "final look" view, but it adds nothing on top of `.shaded`.
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
    ///
    /// Surfaces are stamped into the GPU pick buffer only when this is `true`, so hidden faces
    /// can't win a pick in `.wireframe`.
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

    /// Whether this mode shades with the interpolated vertex normals.
    ///
    /// `false` only for `.flat`, which the renderers draw with per-triangle face normals instead.
    public var usesSmoothShading: Bool {
        switch self {
        case .flat:
            return false
        case .wireframe, .shaded, .shadedWithEdges, .unlit, .xray, .rendered:
            return true
        }
    }

    /// Whether this mode draws every surface translucent.
    ///
    /// `true` only for `.xray`: the renderers then route all geometry-layer surfaces through the
    /// sorted, depth-write-off translucent pass at
    /// ``surfaceOpacity(forMaterialOpacity:xrayOpacity:)``.
    public var usesTransparency: Bool {
        self == .xray
    }

    /// Default opacity ceiling for surfaces in `.xray` mode.
    ///
    /// The default of both `ViewportConfiguration.xrayOpacity` (and so
    /// `ViewportController.xrayOpacity`) and `OffscreenRenderOptions.xrayOpacity`.
    public static let defaultXRayOpacity: Float = 0.4

    /// Clamps an x-ray opacity setting to `0...1`.
    ///
    /// A non-finite value (NaN or infinity) falls back to ``defaultXRayOpacity``.
    public static func clampedXRayOpacity(_ opacity: Float) -> Float {
        guard opacity.isFinite else { return defaultXRayOpacity }
        return min(max(opacity, 0), 1)
    }

    /// The opacity a surface with the given material opacity is drawn with in this mode.
    ///
    /// Unchanged in every mode except one that ``usesTransparency``, which caps it at
    /// `xrayOpacity` (clamped with ``clampedXRayOpacity(_:)``).
    public func surfaceOpacity(
        forMaterialOpacity opacity: Float, xrayOpacity: Float = defaultXRayOpacity
    ) -> Float {
        usesTransparency ? min(opacity, Self.clampedXRayOpacity(xrayOpacity)) : opacity
    }

    /// Whether a body's edges are drawn, and stamped into the pick buffer, in this mode.
    ///
    /// Edges show when the mode ``showsEdges``, and always for a body with no surface mesh, which
    /// would otherwise be invisible.
    public func drawsEdges(bodyHasMesh: Bool) -> Bool {
        showsEdges || !bodyHasMesh
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
