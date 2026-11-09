// OffscreenFrameSetup.swift
// OCCTSwiftViewport
//
// The camera, projection and clip-plane fit of one OffscreenRenderer frame, so `render` and the
// GPU pick pass derive them from the same code and cannot see different scenes.

import simd

/// The view an `OffscreenRenderer` frame is drawn from.
///
/// Built from the bodies and options exactly as `render(bodies:options:)` builds it: model
/// bounds, the grid and axes the clip fit must hold, the orthographic eye placement (#215), the
/// scene-fitted near and far planes (#57), the projection, and the packed section planes.
struct OffscreenFrameSetup {

    /// Bounds of the visible geometry-layer bodies, before the grid and axes widen them (#183).
    let modelBounds: BoundingBox?
    let gridAxisSettings: GridAxisSettings
    /// The camera drawn with: `options.cameraState`, with an orthographic eye placed in front of
    /// the scene.
    let cameraState: CameraState
    let viewMatrix: simd_float4x4
    let projMatrix: simd_float4x4
    let viewProjection: simd_float4x4
    let nearClip: Float
    let farClip: Float
    /// The first four enabled section planes, packed for the shaders.
    let clipPlanes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    let clipPlaneCount: UInt32

    @MainActor
    init(bodies: [ViewportBody], options: OffscreenRenderOptions) {
        // Scene-adaptive clip planes (issue #57): fit near/far to the visible
        // geometry so depth precision isn't crushed by a fixed 0.01/10000 range.
        // The shadow frustum reuses these model bounds, before the grid/axes widen them
        // for the clip fit (issue #183).
        let modelBounds = RendererSharedSetup.sceneBounds(of: bodies)
        let gridAxisSettings = GridAxisSettings(
            options: options, sceneBounds: modelBounds,
            background: options.resolvedBackgroundColor)

        // An orthographic eye in front of the bodies, overlays and axes, as `MetalViewportView`
        // keeps the live one (#215): an eye inside the scene would near-clip it.
        let cameraState = OffscreenRenderer.renderCamera(options: options) {
            RendererSharedSetup.orthographicEyeBounds(
                modelBounds: modelBounds, bodies: bodies, settings: gridAxisSettings,
                showAxes: options.showAxes, cameraState: options.cameraState)
        }
        let viewMatrix = cameraState.viewMatrix
        let sceneBounds = GridAxisGeometry.clipBounds(
            sceneBounds: modelBounds,
            settings: gridAxisSettings,
            cameraState: options.cameraState,
            showGrid: options.showGrid,
            showAxes: options.showAxes
        )
        // The planes are fitted as orthographic whenever the projection is, including an
        // `explicitOrthoBounds` one on a perspective camera (#217).
        var clipCamera = cameraState
        clipCamera.isOrthographic = OffscreenRenderer.isOrthographic(options)
        let clip = clipCamera.clipPlanes(
            sceneBounds: RendererSharedSetup.clipFitBounds(
                sceneBounds, includingOverlaysOf: bodies,
                in: OffscreenRenderer.wideViewFrustum(options: options, camera: cameraState),
                // Orthographic: cap overlays as the eye placement does, as live (#215).
                capBasis: OffscreenRenderer.isOrthographic(options)
                    ? RendererSharedSetup.overlayCapBasis(
                        modelBounds: modelBounds, settings: gridAxisSettings,
                        showAxes: options.showAxes, cameraState: options.cameraState) : nil))
        let projMatrix = OffscreenRenderer.projectionMatrix(
            options: options, near: clip.near, far: clip.far)
        let packed = RendererSharedSetup.packClipPlanes(options.clipPlanes)

        self.modelBounds = modelBounds
        self.gridAxisSettings = gridAxisSettings
        self.cameraState = cameraState
        self.viewMatrix = viewMatrix
        self.projMatrix = projMatrix
        self.viewProjection = projMatrix * viewMatrix
        self.nearClip = clip.near
        self.farClip = clip.far
        self.clipPlanes = packed.planes
        self.clipPlaneCount = packed.count
    }

    /// The scene uniforms for `options`, with `modelMatrix` the identity for the caller to set.
    ///
    /// The light matrix, shadow, environment and debug parameters belong to the lit passes; the
    /// pick pass reads none of them and leaves them at their defaults.
    @MainActor
    func uniforms(
        options: OffscreenRenderOptions,
        lightViewProjection: simd_float4x4 = matrix_identity_float4x4,
        shadowParams: SIMD4<Float>,
        shadowParams2: SIMD4<Float> = .zero,
        iblParams: SIMD4<Float> = .zero
    ) -> Uniforms {
        Uniforms(
            viewProjection: viewProjection,
            viewMatrix: viewMatrix,
            // Parallel view vectors in orthographic, as live (#215).
            cameraPosition: RendererSharedSetup.shadingEyePosition(
                of: cameraState, orthographic: OffscreenRenderer.isOrthographic(options)),
            nearPlane: nearClip,
            farPlane: farClip,
            lighting: options.lightingConfiguration,
            lightViewProjection: lightViewProjection,
            shadowParams: shadowParams,
            shadowParams2: shadowParams2,
            iblParams: iblParams,
            clipPlanes: clipPlanes,
            clipPlaneCount: clipPlaneCount,
            unlit: options.displayMode == .unlit,
            flatShading: !options.displayMode.usesSmoothShading,
            viewportSize: SIMD2(Float(options.width), Float(options.height)),
            selectionTint: options.selectionTint,
            hoverTint: options.hoverTint
        )
    }
}
