// ViewCubeView.swift
// ViewportKit
//
// SwiftUI ViewCube overlay for viewport orientation.

import SwiftUI
import simd

/// A 3D orientation cube overlay for the viewport.
///
/// ViewCubeView displays a miniature 3D cube that:
/// - Shows the current camera orientation
/// - Provides clickable regions to snap to standard views
/// - Includes a compass ring showing north direction
///
/// ## Example
///
/// ```swift
/// ZStack {
///     MetalViewportView(controller: controller, bodies: $bodies)
///     VStack {
///         Spacer()
///         HStack {
///             Spacer()
///             ViewCubeView(controller: controller)
///                 .frame(width: 80, height: 80)
///                 .padding()
///         }
///     }
/// }
/// ```
public struct ViewCubeView: View {

    // MARK: - Properties

    @ObservedObject private var controller: ViewportController

    /// Size of the cube face.
    private let cubeSize: CGFloat = 40

    // MARK: - Initialization

    public init(controller: ViewportController) {
        self.controller = controller
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            ZStack {
                // Compass ring
                compassRing(size: size)

                // Cube representation
                cubeView(size: size)
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Compass Ring

    private func compassRing(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                .frame(width: size - 4, height: size - 4)

            // North indicator
            let northAngle = northDirection()
            Text("N")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .offset(
                    x: cos(northAngle - .pi / 2) * (size / 2 - 8),
                    y: sin(northAngle - .pi / 2) * (size / 2 - 8)
                )
        }
    }

    private func northDirection() -> CGFloat {
        // Calculate the projection of the Y axis onto the view plane
        let rotation = controller.cameraState.rotation
        let yAxis = rotation.inverse.act(SIMD3<Float>(0, 1, 0))
        return CGFloat(atan2(yAxis.x, yAxis.y))
    }

    // MARK: - Cube View

    private func cubeView(size: CGFloat) -> some View {
        let faceSize = size * 0.4

        return ZStack {
            // Draw cube faces based on camera orientation
            // This is a simplified 2D representation

            // Calculate which faces are visible
            let visibleFaces = calculateVisibleFaces()

            ForEach(visibleFaces, id: \.face) { faceInfo in
                cubeFace(
                    face: faceInfo.face,
                    size: faceSize,
                    depth: faceInfo.depth,
                    offset: faceInfo.offset
                )
            }
        }
    }

    private struct FaceInfo: Identifiable {
        let face: ViewCubeFace
        let depth: CGFloat
        let offset: CGSize
        var id: ViewCubeFace { face }
    }

    private func calculateVisibleFaces() -> [FaceInfo] {
        let rotation = controller.cameraState.rotation

        // Camera's view direction (what the camera sees)
        let viewDir = rotation.act(SIMD3<Float>(0, 0, -1))

        var faces: [FaceInfo] = []

        // Check each face's visibility
        let faceNormals: [(ViewCubeFace, SIMD3<Float>)] = [
            (.top, SIMD3<Float>(0, 0, 1)),
            (.bottom, SIMD3<Float>(0, 0, -1)),
            (.front, SIMD3<Float>(0, -1, 0)),
            (.back, SIMD3<Float>(0, 1, 0)),
            (.right, SIMD3<Float>(1, 0, 0)),
            (.left, SIMD3<Float>(-1, 0, 0)),
        ]

        for (face, normal) in faceNormals {
            // Face is visible if its normal points toward camera
            let dot = simd_dot(normal, -viewDir)
            if dot > 0 {
                // Project face center to screen space
                let projected = projectToScreen(normal, rotation: rotation)
                faces.append(
                    FaceInfo(
                        face: face,
                        depth: CGFloat(dot),
                        offset: projected
                    ))
            }
        }

        // Sort by depth (furthest first for proper overlap)
        return faces.sorted { $0.depth < $1.depth }
    }

    private func projectToScreen(_ point: SIMD3<Float>, rotation: simd_quatf) -> CGSize {
        // Simple orthographic projection
        let rotated = rotation.inverse.act(point)
        return CGSize(
            width: CGFloat(rotated.x) * 15,
            height: CGFloat(-rotated.y) * 15
        )
    }

    private func cubeFace(face: ViewCubeFace, size: CGFloat, depth: CGFloat, offset: CGSize)
        -> some View
    {
        Button {
            let standardView = StandardView.fromViewCubeFace(face)
            controller.goToStandardView(standardView, duration: 0.3)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(faceColor(face, depth: depth))
                    .frame(width: size, height: size)

                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.primary.opacity(0.3), lineWidth: 0.5)
                    .frame(width: size, height: size)

                Text(faceLabel(face))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
        .offset(offset)
    }

    private func faceColor(_ face: ViewCubeFace, depth: CGFloat) -> Color {
        let baseColor: Color
        switch face {
        case .top:
            baseColor = Color.blue.opacity(0.3)
        case .bottom:
            baseColor = Color.blue.opacity(0.2)
        case .front, .back:
            baseColor = Color.gray.opacity(0.25)
        case .left, .right:
            baseColor = Color.gray.opacity(0.2)
        }

        // Brighten based on how much face is facing camera
        return baseColor.opacity(0.5 + depth * 0.5)
    }

    private func faceLabel(_ face: ViewCubeFace) -> String {
        switch face {
        case .top: return "T"
        case .bottom: return "B"
        case .front: return "F"
        case .back: return "Bk"
        case .right: return "R"
        case .left: return "L"
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ViewCubeView_Previews: PreviewProvider {
        static var previews: some View {
            ViewCubeView(controller: ViewportController())
                .frame(width: 100, height: 100)
                .padding()
                .previewLayout(.sizeThatFits)
        }
    }
#endif
