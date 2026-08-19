// MatrixUtils.swift
// ViewportKit
//
// Matrix construction utilities for camera and projection transforms.

import simd

extension simd_float4x4 {

    /// Creates a look-at view matrix.
    ///
    /// - Parameters:
    ///   - eye: Camera position in world space
    ///   - target: Point the camera is looking at
    ///   - up: World up vector
    /// - Returns: A view matrix that transforms world space to camera space
    public static func lookAt(
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let correctedUp = simd_cross(right, forward)

        // Column-major: each SIMD4 is a column
        var m = simd_float4x4(1.0)  // identity
        m.columns.0 = SIMD4<Float>(right.x, correctedUp.x, -forward.x, 0)
        m.columns.1 = SIMD4<Float>(right.y, correctedUp.y, -forward.y, 0)
        m.columns.2 = SIMD4<Float>(right.z, correctedUp.z, -forward.z, 0)
        m.columns.3 = SIMD4<Float>(
            -simd_dot(right, eye),
            -simd_dot(correctedUp, eye),
            simd_dot(forward, eye),
            1
        )
        return m
    }

    /// Creates a perspective projection matrix.
    ///
    /// - Parameters:
    ///   - fovY: Vertical field of view in radians
    ///   - aspectRatio: Width / height
    ///   - near: Near clipping plane distance
    ///   - far: Far clipping plane distance
    /// - Returns: A perspective projection matrix (Metal NDC: z in [0, 1])
    public static func perspective(
        fovY: Float,
        aspectRatio: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let y = 1.0 / tanf(fovY * 0.5)
        let x = y / aspectRatio
        let z = far / (near - far)

        return simd_float4x4(
            columns: (
                SIMD4<Float>(x, 0, 0, 0),
                SIMD4<Float>(0, y, 0, 0),
                SIMD4<Float>(0, 0, z, -1),
                SIMD4<Float>(0, 0, z * near, 0)
            ))
    }

    /// Creates an orthographic projection matrix.
    ///
    /// - Parameters:
    ///   - left: Left clipping plane
    ///   - right: Right clipping plane
    ///   - bottom: Bottom clipping plane
    ///   - top: Top clipping plane
    ///   - near: Near clipping plane
    ///   - far: Far clipping plane
    /// - Returns: An orthographic projection matrix (Metal NDC: z in [0, 1])
    public static func orthographic(
        left: Float,
        right: Float,
        bottom: Float,
        top: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let width = right - left
        let height = top - bottom
        let depth = far - near

        return simd_float4x4(
            columns: (
                SIMD4<Float>(2.0 / width, 0, 0, 0),
                SIMD4<Float>(0, 2.0 / height, 0, 0),
                SIMD4<Float>(0, 0, -1.0 / depth, 0),
                SIMD4<Float>(
                    -(right + left) / width,
                    -(top + bottom) / height,
                    -near / depth,
                    1
                )
            ))
    }
}
