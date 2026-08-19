// CameraController.swift
// ViewportKit
//
// Camera controller implementing orbit, pan, and zoom with support for
// arcball and turntable rotation styles.

import Combine
import Foundation
import simd

/// Controls camera movement in a 3D viewport.
///
/// CameraController manages orbit, pan, and zoom operations, supporting
/// both arcball (free rotation) and turntable (constrained) modes.
///
/// The controller maintains camera state and provides smooth interpolation
/// for animated transitions.
///
/// ## Example
///
/// ```swift
/// let controller = CameraController()
/// controller.rotationStyle = .turntable
///
/// // Handle orbit gesture
/// controller.orbit(deltaX: translation.x, deltaY: translation.y)
///
/// // Animate to a standard view
/// controller.animateTo(.top, duration: 0.3)
/// ```
@MainActor
public final class CameraController: ObservableObject {

    // MARK: - Published Properties

    /// Current camera state.
    @Published public private(set) var cameraState: CameraState

    /// Whether an animation is in progress.
    @Published public private(set) var isAnimating: Bool = false

    // MARK: - Configuration

    /// Rotation behavior style.
    public var rotationStyle: RotationStyle = .turntable

    /// Orbit sensitivity (radians per point of drag).
    public var orbitSensitivity: Float = 0.005

    /// Pan sensitivity (world units per point of drag, scaled by distance).
    public var panSensitivity: Float = 0.002

    /// Zoom sensitivity for pinch gestures.
    public var zoomSensitivity: Float = 1.0

    /// Scroll wheel zoom sensitivity.
    public var scrollZoomSensitivity: Float = 0.1

    /// Minimum pan speed (prevents pan from becoming imperceptibly slow when zoomed in close).
    public var minPanSpeed: Float = 0.001

    /// Minimum distance from pivot.
    public var minDistance: Float = 0.1

    /// Maximum distance from pivot.
    public var maxDistance: Float = 10000

    /// Minimum vertical angle for turntable mode (radians from vertical).
    public var minPhi: Float = 0.01

    /// Maximum vertical angle for turntable mode (radians from vertical).
    public var maxPhi: Float = .pi - 0.01

    /// Damping factor for inertia (0 = no damping, 1 = instant stop).
    public var dampingFactor: Float = 0.1

    /// Whether inertia is enabled.
    public var enableInertia: Bool = true

    // MARK: - Internal State

    /// Velocity for inertia (radians per second).
    private var angularVelocity: SIMD2<Float> = .zero

    /// Pan velocity for inertia.
    private var panVelocity: SIMD2<Float> = .zero

    /// Arcball virtual sphere radius (in screen coordinates).
    private var arcballRadius: Float = 300

    /// Animation target state.
    private var animationTarget: CameraState?

    /// Animation start state.
    private var animationStart: CameraState?

    /// Animation progress (0 to 1).
    private var animationProgress: Float = 0

    /// Animation duration.
    private var animationDuration: Float = 0

    /// Timer for animations and inertia.
    private var animationTimer: Timer?

    /// Last update timestamp.
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Turntable State

    /// Spherical theta (horizontal angle around Z axis).
    private var theta: Float = 0

    /// Spherical phi (angle from Z axis down).
    private var phi: Float = .pi / 4

    /// Roll angle around the camera's forward axis (turntable mode).
    private var rollAngle: Float = 0

    // MARK: - Initialization

    /// Creates a camera controller with the specified initial state.
    public init(initialState: CameraState = CameraState()) {
        self.cameraState = initialState

        // Extract spherical coordinates from initial rotation
        updateSphericalFromRotation()
    }

    /// Creates a camera controller with a standard view.
    public convenience init(standardView: StandardView, distance: Float = 10) {
        self.init(initialState: standardView.cameraState(distance: distance))
    }

    // Note: Timer cleanup happens automatically when the object is deallocated.
    // We can't access animationTimer in deinit due to Swift 6 Sendable requirements.

    // MARK: - Orbit

    /// Performs orbit rotation based on drag delta.
    ///
    /// - Parameters:
    ///   - deltaX: Horizontal drag in points
    ///   - deltaY: Vertical drag in points
    public func orbit(deltaX: Float, deltaY: Float) {
        switch rotationStyle {
        case .arcball:
            orbitArcball(deltaX: deltaX, deltaY: deltaY)
        case .turntable:
            orbitTurntable(deltaX: deltaX, deltaY: deltaY)
        case .firstPerson:
            orbitFirstPerson(deltaX: deltaX, deltaY: deltaY)
        }
    }

    /// Arcball rotation using Shoemake's algorithm.
    private func orbitArcball(deltaX: Float, deltaY: Float) {
        // Project points onto virtual sphere
        let p1 = projectOntoArcball(x: 0, y: 0)
        let p2 = projectOntoArcball(
            x: -deltaX * orbitSensitivity * 100, y: deltaY * orbitSensitivity * 100)

        // Calculate rotation quaternion from p1 to p2
        let axis = simd_cross(p1, p2)
        let axisLength = simd_length(axis)

        guard axisLength > 0.0001 else { return }

        let angle = 2.0 * asin(min(1.0, axisLength))
        let normalizedAxis = axis / axisLength

        let deltaRotation = simd_quatf(angle: angle, axis: normalizedAxis)

        // Apply rotation
        var newState = cameraState
        newState.rotation = simd_normalize(deltaRotation * cameraState.rotation)
        cameraState = newState
    }

    /// Projects a 2D point onto the arcball sphere.
    private func projectOntoArcball(x: Float, y: Float) -> SIMD3<Float> {
        let r = arcballRadius
        let d = x * x + y * y
        let rSquared = r * r

        if d < rSquared / 2 {
            // Inside sphere - project onto sphere surface
            let z = sqrt(rSquared - d)
            return simd_normalize(SIMD3<Float>(x, y, z))
        } else {
            // Outside sphere - use hyperbolic sheet
            let z = rSquared / (2 * sqrt(d))
            return simd_normalize(SIMD3<Float>(x, y, z))
        }
    }

    /// Turntable rotation (Z-up constrained).
    private func orbitTurntable(deltaX: Float, deltaY: Float) {
        // Horizontal rotation around Z axis
        theta -= deltaX * orbitSensitivity

        // Vertical tilt: unclamped for full 360° rotation
        phi -= deltaY * orbitSensitivity
        // Wrap phi to [0, 2π) for clean cycling
        let twoPi = Float.pi * 2
        phi = phi.truncatingRemainder(dividingBy: twoPi)
        if phi < 0 { phi += twoPi }

        // Convert spherical to quaternion
        updateRotationFromSpherical()
    }

    /// First-person rotation.
    private func orbitFirstPerson(deltaX: Float, deltaY: Float) {
        // Yaw around world up
        let yaw = simd_quatf(angle: -deltaX * orbitSensitivity, axis: SIMD3<Float>(0, 0, 1))

        // Pitch around camera right
        let right = cameraState.rightVector
        let pitch = simd_quatf(angle: -deltaY * orbitSensitivity, axis: right)

        var newState = cameraState
        newState.rotation = simd_normalize(yaw * pitch * cameraState.rotation)
        cameraState = newState
    }

    // MARK: - Pan

    /// Performs pan based on drag delta.
    ///
    /// - Parameters:
    ///   - deltaX: Horizontal drag in points
    ///   - deltaY: Vertical drag in points
    public func pan(deltaX: Float, deltaY: Float) {
        let scaleFactor = max(minPanSpeed, cameraState.distance * panSensitivity)

        // Move in camera's local XY plane
        let right = cameraState.rightVector
        let up = cameraState.upVector

        var newState = cameraState
        newState.pivot -= right * deltaX * scaleFactor
        newState.pivot += up * deltaY * scaleFactor
        cameraState = newState
    }

    // MARK: - Zoom

    /// Zooms by changing distance from pivot.
    ///
    /// - Parameter factor: Zoom factor (>1 zooms in, <1 zooms out)
    public func zoom(factor: Float) {
        var newState = cameraState
        let newDistance = cameraState.distance / factor
        newState.distance = max(minDistance, min(maxDistance, newDistance))

        if cameraState.isOrthographic {
            newState.orthographicScale = newState.orthographicScale / factor
        }

        cameraState = newState
    }

    /// Zooms using scroll wheel delta, optionally shifting the pivot toward the cursor.
    ///
    /// - Parameters:
    ///   - delta: Scroll delta (positive = zoom in)
    ///   - cursorNormalized: Cursor position in normalized coordinates (−1…+1), or `nil` for center zoom
    ///   - aspectRatio: View aspect ratio (width / height)
    public func scrollZoom(
        delta: Float, cursorNormalized: SIMD2<Float>? = nil, aspectRatio: Float = 1.0
    ) {
        // Exponential mapping: smooth, symmetric (in/out cancel), and never produces a non-positive
        // factor. The old linear 1 + delta·k jumped wildly on precise-trackpad pixel deltas.
        let factor = exp(delta * scrollZoomSensitivity)
        zoomToward(factor: factor, cursorNormalized: cursorNormalized, aspectRatio: aspectRatio)
    }

    /// Zooms by `factor`, keeping the world point under `cursorNormalized` (NDC −1…+1) stationary
    /// (pinch-at-fingers / zoom-at-cursor). `nil` cursor = plain centre zoom.
    public func zoomToward(factor: Float, cursorNormalized: SIMD2<Float>?, aspectRatio: Float = 1.0)
    {
        guard factor > 0 else { return }

        let oldDistance = cameraState.distance
        let oldOrthoScale = cameraState.orthographicScale

        // Apply distance/scale change
        zoom(factor: factor)

        // Shift pivot toward cursor to keep the world point under cursor stationary
        guard let cursor = cursorNormalized else { return }

        let right = cameraState.rightVector
        let up = cameraState.upVector

        let cursorOffset: SIMD3<Float>
        if cameraState.isOrthographic {
            let halfH = oldOrthoScale / 2
            let halfW = halfH * aspectRatio
            cursorOffset = right * cursor.x * halfW + up * cursor.y * halfH
        } else {
            let fovRad = cameraState.fieldOfView * .pi / 180.0
            let halfH = oldDistance * tan(fovRad / 2.0)
            let halfW = halfH * aspectRatio
            cursorOffset = right * cursor.x * halfW + up * cursor.y * halfH
        }

        let zoomRatio = 1.0 - 1.0 / factor
        var newState = cameraState
        newState.pivot += cursorOffset * zoomRatio
        cameraState = newState
    }

    // MARK: - Roll

    /// Rolls the camera around its forward axis.
    ///
    /// - Parameter deltaAngle: Rotation delta in radians
    public func roll(deltaAngle: Float) {
        switch rotationStyle {
        case .turntable:
            rollAngle += deltaAngle
            updateRotationFromSpherical()
        case .arcball, .firstPerson:
            let forward = cameraState.viewDirection
            let rollQuat = simd_quatf(angle: deltaAngle, axis: forward)
            var newState = cameraState
            newState.rotation = simd_normalize(rollQuat * cameraState.rotation)
            cameraState = newState
        }
    }

    // MARK: - Animation

    /// Animates to a target camera state.
    ///
    /// - Parameters:
    ///   - target: Target camera state
    ///   - duration: Animation duration in seconds
    public func animateTo(_ target: CameraState, duration: Float = 0.3) {
        guard duration > 0 else {
            cameraState = target
            updateSphericalFromRotation()
            return
        }

        animationStart = cameraState
        animationTarget = target
        animationDuration = duration
        animationProgress = 0
        isAnimating = true
        lastUpdateTime = Date.timeIntervalSinceReferenceDate

        startAnimationTimer()
    }

    /// Animates to a standard view.
    ///
    /// - Parameters:
    ///   - view: Target standard view
    ///   - duration: Animation duration in seconds
    public func animateTo(_ view: StandardView, duration: Float = 0.3) {
        let target = view.cameraState(
            pivot: cameraState.pivot,
            distance: cameraState.distance,
            fieldOfView: cameraState.fieldOfView,
            orthographicScale: cameraState.orthographicScale
        )
        animateTo(target, duration: duration)
    }

    /// Cancels any in-progress animation.
    public func cancelAnimation() {
        isAnimating = false
        animationTarget = nil
        stopAnimationTimer()
    }

    // MARK: - Focus

    /// Focuses on a point, optionally adjusting distance.
    ///
    /// - Parameters:
    ///   - point: World point to focus on
    ///   - distance: Optional new distance
    ///   - animated: Whether to animate
    public func focusOn(point: SIMD3<Float>, distance: Float? = nil, animated: Bool = true) {
        var target = cameraState
        target.pivot = point
        if let d = distance {
            target.distance = max(minDistance, min(maxDistance, d))
        }

        if animated {
            animateTo(target, duration: 0.3)
        } else {
            cameraState = target
        }
    }

    /// Resets the camera to the default view.
    public func reset(animated: Bool = true) {
        let target = CameraState()
        rollAngle = 0

        if animated {
            animateTo(target, duration: 0.5)
        } else {
            cameraState = target
            updateSphericalFromRotation()
        }
    }

    // MARK: - Dynamic Pivot

    /// Animates only the pivot to a new position.
    ///
    /// Skips if the delta is negligible or an animation is already running.
    ///
    /// - Parameters:
    ///   - newPivot: Target pivot position.
    ///   - duration: Animation duration in seconds.
    public func adjustPivot(to newPivot: SIMD3<Float>, duration: Float = 0.15) {
        let delta = simd_length(newPivot - cameraState.pivot)
        guard delta > 0.001, !isAnimating else { return }
        var target = cameraState
        target.pivot = newPivot
        animateTo(target, duration: duration)
    }

    // MARK: - Inertia

    /// Sets angular velocity for inertia.
    public func setAngularVelocity(_ velocity: SIMD2<Float>) {
        guard enableInertia else { return }
        angularVelocity = velocity
        startAnimationTimer()
    }

    /// Sets pan velocity for inertia.
    public func setPanVelocity(_ velocity: SIMD2<Float>) {
        guard enableInertia else { return }
        panVelocity = velocity
        startAnimationTimer()
    }

    // MARK: - Snap to Standard View

    /// Returns the nearest axis-aligned standard view if within the angular threshold.
    ///
    /// - Parameter threshold: Maximum angle in degrees to snap
    /// - Returns: The nearest standard view, or `nil` if none is close enough
    func nearestStandardView(threshold: Float = 3.0) -> StandardView? {
        let thresholdRad = threshold * .pi / 180.0
        let snapViews: [StandardView] = [.top, .bottom, .front, .back, .right, .left]
        for view in snapViews {
            let angle = angleTo(standardView: view)
            if angle < thresholdRad {
                return view
            }
        }
        return nil
    }

    private func angleTo(standardView view: StandardView) -> Float {
        let targetRotation = view.rotation
        let dot = abs(
            simd_dot(simd_normalize(cameraState.rotation), simd_normalize(targetRotation)))
        return 2.0 * acos(min(1.0, dot))
    }

    // MARK: - Private Helpers

    /// Updates spherical coordinates from current rotation.
    private func updateSphericalFromRotation() {
        // Extract theta and phi from rotation quaternion
        let forward = cameraState.rotation.act(SIMD3<Float>(0, 0, 1))

        // Phi is angle from Z axis (acos gives [0, pi])
        // We accept the [0, pi] range here, since continuous dragging maintains
        // the full phi via incremental updates in orbitTurntable.
        phi = acos(simd_clamp(forward.z, -1, 1))

        // Theta is angle in XY plane
        theta = atan2(forward.y, forward.x)

        // Reset roll: standard views have no roll, and extracting roll
        // from an arbitrary quaternion is fragile.
        rollAngle = 0
    }

    /// Updates rotation quaternion from spherical coordinates.
    private func updateRotationFromSpherical() {
        // Build rotation from spherical coordinates
        // First rotate around Z (horizontal), then tilt down from Z axis, then roll
        let rotZ = simd_quatf(angle: theta, axis: SIMD3<Float>(0, 0, 1))
        let rotX = simd_quatf(angle: phi - .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let rotRoll = simd_quatf(angle: rollAngle, axis: SIMD3<Float>(0, 0, 1))

        var newState = cameraState
        newState.rotation = simd_normalize(rotZ * rotX * rotRoll)
        cameraState = newState
    }

    // MARK: - Animation Timer

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }

        lastUpdateTime = Date.timeIntervalSinceReferenceDate
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.updateAnimation()
            }
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func updateAnimation() {
        let currentTime = Date.timeIntervalSinceReferenceDate
        let deltaTime = Float(currentTime - lastUpdateTime)
        lastUpdateTime = currentTime

        var needsContinue = false

        // Animation update
        if isAnimating, let start = animationStart, let target = animationTarget {
            animationProgress += deltaTime / animationDuration

            if animationProgress >= 1.0 {
                cameraState = target
                updateSphericalFromRotation()
                isAnimating = false
                animationTarget = nil
            } else {
                // Use ease-out curve
                let t = 1.0 - pow(1.0 - animationProgress, 3)
                cameraState = start.interpolated(to: target, t: t)
                needsContinue = true
            }
        }

        // Inertia update
        if simd_length(angularVelocity) > 0.001 {
            orbit(
                deltaX: angularVelocity.x * deltaTime * 60,
                deltaY: angularVelocity.y * deltaTime * 60)
            angularVelocity *= (1.0 - dampingFactor)
            needsContinue = true
        } else {
            angularVelocity = .zero
        }

        if simd_length(panVelocity) > 0.001 {
            pan(deltaX: panVelocity.x * deltaTime * 60, deltaY: panVelocity.y * deltaTime * 60)
            panVelocity *= (1.0 - dampingFactor)
            needsContinue = true
        } else {
            panVelocity = .zero
        }

        if !needsContinue {
            stopAnimationTimer()
        }
    }
}
