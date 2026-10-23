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
    ///
    /// In orthographic, with a `sceneBoundsProvider`, every change keeps the eye in front of the
    /// scene (see `CameraState.placingOrthographicEye(inFrontOf:)`).
    @Published public private(set) var cameraState: CameraState

    /// Whether an animation is in progress.
    @Published public private(set) var isAnimating: Bool = false

    // MARK: - Configuration

    /// Rotation behavior style.
    ///
    /// Changing it ends any orbit drag in progress and re-reads the turntable angles from the
    /// current rotation, so the first turntable orbit after arcball or first-person moves does
    /// not snap back to the last turntable orientation.
    public var rotationStyle: RotationStyle = .turntable {
        didSet {
            guard rotationStyle != oldValue else { return }
            orbitDrag = nil
            updateSphericalFromRotation()
        }
    }

    // The sensitivity, inertia and damping defaults below come from `GestureConfiguration.default`, so
    // a standalone controller feels the same as one that `ViewportController` configured.

    /// Orbit sensitivity (radians per point of drag).
    public var orbitSensitivity: Float = GestureConfiguration.default.orbitSensitivity

    /// Pan speed as a multiple of the pointer's: `1` (the default) is 1:1.
    ///
    /// At `1` a pan keeps the point under the pointer under the pointer: the world point at the
    /// pivot's depth in perspective, any point in orthographic. `2` moves the view twice as far
    /// as the pointer, `0.5` half as far. Pan speed follows `viewportHeight`, the field of view,
    /// `distance` and `orthographicScale`.
    ///
    /// Before issue #200 this was world units per point, scaled by distance, with a default of
    /// 0.005: about five times the pointer in an 800 pt tall view.
    public var panSensitivity: Float = GestureConfiguration.default.panSensitivity

    /// Height of the view the pointer moves over, in points.
    ///
    /// Pan uses it to turn points into world units, so the point under the pointer stays under
    /// it. `MetalViewportView` keeps it up to date; set it yourself when you drive the controller
    /// from another view. Values below 1 are treated as 1.
    public var viewportHeight: Float = 800

    /// Zoom sensitivity for pinch and drag zoom.
    ///
    /// `pinchZoom(magnification:cursorNormalized:aspectRatio:)` raises the gesture's magnification
    /// to this power, so `1` applies the gesture as is, `2` zooms twice as fast (in log terms) and
    /// `0.5` half as fast. `zoom(factor:)` and `zoomToward(factor:cursorNormalized:aspectRatio:)`
    /// are the raw primitives and do not apply it.
    public var zoomSensitivity: Float = GestureConfiguration.default.zoomSensitivity

    /// Scroll wheel zoom sensitivity.
    public var scrollZoomSensitivity: Float = GestureConfiguration.default.scrollZoomSensitivity

    /// Minimum pan speed, in world units per point of drag.
    ///
    /// A floor under the 1:1 pan speed, which already tracks the pointer at any distance. The
    /// default, `0`, keeps pan 1:1 however close the camera is; a positive value speeds pan up
    /// wherever 1:1 would move less than that per point.
    public var minPanSpeed: Float = GestureConfiguration.default.minPanSpeed

    /// Minimum distance from pivot.
    public var minDistance: Float = 0.1

    /// Maximum distance from pivot.
    public var maxDistance: Float = 10000

    /// The range `zoom(factor:)` keeps `orthographicScale` in.
    ///
    /// The heights the field of view spans at `minDistance` and `maxDistance`, so an
    /// orthographic view zooms as far in and out as a perspective one.
    public var orthographicScaleRange: ClosedRange<Float> {
        let span = 2 * tan(cameraState.fieldOfView * .pi / 360)
        let lower = max(minDistance * span, .leastNormalMagnitude)
        return lower...max(lower, maxDistance * span)
    }

    /// Minimum vertical angle for turntable mode (ignored).
    ///
    /// Turntable tilt is deliberately unclamped, so the camera can tilt over the pole for a full
    /// 360° vertical orbit. Nothing reads this property.
    @available(*, deprecated, message: "Ignored: turntable tilt is unclamped by design.")
    public var minPhi: Float = 0.01

    /// Maximum vertical angle for turntable mode (ignored; see `minPhi`).
    @available(*, deprecated, message: "Ignored: turntable tilt is unclamped by design.")
    public var maxPhi: Float = .pi - 0.01

    /// Damping factor for inertia (0 = no damping, 1 = instant stop).
    ///
    /// This is the fraction of velocity lost per 1/60 s. The decay is scaled by elapsed time, so
    /// momentum coasts for the same time and distance whatever the tick rate.
    public var dampingFactor: Float = GestureConfiguration.default.dampingFactor

    /// Whether inertia is enabled.
    public var enableInertia: Bool = GestureConfiguration.default.enableInertia

    /// Rate of the animation and inertia timer, in frames per second.
    ///
    /// `ViewportController` sets this from `ViewportConfiguration.preferredFramesPerSecond`, so
    /// camera updates keep pace with the display. The motion itself is time-based, so this changes
    /// only how smooth it looks, not how fast it goes. Values below 1 are treated as 1.
    public var preferredFramesPerSecond: Int = 120

    /// The state `reset(animated:)` returns to.
    ///
    /// Defaults to the controller's initial state, which for a `ViewportController` is
    /// `ViewportConfiguration.initialCameraState`.
    public var homeCameraState: CameraState

    /// Whether `zoomToward` should shift the pivot toward the cursor.
    ///
    /// When `true` (default), zoom-at-cursor keeps the world point under the cursor
    /// stationary by shifting the pivot. When `false`, zoom only changes distance/scale
    /// and the pivot remains fixed. This should be synced with
    /// `ViewportConfiguration.dynamicPivotConfiguration.isEnabled`.
    public var zoomTowardShiftsPivot: Bool = true

    /// Returns the world-space bounds of the scene, which an orthographic eye is kept in front of.
    ///
    /// An orthographic view's size is `orthographicScale`, whatever the eye's distance, but the
    /// near plane cannot go behind the eye, so an eye inside the model cut its front away. With
    /// a provider set, each change to `cameraState` in orthographic moves the eye back along the
    /// line of sight, if need be, until it is in front of these bounds; the picture does not
    /// change (issue #211). `MetalViewportView` sets one that reads its bodies when it appears,
    /// replacing any set before. `nil` (the default) leaves the eye where `distance` puts it.
    public var sceneBoundsProvider: (@MainActor () -> BoundingBox?)? {
        didSet { placeOrthographicEyeInFrontOfScene() }
    }

    // MARK: - Internal State

    /// Velocity for inertia (drag points per 1/60 s).
    private(set) var angularVelocity: SIMD2<Float> = .zero

    /// Pan velocity for inertia (drag points per 1/60 s).
    private(set) var panVelocity: SIMD2<Float> = .zero

    /// The orbit drag in progress, or still coasting after release.
    private var orbitDrag: OrbitDrag?

    /// Animation target state.
    private var animationTarget: CameraState?

    /// Animation start state.
    private var animationStart: CameraState?

    /// Animation progress (0 to 1).
    private var animationProgress: Float = 0

    /// Animation duration.
    private var animationDuration: Float = 0

    /// Whether the running animation moves only the pivot (`adjustPivot`), leaving rotation and
    /// distance to the user and to momentum.
    private var animatesPivotOnly = false

    /// The distances a `slidePivotAlongLineOfSight` animation runs between, or `nil` when the
    /// pivot-only animation is an `adjustPivot` one.
    private var pivotDepthAnimation: (start: Float, target: Float)?

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
        self.homeCameraState = initialState

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

    /// What an orbit drag fixes when it begins.
    private struct OrbitDrag {
        /// `-1` when the drag began with the camera upside down (its up vector below the
        /// horizon), else `1`.
        ///
        /// Turntable and first-person turn about world Z, which looks reversed from upside
        /// down, so a horizontal drag is flipped for the whole drag, as Blender does. Deciding
        /// once at the start avoids a jump when the drag crosses the top view.
        var turnSign: Float

        /// Drag direction as (horizontal, vertical, roll), each `1` or `-1`.
        var signs: SIMD3<Float>

        /// Arcball: the pointer at the start of the drag, in points from the arcball centre
        /// (y down), before `signs` apply.
        var startPointer: SIMD2<Float>

        /// Arcball: the pointer now, in the same frame as `startPointer`.
        var pointer: SIMD2<Float>

        /// Arcball: the camera-space rotation applied so far in this drag.
        var applied = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        /// Whether the pointer has been released; the drag then lives on only while its
        /// momentum coasts.
        var released = false
    }

    /// Whether an orbit drag is in progress: begun and not yet ended.
    public var isOrbitDragActive: Bool {
        guard let drag = orbitDrag else { return false }
        return !drag.released
    }

    /// Begins an orbit drag, stopping any orbit momentum still coasting.
    ///
    /// A drag fixes two things when it begins. For `.turntable` and `.firstPerson` it fixes which
    /// way a horizontal drag turns: if the camera is upside down (tilted over the pole), the turn
    /// is reversed for the whole drag, so the model still follows the pointer. For `.arcball` it
    /// fixes where the pointer is on the virtual sphere, which is what lets a drag outside the
    /// sphere roll the view.
    ///
    /// `orbit(deltaX:deltaY:)` begins a drag itself when none is in progress, at the arcball
    /// centre with every sign `1`. `ViewportController` calls this with the pointer's position
    /// and `GestureConfiguration.orbitDragSigns` plus `orbitRollSign`.
    ///
    /// - Parameters:
    ///   - pointer: Where the drag starts, in points from the centre of the view (y down).
    ///   - signs: Drag direction as (horizontal, vertical, roll), each `1` or `-1`. The deltas
    ///     passed to `orbit(deltaX:deltaY:)` already carry the horizontal and vertical signs.
    ///     The arcball uses them to recover where the pointer really is, and the roll sign to
    ///     set which way a drag outside the sphere rolls.
    public func beginOrbitDrag(
        at pointer: SIMD2<Float> = .zero, signs: SIMD3<Float> = SIMD3(1, 1, 1)
    ) {
        angularVelocity = .zero
        orbitDrag = makeOrbitDrag(at: pointer, signs: signs)
    }

    private func makeOrbitDrag(at pointer: SIMD2<Float>, signs: SIMD3<Float>) -> OrbitDrag {
        if rotationStyle == .turntable { syncSphericalIfStale() }
        let upsideDown = cameraState.upVector.z < -1e-4
        return OrbitDrag(
            turnSign: upsideDown ? -1 : 1,
            signs: SIMD3(signs.x < 0 ? -1 : 1, signs.y < 0 ? -1 : 1, signs.z < 0 ? -1 : 1),
            startPointer: pointer,
            pointer: pointer)
    }

    /// Ends the orbit drag in progress.
    ///
    /// Momentum from `setAngularVelocity(_:)` still coasts the way the drag was turning. The drag
    /// is forgotten once the momentum dies out or the next drag begins.
    public func endOrbitDrag() {
        guard orbitDrag != nil else { return }
        if simd_length(angularVelocity) > 0.001 {
            orbitDrag?.released = true
        } else {
            orbitDrag = nil
        }
    }

    /// Stops orbit and pan momentum and forgets any orbit drag.
    ///
    /// The viewport calls this when a new drag begins, so touching the view stops a coasting
    /// model instead of adding the new drag to its momentum.
    public func stopInertia() {
        angularVelocity = .zero
        panVelocity = .zero
        orbitDrag = nil
    }

    /// Hands the camera to a gesture that is beginning: stops momentum (`stopInertia()`) and any
    /// animation to a target view.
    ///
    /// The animation replays its path on every tick, so a drag, pan or pinch made while it ran
    /// was overwritten until it finished, then thrown away; a slow release near an axis view
    /// starts one (the snap). A pivot-only animation from the dynamic pivot is kept: it moves
    /// the pivot by increments and works alongside the gesture.
    func yieldToGesture() {
        stopInertia()
        cancelViewAnimation()
    }

    /// Cancels an animation to a target view, keeping a pivot-only one.
    ///
    /// The animation would overwrite a pinch, scroll or roll on its next tick. Momentum is left
    /// alone.
    func cancelViewAnimation() {
        if isAnimating, !animatesPivotOnly { cancelAnimation() }
    }

    /// Performs orbit rotation based on drag delta.
    ///
    /// The deltas are screen points with y down, and the model turns with them in every
    /// `rotationStyle`: a positive `deltaX` carries the near side of the model right, a negative
    /// `deltaY` (an upward drag) carries it up. `ViewportController` applies
    /// `GestureConfiguration.orbitDragSigns` before calling this, which is how
    /// `DragRotationConvention.orbitCamera` reverses it.
    ///
    /// Successive calls are one drag until `endOrbitDrag()`. The first call begins one if
    /// `beginOrbitDrag(at:signs:)` was not called; see it for what a drag fixes at its start.
    ///
    /// - Parameters:
    ///   - deltaX: Horizontal drag in points
    ///   - deltaY: Vertical drag in points
    public func orbit(deltaX: Float, deltaY: Float) {
        if !isOrbitDragActive { beginOrbitDrag() }
        orbitStep(deltaX: deltaX, deltaY: deltaY)
    }

    /// One step of the current orbit drag, from the pointer or from its momentum.
    private func orbitStep(deltaX: Float, deltaY: Float) {
        // Only momentum set without a drag gets here with none; it is a released drag at once.
        var drag =
            orbitDrag
            ?? {
                var momentum = makeOrbitDrag(at: .zero, signs: SIMD3(1, 1, 1))
                momentum.released = true
                return momentum
            }()
        switch rotationStyle {
        case .arcball:
            orbitArcball(deltaX: deltaX, deltaY: deltaY, drag: &drag)
        case .turntable:
            orbitTurntable(deltaX: deltaX * drag.turnSign, deltaY: deltaY)
        case .firstPerson:
            orbitFirstPerson(deltaX: deltaX * drag.turnSign, deltaY: deltaY)
        }
        orbitDrag = drag
    }

    /// Radius of the arcball's virtual sphere, in points.
    ///
    /// Shoemake's arcball turns the model through twice the arc the pointer covers on the
    /// sphere, so this radius makes a short drag near the centre turn it `orbitSensitivity`
    /// radians per point, as in the other styles: 400 pt at the default 0.005.
    var arcballRadius: Float {
        2 / max(orbitSensitivity, 1e-6)
    }

    /// Arcball rotation (Shoemake), from where the drag began to where the pointer is now.
    ///
    /// The pointer is placed on a virtual sphere centred on the view. Inside it a drag tumbles
    /// the model; outside it the pointer is held to the rim, so moving around the centre rolls
    /// the view about the line of sight. Each step is measured from the drag's start, so a
    /// pointer that returns to where it began leaves the model as it found it.
    private func orbitArcball(deltaX: Float, deltaY: Float, drag: inout OrbitDrag) {
        // The deltas carry the drag's signs; undo them to follow the real pointer.
        drag.pointer += SIMD2(deltaX * drag.signs.x, deltaY * drag.signs.y)
        let target = Self.arcballRotation(
            from: drag.startPointer, to: drag.pointer, radius: arcballRadius, signs: drag.signs)
        // Apply only the change since the last step, so a roll or anything else that turned the
        // camera during the drag is kept. The rotation is in camera space: compose on the right.
        let step = drag.applied.inverse * target
        drag.applied = target
        var newState = cameraState
        newState.rotation = simd_normalize(cameraState.rotation * step)
        setCameraState(newState)
    }

    /// The camera-space rotation an arcball drag from `start` to `end` applies to the camera.
    ///
    /// - Parameters:
    ///   - start: Pointer at the start of the drag, in points from the arcball centre (y down).
    ///   - end: Pointer now, in the same frame.
    ///   - radius: Sphere radius in points.
    ///   - signs: (horizontal, vertical, roll) signs. With all three `1` the model turns as if
    ///     the pointer held the sphere; each `-1` reverses that part of the turn.
    /// - Returns: The rotation to compose on the right of the drag's starting camera rotation.
    static func arcballRotation(
        from start: SIMD2<Float>, to end: SIMD2<Float>, radius: Float, signs: SIMD3<Float>
    ) -> simd_quatf {
        let a = arcballPoint(start, radius: radius)
        let b = arcballPoint(end, radius: radius)
        // Shoemake's quaternion from a to b turns through twice the arc between them, about
        // a × b. That is the turn the model appears to make; the camera turns the other way.
        let c = simd_cross(a, b)
        // A horizontal drag turns about the screen's y axis, a vertical one about its x axis,
        // and a drag around the rim about z, the line of sight.
        let axis = SIMD3(c.x * signs.y, c.y * signs.x, c.z * signs.z)
        let model = simd_quatf(ix: axis.x, iy: axis.y, iz: axis.z, r: simd_dot(a, b))
        return simd_normalize(model.inverse)
    }

    /// Projects a pointer offset (points from the centre, y down) onto the unit arcball.
    ///
    /// The result is in camera space: x right, y up, z toward the viewer. A point outside the
    /// sphere lands on its rim, as in Shoemake's arcball, so moving around outside it is a pure
    /// roll.
    static func arcballPoint(_ pointer: SIMD2<Float>, radius: Float) -> SIMD3<Float> {
        let p = SIMD2(pointer.x, -pointer.y) / max(radius, 1e-6)
        let d2 = simd_length_squared(p)
        if d2 <= 1 {
            return SIMD3(p.x, p.y, sqrt(1 - d2))
        }
        let rim = p / sqrt(d2)
        return SIMD3(rim.x, rim.y, 0)
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

    /// First-person look-around: the camera turns in place and the pivot moves with it.
    ///
    /// Horizontal drag yaws about world Z; vertical drag pitches about the camera's right vector.
    /// The camera position is held and the pivot is put back `distance` in front of it, so the
    /// view turns about the eye rather than about a point in the scene. With the deltas
    /// `orbit(deltaX:deltaY:)` documents, the scene follows the drag (a drag right turns the
    /// view to the left); `DragRotationConvention.orbitCamera` reverses that to mouse-look.
    private func orbitFirstPerson(deltaX: Float, deltaY: Float) {
        let yaw = simd_quatf(angle: deltaX * orbitSensitivity, axis: SIMD3<Float>(0, 0, 1))
        let pitch = simd_quatf(angle: deltaY * orbitSensitivity, axis: cameraState.rightVector)

        let eye = cameraState.position
        var newState = cameraState
        newState.rotation = simd_normalize(yaw * pitch * cameraState.rotation)
        // position = pivot + back × distance, so keep the eye and move the pivot.
        newState.pivot = eye - newState.rotation.act(SIMD3<Float>(0, 0, 1)) * newState.distance
        setCameraState(newState)
    }

    // MARK: - Pan

    /// World units one point of drag pans: 1:1 times `panSensitivity`, floored at `minPanSpeed`.
    ///
    /// 1:1 is the height the view shows divided by `viewportHeight`: `orthographicScale` in
    /// orthographic, the height the field of view spans at the pivot's depth in perspective.
    var panWorldUnitsPerPoint: Float {
        let visibleHeight =
            cameraState.isOrthographic
            ? cameraState.orthographicScale
            : 2 * cameraState.distance * tan(cameraState.fieldOfView * .pi / 360)
        return max(minPanSpeed, visibleHeight / max(viewportHeight, 1) * panSensitivity)
    }

    /// Performs pan based on drag delta.
    ///
    /// At the default `panSensitivity` of 1 the scene follows the pointer 1:1: the world point at
    /// the pivot's depth (any point, in orthographic) under the pointer when the drag starts is
    /// still under it when the drag ends. That needs `viewportHeight` to be the view's height.
    ///
    /// - Parameters:
    ///   - deltaX: Horizontal drag in points
    ///   - deltaY: Vertical drag in points
    public func pan(deltaX: Float, deltaY: Float) {
        let scaleFactor = panWorldUnitsPerPoint

        // Move in camera's local XY plane
        let right = cameraState.rightVector
        let up = cameraState.upVector

        var newState = cameraState
        newState.pivot -= right * deltaX * scaleFactor
        newState.pivot += up * deltaY * scaleFactor
        setCameraState(newState)
    }

    // MARK: - Zoom

    /// Zooms by changing the distance from the pivot (perspective) or `orthographicScale`
    /// (orthographic).
    ///
    /// The distance stays within `minDistance...maxDistance` and `orthographicScale` within
    /// `orthographicScaleRange`. An orthographic zoom leaves `distance`, and so the eye, where
    /// it is: dividing it too walked the eye toward the pivot, into the model, where the near
    /// plane cut away its front (issue #211).
    ///
    /// - Parameter factor: Zoom factor (>1 zooms in, <1 zooms out)
    public func zoom(factor: Float) {
        var newState = cameraState
        if cameraState.isOrthographic {
            let range = orthographicScaleRange
            newState.orthographicScale = min(
                range.upperBound, max(range.lowerBound, newState.orthographicScale / factor))
        } else {
            newState.distance = max(minDistance, min(maxDistance, cameraState.distance / factor))
        }
        setCameraState(newState)
    }

    /// Zooms by a pinch or drag-zoom magnification, scaled by `zoomSensitivity`.
    ///
    /// The applied factor is `magnification` raised to `zoomSensitivity`, so the default
    /// sensitivity of 1 applies the gesture unchanged.
    ///
    /// - Parameters:
    ///   - magnification: Incremental gesture scale (>1 zooms in, <1 zooms out, 1 = no change).
    ///     Non-positive values are ignored.
    ///   - cursorNormalized: Gesture centre in normalized coordinates (−1…+1), or `nil` for
    ///     centre zoom
    ///   - aspectRatio: View aspect ratio (width / height)
    public func pinchZoom(
        magnification: Float, cursorNormalized: SIMD2<Float>? = nil, aspectRatio: Float = 1.0
    ) {
        guard magnification > 0 else { return }
        zoomToward(
            factor: pow(magnification, zoomSensitivity), cursorNormalized: cursorNormalized,
            aspectRatio: aspectRatio)
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
        // Only if zoomTowardShiftsPivot is enabled (synced with dynamicPivotConfiguration)
        guard zoomTowardShiftsPivot, let cursor = cursorNormalized else { return }

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

        // Use the zoom actually applied: at minDistance or maxDistance the distance stops
        // changing, and shifting by the requested factor kept sliding the view sideways.
        let applied =
            cameraState.isOrthographic
            ? oldOrthoScale / max(cameraState.orthographicScale, .leastNormalMagnitude)
            : oldDistance / max(cameraState.distance, .leastNormalMagnitude)
        let zoomRatio = 1.0 - 1.0 / applied
        guard abs(zoomRatio) > 0 else { return }
        var newState = cameraState
        newState.pivot += cursorOffset * zoomRatio
        setCameraState(newState)
    }

    // MARK: - Roll

    /// Rolls the camera around its forward axis.
    ///
    /// A positive angle turns the picture clockwise on screen, as a clockwise twist does, in
    /// every `rotationStyle`. Arcball and first-person used to roll the other way from turntable.
    ///
    /// - Parameter deltaAngle: Rotation delta in radians
    public func roll(deltaAngle: Float) {
        switch rotationStyle {
        case .turntable:
            rollAngle += deltaAngle
            updateRotationFromSpherical()
        case .arcball, .firstPerson:
            // About the camera's own z (back) axis, composed on the right as turntable does.
            let rollQuat = simd_quatf(angle: deltaAngle, axis: SIMD3<Float>(0, 0, 1))
            var newState = cameraState
            newState.rotation = simd_normalize(cameraState.rotation * rollQuat)
            setCameraState(newState)
        }
    }

    // MARK: - Animation

    /// Animates to a target camera state.
    ///
    /// Stops any orbit or pan momentum, which would otherwise fight the animation, and ends any
    /// orbit drag in progress.
    ///
    /// - Parameters:
    ///   - target: Target camera state
    ///   - duration: Animation duration in seconds
    public func animateTo(_ target: CameraState, duration: Float = 0.3) {
        stopInertia()
        animatesPivotOnly = false
        guard duration > 0 else {
            cancelAnimation()
            setCameraState(target)
            updateSphericalFromRotation()
            return
        }
        startAnimation(to: target, duration: duration)
    }

    private func startAnimation(to target: CameraState, duration: Float) {
        pivotDepthAnimation = nil
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
    /// Keeps the pivot and the view's size: a view in the other projection (the axis views are
    /// orthographic, the isometric ones perspective) gets the scale or distance that shows the
    /// same height at the pivot, as `switchedProjection(toOrthographic:)` does.
    public func animateTo(_ view: StandardView, duration: Float = 0.3) {
        let framed = switchedProjection(toOrthographic: view.isOrthographic)
        let target = view.cameraState(
            pivot: framed.pivot,
            distance: framed.distance,
            fieldOfView: framed.fieldOfView,
            orthographicScale: framed.orthographicScale
        )
        animateTo(target, duration: duration)
    }

    /// The current camera state switched to the given projection, showing the same height at
    /// the pivot.
    ///
    /// Switching to orthographic sets `orthographicScale` to the height the perspective view
    /// shows at the pivot; switching to perspective sets `distance` to the one that shows the
    /// orthographic height, within `minDistance...maxDistance`. The state is returned unchanged
    /// when it is already in that projection.
    func switchedProjection(toOrthographic orthographic: Bool) -> CameraState {
        guard orthographic != cameraState.isOrthographic else { return cameraState }
        var state = cameraState.matchingFraming(orthographic: orthographic)
        if orthographic {
            let range = orthographicScaleRange
            state.orthographicScale = min(
                range.upperBound, max(range.lowerBound, state.orthographicScale))
        } else {
            state.distance = min(maxDistance, max(minDistance, state.distance))
        }
        return state
    }

    /// Cancels any in-progress animation.
    ///
    /// Momentum keeps coasting: the shared timer stops only when nothing else is moving.
    public func cancelAnimation() {
        isAnimating = false
        animationTarget = nil
        animatesPivotOnly = false
        pivotDepthAnimation = nil
        if simd_length(angularVelocity) <= 0.001 && simd_length(panVelocity) <= 0.001 {
            stopAnimationTimer()
        }
    }

    // MARK: - Focus

    /// Focuses on a point, optionally adjusting distance.
    ///
    /// Stops any orbit or pan momentum, animated or not, so the camera stays on the point.
    ///
    /// In orthographic, `distance` zooms to the height a perspective camera that far from the
    /// point would show, `2 · distance · tan(fieldOfView / 2)`, within
    /// `orthographicScaleRange`; it used to set the eye's distance, which an orthographic view
    /// does not show, so the call did not zoom (issue #211). The eye's distance is kept.
    ///
    /// - Parameters:
    ///   - point: World point to focus on
    ///   - distance: Optional new distance (perspective), or the distance whose framing to
    ///     show (orthographic)
    ///   - animated: Whether to animate
    public func focusOn(point: SIMD3<Float>, distance: Float? = nil, animated: Bool = true) {
        var target = cameraState
        target.pivot = point
        if let d = distance {
            let clamped = max(minDistance, min(maxDistance, d))
            if cameraState.isOrthographic {
                let range = orthographicScaleRange
                let height = clamped * 2 * tan(cameraState.fieldOfView * .pi / 360)
                target.orthographicScale = min(range.upperBound, max(range.lowerBound, height))
            } else {
                target.distance = clamped
            }
        }

        animateTo(target, duration: animated ? 0.3 : 0)
    }

    /// Resets the camera to `homeCameraState`.
    public func reset(animated: Bool = true) {
        let target = homeCameraState
        rollAngle = 0

        if animated {
            animateTo(target, duration: 0.5)
        } else {
            animateTo(target, duration: 0)
        }
    }

    // MARK: - Dynamic Pivot

    /// Animates only the pivot to a new position.
    ///
    /// Skips if the delta is negligible or an animation is already running. Only the pivot is
    /// animated, so orbit momentum still coasting keeps turning the view; previously the
    /// animation replayed the rotation it started from on every tick and, when it finished,
    /// threw away whatever the momentum had turned in the meantime.
    ///
    /// The camera stays where it is along the line of sight: `distance` changes by the pivot's
    /// change in depth, so a pivot that moves along the view axis (the dynamic pivot's raycast
    /// hit) leaves the view as it was. Previously the distance was kept and the camera slid
    /// toward or away from the model after each gesture, a visible zoom jump. Only a move
    /// across the view still moves the camera, as it must for the pivot to stay at the centre
    /// of the view. The distance stays within `minDistance...maxDistance`.
    ///
    /// - Parameters:
    ///   - newPivot: Target pivot position.
    ///   - duration: Animation duration in seconds.
    public func adjustPivot(to newPivot: SIMD3<Float>, duration: Float = 0.15) {
        let delta = simd_length(newPivot - cameraState.pivot)
        guard delta > 0.001, !isAnimating else { return }
        guard duration > 0 else {
            movePivotKeepingDepth(by: newPivot - cameraState.pivot)
            return
        }
        var target = cameraState
        target.pivot = newPivot
        animatesPivotOnly = true
        startAnimation(to: target, duration: duration)
    }

    /// Slides the pivot along the current line of sight to the depth of `point`, leaving the
    /// camera's position and orientation exactly as they are.
    ///
    /// This is how the dynamic pivot moves the orbit centre after a gesture: only `distance`
    /// changes, and the pivot is recomputed from the camera's position on every animation tick,
    /// so the view never moves, even while orbit or pan momentum is still coasting. A target at
    /// or behind the camera is ignored, and the distance stays within
    /// `minDistance...maxDistance` (in orthographic, only above `minDistance`). Like
    /// `adjustPivot(to:duration:)`, it does nothing while another animation runs.
    ///
    /// - Parameters:
    ///   - point: A world point whose depth along the line of sight the pivot moves to. Only
    ///     its depth is used; a point off the line of sight does not pull the view across.
    ///   - duration: Animation duration in seconds; `0` moves at once.
    func slidePivotAlongLineOfSight(toDepthOf point: SIMD3<Float>, duration: Float = 0.15) {
        guard !isAnimating else { return }
        let depth = simd_dot(point - cameraState.position, cameraState.viewDirection)
        guard depth > 0 else { return }
        let target = clampedPivotDistance(depth)
        guard abs(target - cameraState.distance) > 0.001 else { return }
        guard duration > 0 else {
            setDistanceKeepingPosition(target)
            return
        }
        animatesPivotOnly = true
        startAnimation(to: cameraState, duration: duration)
        pivotDepthAnimation = (cameraState.distance, target)
    }

    /// Sets `distance`, moving the pivot along the line of sight so the camera stays put.
    private func setDistanceKeepingPosition(_ distance: Float) {
        let eye = cameraState.position
        var newState = cameraState
        newState.distance = clampedPivotDistance(distance)
        // position = pivot − viewDirection × distance.
        newState.pivot = eye + cameraState.viewDirection * newState.distance
        setCameraState(newState)
    }

    /// Sets `cameraState`, first moving an orthographic eye in front of the scene.
    ///
    /// Every change after `init` goes through here, so the state is published once, already
    /// placed, rather than first with the eye inside the model.
    private func setCameraState(_ state: CameraState) {
        cameraState = placingOrthographicEye(state)
    }

    /// Returns `state` with an orthographic eye moved in front of the scene.
    ///
    /// The eye moves back along the line of sight to the front of the `sceneBoundsProvider`'s
    /// bounds. The picture does not change: only `distance` grows.
    ///
    /// An eye already in front of the scene is left exactly where it is, so a pivot that slides
    /// along the line of sight (the dynamic pivot) never moves it.
    private func placingOrthographicEye(_ state: CameraState) -> CameraState {
        guard state.isOrthographic, let provider = sceneBoundsProvider else { return state }
        return state.placingOrthographicEye(inFrontOf: provider())
    }

    /// Moves an orthographic eye in front of the scene now, without any other camera change.
    ///
    /// For when the scene changed rather than the camera: a model loaded or moved while the
    /// camera was still. Does nothing if the eye is already in front, or without a
    /// `sceneBoundsProvider`.
    public func placeOrthographicEyeInFrontOfScene() {
        let placed = placingOrthographicEye(cameraState)
        if placed != cameraState { cameraState = placed }
    }

    /// Clamps a `distance` the pivot is moved to while the eye stays put.
    ///
    /// Perspective keeps it within `minDistance...maxDistance`. Orthographic keeps only the
    /// floor: there `distance` just places the eye, which may sit further back than
    /// `maxDistance` to be in front of a large scene, and capping it would stop the pivot short
    /// of the surface it was sliding to.
    private func clampedPivotDistance(_ distance: Float) -> Float {
        let upper = cameraState.isOrthographic ? Float.greatestFiniteMagnitude : maxDistance
        return max(minDistance, min(upper, distance))
    }

    /// Moves the pivot by `delta`, changing `distance` by the move's depth along the line of
    /// sight, so the camera does not move along it.
    private func movePivotKeepingDepth(by delta: SIMD3<Float>) {
        var newState = cameraState
        newState.pivot += delta
        // position = pivot − viewDirection × distance, so growing distance by the move's
        // component along viewDirection leaves the camera's depth unchanged.
        let depth = cameraState.distance + simd_dot(delta, cameraState.viewDirection)
        newState.distance = clampedPivotDistance(depth)
        setCameraState(newState)
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
        // Invert updateRotationFromSpherical exactly: R = Rz(theta) · Rx(beta) · Rz(roll) with
        // beta = phi − π/2 (a Z-X-Z Euler decomposition). The previous acos/atan2 of the back
        // vector did not match that parametrization, so the first turntable orbit after init,
        // reset or any animation snapped the camera to a different orientation.
        let m = simd_float3x3(simd_normalize(cameraState.rotation))
        // m.columns.c[r] is R[r][c].
        var beta = acos(simd_clamp(m.columns.2.z, -1, 1))
        if sin(beta) > 1e-5 {
            theta = atan2(m.columns.2.x, -m.columns.2.y)
            rollAngle = atan2(m.columns.0.z, m.columns.1.z)
            // Every rotation has a second decomposition, Rz(θ + π) · Rx(−β) · Rz(roll − π).
            // Prefer the one with the smaller roll: an upside-down camera is then a tilt over
            // the pole, as a vertical drag leaves it, rather than a half roll, under which the
            // next vertical drag would tilt the wrong way.
            if abs(rollAngle) > .pi / 2 {
                theta += .pi
                beta = -beta
                rollAngle += rollAngle > 0 ? -.pi : .pi
            }
        } else {
            // Looking straight along ±Z: theta and roll turn about the same axis, so fold it all
            // into theta.
            theta = atan2(m.columns.0.y, m.columns.0.x)
            rollAngle = 0
        }
        phi = beta + .pi / 2
        if phi < 0 { phi += 2 * .pi }
    }

    /// Re-reads the turntable angles if the rotation was changed by something other than the
    /// turntable (an arcball or first-person drag, a roll in those styles), so the next
    /// turntable orbit continues from the current view instead of snapping.
    private func syncSphericalIfStale() {
        let rotZ = simd_quatf(angle: theta, axis: SIMD3<Float>(0, 0, 1))
        let rotX = simd_quatf(angle: phi - .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let rotRoll = simd_quatf(angle: rollAngle, axis: SIMD3<Float>(0, 0, 1))
        let stored = simd_normalize(rotZ * rotX * rotRoll)
        if abs(simd_dot(stored.vector, simd_normalize(cameraState.rotation).vector)) < 0.99999 {
            updateSphericalFromRotation()
        }
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
        setCameraState(newState)
    }

    // MARK: - Animation Timer

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }

        lastUpdateTime = Date.timeIntervalSinceReferenceDate
        let interval = 1.0 / Double(max(1, preferredFramesPerSecond))
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
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

        if !advance(by: deltaTime) {
            stopAnimationTimer()
        }
    }

    /// Advances animation and inertia by `deltaTime` seconds.
    ///
    /// Velocities are in drag points per 1/60 s, so each tick moves `velocity * deltaTime * 60`
    /// and keeps `(1 - dampingFactor)^(deltaTime * 60)` of its velocity. At 60 Hz that is the
    /// historical per-frame step; at any other rate, or when timer ticks coalesce, the motion
    /// stays the same over time.
    ///
    /// - Returns: `true` while there is still motion to animate.
    func advance(by deltaTime: Float) -> Bool {
        var needsContinue = false
        let frames = deltaTime * 60
        let decay = pow(max(0, 1.0 - dampingFactor), frames)

        // Animation update
        if isAnimating, let start = animationStart, let target = animationTarget {
            // Ease-out curve.
            let previousT = 1.0 - pow(1.0 - min(animationProgress, 1), 3)
            animationProgress += deltaTime / animationDuration
            let finished = animationProgress >= 1.0
            let t: Float = finished ? 1 : 1.0 - pow(1.0 - animationProgress, 3)

            if animatesPivotOnly, let depth = pivotDepthAnimation {
                // Along the line of sight as it is now, from where the camera is now, so momentum
                // that turned or panned the view meanwhile is kept and the camera never moves.
                setDistanceKeepingPosition(
                    cameraState.distance + (depth.target - depth.start) * (t - previousT))
            } else if animatesPivotOnly {
                // Move the pivot by this tick's share of the way, so pan momentum that moves it
                // too is kept, and leave the rotation alone.
                movePivotKeepingDepth(by: (target.pivot - start.pivot) * (t - previousT))
            } else if finished {
                setCameraState(target)
                updateSphericalFromRotation()
            } else {
                setCameraState(start.interpolated(to: target, t: t))
            }

            if finished {
                isAnimating = false
                animationTarget = nil
                animatesPivotOnly = false
                pivotDepthAnimation = nil
            } else {
                needsContinue = true
            }
        }

        // Inertia update
        if simd_length(angularVelocity) > 0.001 {
            orbitStep(
                deltaX: angularVelocity.x * frames,
                deltaY: angularVelocity.y * frames)
            angularVelocity *= decay
            needsContinue = true
        } else {
            angularVelocity = .zero
            // The momentum has died out, so a released drag is over.
            if orbitDrag?.released == true { orbitDrag = nil }
        }

        if simd_length(panVelocity) > 0.001 {
            pan(deltaX: panVelocity.x * frames, deltaY: panVelocity.y * frames)
            panVelocity *= decay
            needsContinue = true
        } else {
            panVelocity = .zero
        }

        return needsContinue
    }
}
