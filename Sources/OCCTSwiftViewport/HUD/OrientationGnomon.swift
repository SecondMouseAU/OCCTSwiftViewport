// OrientationGnomon.swift
// ViewportKit
//
// Screen-space corner axes legend (X/Y/Z) that reflects camera orientation but
// ignores camera translation — a Graphic3d_TransMode / AIS trihedron analogue.

import SwiftUI
import simd

/// A small fixed-corner gnomon showing the orientation of the world X / Y / Z axes
/// under the current camera rotation.
///
/// Unlike the world-space axes drawn by the renderer, this overlay stays pinned to
/// a viewport corner and only rotates — it is a pure orientation aid (HUD), never
/// affected by zoom or pan.
public struct OrientationGnomon: View {

    @ObservedObject private var controller: ViewportController

    public init(controller: ViewportController) {
        self.controller = controller
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: size / 2, y: size / 2)
            let radius = size / 2 - 9
            let axes = Self.projectedAxes(rotation: controller.cameraState.rotation)

            ZStack {
                ForEach(axes) { axis in
                    let tip = CGPoint(
                        x: center.x + axis.direction.width * radius,
                        y: center.y + axis.direction.height * radius
                    )
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: tip)
                    }
                    .stroke(axis.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                    Text(axis.label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(axis.color)
                        .position(tip)
                }
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Projection (pure, testable)

    /// A world axis projected to gnomon screen space.
    struct ProjectedAxis: Identifiable {
        let label: String
        /// Normalised screen direction (y points down, matching SwiftUI).
        let direction: CGSize
        let color: Color
        /// View-space depth; larger draws on top.
        let depth: Float
        var id: String { label }
    }

    /// Projects the three positive world axes into gnomon screen space for a given
    /// camera rotation, sorted back-to-front so nearer axes draw on top.
    ///
    /// Uses the same convention as `ViewCubeView`: transform into view space via the
    /// inverse rotation, map +X → right and +Y → up (screen y flipped).
    nonisolated static func projectedAxes(rotation: simd_quatf) -> [ProjectedAxis] {
        let world: [(String, SIMD3<Float>, Color)] = [
            ("X", SIMD3<Float>(1, 0, 0), .red),
            ("Y", SIMD3<Float>(0, 1, 0), .green),
            ("Z", SIMD3<Float>(0, 0, 1), .blue)
        ]
        return world.map { label, axis, color in
            let v = rotation.inverse.act(axis)
            return ProjectedAxis(
                label: label,
                direction: CGSize(width: CGFloat(v.x), height: CGFloat(-v.y)),
                color: color,
                depth: v.z
            )
        }
        .sorted { $0.depth < $1.depth }
    }
}

#if DEBUG
struct OrientationGnomon_Previews: PreviewProvider {
    static var previews: some View {
        OrientationGnomon(controller: ViewportController())
            .frame(width: 80, height: 80)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
#endif
