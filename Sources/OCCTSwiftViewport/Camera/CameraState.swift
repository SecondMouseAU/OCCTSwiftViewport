// CameraState.swift
// ViewportKit
//
// Immutable camera state representing a viewport orientation.

import Foundation
import simd

/// Immutable camera state representing a viewport orientation.
///
/// CameraState is a value type that captures all parameters needed to
/// reproduce a specific view. It can be stored, compared, and interpolated.
///
/// ## Example
///
/// ```swift
/// // Capture current state
/// let saved = viewport.cameraState
///
/// // Restore later
/// viewport.animateTo(saved, duration: 0.3)
/// ```
public struct CameraState: Hashable, Codable, Sendable {

    // MARK: - Properties

    /// View rotation as a normalized quaternion.
    public var rotation: simd_quatf

    /// Distance from pivot point along view direction.
    public var distance: Float

    /// Pivot point (orbit center) in world coordinates.
    public var pivot: SIMD3<Float>

    /// Field of view in degrees (perspective mode only).
    public var fieldOfView: Float

    /// Orthographic scale (orthographic mode only).
    public var orthographicScale: Float

    /// Whether using orthographic projection.
    public var isOrthographic: Bool

    /// Unused: nothing reads it, so setting it does not move the view.
    ///
    /// It is still stored, compared, encoded and interpolated, so saved states round-trip, but
    /// no view or projection matrix ever applied it. To pan, move `pivot` across the view, as
    /// `CameraController.pan(deltaX:deltaY:)` does.
    @available(
        *, deprecated,
        message:
            "panOffset was never applied to the view; move pivot across the view to pan instead"
    )
    public var panOffset: SIMD2<Float> {
        get { storedPanOffset }
        set { storedPanOffset = newValue }
    }

    /// Backing store for the deprecated `panOffset`, so the type's own init, interpolation and
    /// coding keep it without deprecation warnings.
    private var storedPanOffset: SIMD2<Float> = .zero

    // MARK: - Computed Properties

    /// Camera position in world coordinates.
    public var position: SIMD3<Float> {
        // Camera looks along -Z in its local space
        // So position is pivot + distance along the view direction (which is +Z in rotated space)
        let forward = rotation.act(SIMD3<Float>(0, 0, 1))
        return pivot + forward * distance
    }

    /// View direction (normalized, pointing toward pivot).
    public var viewDirection: SIMD3<Float> {
        rotation.act(SIMD3<Float>(0, 0, -1))
    }

    /// Up vector in world coordinates.
    public var upVector: SIMD3<Float> {
        rotation.act(SIMD3<Float>(0, 1, 0))
    }

    /// Right vector in world coordinates.
    public var rightVector: SIMD3<Float> {
        rotation.act(SIMD3<Float>(1, 0, 0))
    }

    /// View matrix (world-to-camera transform) for Metal rendering.
    public var viewMatrix: simd_float4x4 {
        let eye = position
        let target = pivot
        let up = upVector
        return simd_float4x4.lookAt(eye: eye, target: target, up: up)
    }

    /// Projection matrix for Metal rendering.
    ///
    /// Returns a perspective or orthographic matrix depending on `isOrthographic`.
    ///
    /// - Parameters:
    ///   - aspectRatio: Viewport width / height
    ///   - near: Near clipping plane distance
    ///   - far: Far clipping plane distance
    /// - Returns: A projection matrix suitable for Metal NDC (z in [0, 1])
    public func projectionMatrix(
        aspectRatio: Float,
        near: Float = 0.01,
        far: Float = 1000.0
    ) -> simd_float4x4 {
        if isOrthographic {
            let halfHeight = orthographicScale * 0.5
            let halfWidth = halfHeight * aspectRatio
            return simd_float4x4.orthographic(
                left: -halfWidth,
                right: halfWidth,
                bottom: -halfHeight,
                top: halfHeight,
                near: near,
                far: far
            )
        } else {
            let fovRadians = fieldOfView * .pi / 180.0
            return simd_float4x4.perspective(
                fovY: fovRadians,
                aspectRatio: aspectRatio,
                near: near,
                far: far
            )
        }
    }

    // MARK: - Initializers

    /// Creates a camera state with the specified parameters.
    public init(
        rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
        distance: Float = 10.0,
        pivot: SIMD3<Float> = .zero,
        fieldOfView: Float = 45.0,
        orthographicScale: Float = 10.0,
        isOrthographic: Bool = false
    ) {
        self.rotation = simd_normalize(rotation)
        self.distance = distance
        self.pivot = pivot
        self.fieldOfView = fieldOfView
        self.orthographicScale = orthographicScale
        self.isOrthographic = isOrthographic
    }

    /// Creates a camera state with the deprecated, never-applied `panOffset`.
    @available(
        *, deprecated,
        message:
            "panOffset was never applied to the view; omit it and move pivot across the view instead"
    )
    public init(
        rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
        distance: Float = 10.0,
        pivot: SIMD3<Float> = .zero,
        fieldOfView: Float = 45.0,
        orthographicScale: Float = 10.0,
        isOrthographic: Bool = false,
        panOffset: SIMD2<Float>
    ) {
        self.init(
            rotation: rotation, distance: distance, pivot: pivot, fieldOfView: fieldOfView,
            orthographicScale: orthographicScale, isOrthographic: isOrthographic)
        self.storedPanOffset = panOffset
    }

    /// Returns a copy fitted to enclose `bounds` from the current viewing direction.
    ///
    /// Pivots on the bounding box centre and chooses a distance (perspective) or
    /// `orthographicScale` (orthographic) such that the bounding sphere of `bounds`
    /// fits inside the view frustum on its narrower axis. `padding` is a
    /// multiplicative margin: `1.0` = tight fit, `1.1` = 10 % breathing room.
    public func fit(to bounds: BoundingBox, aspectRatio: Float, padding: Float = 1.1) -> CameraState
    {
        let center = bounds.center
        // Bounding sphere radius: tight enough for typical CAD scenes.
        let radius = max(bounds.diagonalLength * 0.5, 0.0001)
        let paddedRadius = radius * max(padding, 0.001)

        var copy = self
        copy.pivot = center
        copy.storedPanOffset = .zero

        if isOrthographic {
            // Vertical extent must cover 2·radius; horizontally that equals 2·radius·aspect.
            // If aspect < 1 (portrait), horizontal is the constraint.
            let verticalScale = paddedRadius * 2
            let horizontalScale =
                aspectRatio < 1 ? verticalScale / max(aspectRatio, 0.001) : verticalScale
            copy.orthographicScale = horizontalScale
        } else {
            // d = r / sin(halfFovMin). FoV is vertical; horizontal halfFov derives from aspect.
            let halfFovY = (fieldOfView * .pi / 180.0) * 0.5
            let halfFovX = atan(aspectRatio * tan(halfFovY))
            let halfFovMin = min(halfFovX, halfFovY)
            copy.distance = paddedRadius / max(sin(halfFovMin), 0.001)
        }
        return copy
    }

    /// Returns a copy in the given projection that shows the same height at the pivot.
    ///
    /// Perspective shows `2 · distance · tan(fieldOfView / 2)` at the pivot's depth and
    /// orthographic shows `orthographicScale` everywhere. Switching to orthographic sets the
    /// scale to the perspective height; switching to perspective sets the distance to the one
    /// that shows the orthographic height, keeping the pivot. Without this, a switch kept
    /// whatever scale or distance the other projection last had, so the view jumped in size.
    /// A copy already in `orthographic` is returned as it is.
    func matchingFraming(orthographic: Bool) -> CameraState {
        guard orthographic != isOrthographic else { return self }
        let span = 2 * tan(fieldOfView * .pi / 360)
        var copy = self
        copy.isOrthographic = orthographic
        guard span.isFinite, span > 1e-4 else { return copy }
        if orthographic {
            copy.orthographicScale = distance * span
        } else {
            copy.distance = orthographicScale / span
        }
        return copy
    }

    /// Convenience: fits to the world-space union of the visible bodies' bounding boxes.
    ///
    /// Each body's box is moved by its `transform`, so a moved or instanced body is framed where
    /// it is drawn. Hidden bodies are left out, and so are `.overlay`-layer bodies (gizmos,
    /// manipulators), as in the renderer's scene bounds, unless the scene has nothing else to
    /// frame (issue #208).
    ///
    /// Returns `nil` if no visible body has geometry.
    public func fit(to bodies: [ViewportBody], aspectRatio: Float, padding: Float = 1.1)
        -> CameraState?
    {
        guard
            let bounds = Self.worldBounds(of: bodies, layer: .geometry)
                ?? Self.worldBounds(of: bodies, layer: .overlay)
        else { return nil }
        return fit(to: bounds, aspectRatio: aspectRatio, padding: padding)
    }

    /// World-space union of the bounds of the visible `bodies` in `layer`.
    private static func worldBounds(of bodies: [ViewportBody], layer: RenderLayer) -> BoundingBox? {
        var union: BoundingBox?
        for body in bodies where body.isVisible && body.renderLayer == layer {
            guard let bb = body.boundingBox?.transformed(by: body.transform) else { continue }
            union = union?.union(bb) ?? bb
        }
        return union
    }

    /// Creates a camera state looking at a target from a position.
    public static func lookAt(
        target: SIMD3<Float>,
        from position: SIMD3<Float>,
        up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    ) -> CameraState {
        let direction = simd_normalize(target - position)
        let distance = simd_length(target - position)

        // Create rotation from direction vectors
        let rotation = quaternionLookAt(direction: direction, up: up)

        return CameraState(
            rotation: rotation,
            distance: distance,
            pivot: target
        )
    }

    // MARK: - Interpolation

    /// Interpolates to another state using SLERP for rotation.
    ///
    /// - Parameters:
    ///   - target: The target camera state
    ///   - t: Interpolation factor (0 = self, 1 = target)
    /// - Returns: Interpolated camera state
    /// When the two states differ in projection, the projection switches at `t = 0.5`. The
    /// receiver's unused value (`orthographicScale` in perspective, `distance` in orthographic)
    /// is first matched to the height it shows, which does not change it at `t = 0`, so the
    /// switch does not jump the view in size.
    public func interpolated(to target: CameraState, t: Float) -> CameraState {
        let clampedT = simd_clamp(t, 0, 1)
        if isOrthographic != target.isOrthographic {
            var start = matchingFraming(orthographic: !isOrthographic)
            start.isOrthographic = isOrthographic
            if start != self {
                return start.interpolated(to: target, t: clampedT)
            }
        }

        var result = CameraState(
            rotation: simd_slerp(rotation, target.rotation, clampedT),
            distance: distance + (target.distance - distance) * clampedT,
            pivot: pivot + (target.pivot - pivot) * clampedT,
            fieldOfView: fieldOfView + (target.fieldOfView - fieldOfView) * clampedT,
            orthographicScale: orthographicScale + (target.orthographicScale - orthographicScale)
                * clampedT,
            isOrthographic: clampedT >= 0.5 ? target.isOrthographic : isOrthographic
        )
        result.storedPanOffset =
            storedPanOffset + (target.storedPanOffset - storedPanOffset) * clampedT
        return result
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case rotationX, rotationY, rotationZ, rotationW
        case distance
        case pivotX, pivotY, pivotZ
        case fieldOfView
        case orthographicScale
        case isOrthographic
        case panOffsetX, panOffsetY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rx = try container.decode(Float.self, forKey: .rotationX)
        let ry = try container.decode(Float.self, forKey: .rotationY)
        let rz = try container.decode(Float.self, forKey: .rotationZ)
        let rw = try container.decode(Float.self, forKey: .rotationW)
        rotation = simd_quatf(ix: rx, iy: ry, iz: rz, r: rw)

        distance = try container.decode(Float.self, forKey: .distance)

        let px = try container.decode(Float.self, forKey: .pivotX)
        let py = try container.decode(Float.self, forKey: .pivotY)
        let pz = try container.decode(Float.self, forKey: .pivotZ)
        pivot = SIMD3<Float>(px, py, pz)

        fieldOfView = try container.decode(Float.self, forKey: .fieldOfView)
        orthographicScale = try container.decode(Float.self, forKey: .orthographicScale)
        isOrthographic = try container.decode(Bool.self, forKey: .isOrthographic)

        let ox = try container.decode(Float.self, forKey: .panOffsetX)
        let oy = try container.decode(Float.self, forKey: .panOffsetY)
        storedPanOffset = SIMD2<Float>(ox, oy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(rotation.imag.x, forKey: .rotationX)
        try container.encode(rotation.imag.y, forKey: .rotationY)
        try container.encode(rotation.imag.z, forKey: .rotationZ)
        try container.encode(rotation.real, forKey: .rotationW)

        try container.encode(distance, forKey: .distance)

        try container.encode(pivot.x, forKey: .pivotX)
        try container.encode(pivot.y, forKey: .pivotY)
        try container.encode(pivot.z, forKey: .pivotZ)

        try container.encode(fieldOfView, forKey: .fieldOfView)
        try container.encode(orthographicScale, forKey: .orthographicScale)
        try container.encode(isOrthographic, forKey: .isOrthographic)

        try container.encode(storedPanOffset.x, forKey: .panOffsetX)
        try container.encode(storedPanOffset.y, forKey: .panOffsetY)
    }
}

// MARK: - Standard View Presets

extension CameraState {
    /// Default isometric view (front-right-top corner).
    public static let isometric = StandardView.isometricFrontRight.cameraState()

    /// Top-down plan view.
    public static let top = StandardView.top.cameraState()

    /// Front elevation view.
    public static let front = StandardView.front.cameraState()

    /// Right side view.
    public static let right = StandardView.right.cameraState()
}

// MARK: - Helper Functions

/// Creates a quaternion that orients a camera so it looks along `direction`.
///
/// `direction` points from the eye toward the target (i.e. `normalize(target - eye)`).
/// The returned quaternion is the camera's orientation (camera-to-world): applying it to
/// the local `-Z` axis (see `CameraState.viewDirection`) reproduces `direction`, and applying
/// it to local `+Z` (see `CameraState.position`) gives the world-space direction from the
/// target back out to the eye, matching the standard "camera looks down local -Z" convention.
///
/// `right`/`correctedUp` follow the same cross-product order as a standard view-matrix basis
/// (`right = forward × up`, `up' = right × forward`); the row layout fed to the quaternion
/// extraction below is the transpose of that basis with the forward row negated, which is what
/// yields a camera-to-world (not world-to-camera) quaternion. Getting either the cross-product
/// order or the forward-row sign wrong reflects the resulting eye position through the target
/// (see the regression test `lookAt places the eye at the requested point, not its reflection`).
private func quaternionLookAt(direction: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
    let forward = simd_normalize(direction)
    let right = simd_normalize(simd_cross(forward, up))
    let correctedUp = simd_cross(right, forward)

    // Build rotation matrix
    let m00 = right.x
    let m01 = right.y
    let m02 = right.z
    let m10 = correctedUp.x
    let m11 = correctedUp.y
    let m12 = correctedUp.z
    let m20 = -forward.x
    let m21 = -forward.y
    let m22 = -forward.z

    // Convert to quaternion
    let trace = m00 + m11 + m22

    if trace > 0 {
        let s = 0.5 / sqrt(trace + 1.0)
        let w = 0.25 / s
        let x = (m12 - m21) * s
        let y = (m20 - m02) * s
        let z = (m01 - m10) * s
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
    } else if m00 > m11 && m00 > m22 {
        let s = 2.0 * sqrt(1.0 + m00 - m11 - m22)
        let w = (m12 - m21) / s
        let x = 0.25 * s
        let y = (m10 + m01) / s
        let z = (m20 + m02) / s
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
    } else if m11 > m22 {
        let s = 2.0 * sqrt(1.0 + m11 - m00 - m22)
        let w = (m20 - m02) / s
        let x = (m10 + m01) / s
        let y = 0.25 * s
        let z = (m21 + m12) / s
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
    } else {
        let s = 2.0 * sqrt(1.0 + m22 - m00 - m11)
        let w = (m01 - m10) / s
        let x = (m20 + m02) / s
        let y = (m21 + m12) / s
        let z = 0.25 * s
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
    }
}
