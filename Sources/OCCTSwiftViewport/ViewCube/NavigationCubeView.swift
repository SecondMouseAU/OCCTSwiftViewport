// NavigationCubeView.swift
// ViewportKit
//
// Interactive 3D navigation cube (issue #60): a corner widget that tracks the
// camera and snaps to plan/elevation/iso views when its faces, edges, or corners
// are clicked. Geometry + hit-testing live in `NavigationCube` (unit-tested).

import SwiftUI
import simd

/// A Shapr3D / Fusion-style navigation cube. Renders the cube under the current
/// camera rotation and routes taps on faces / edges / corners to the matching
/// `ViewCubeRegion` via `ViewportController.goToRegion(_:)`.
public struct NavigationCubeView: View {

    @ObservedObject private var controller: ViewportController
    @State private var hovered: ViewCubeRegion?

    public init(controller: ViewportController) {
        self.controller = controller
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cube = NavigationCube(rotation: controller.cameraState.rotation, size: side)

            Canvas { ctx, _ in
                for face in cube.visibleFaces() {
                    var path = Path()
                    path.move(to: face.corners[0])
                    for c in face.corners.dropFirst() { path.addLine(to: c) }
                    path.closeSubpath()

                    let isHovered = (hovered?.baseFaceSet.contains(face.region) ?? false)
                    ctx.fill(path, with: .color(faceColor(depth: face.depth, hovered: isHovered)))
                    ctx.stroke(path, with: .color(.primary.opacity(0.45)), lineWidth: 1)

                    ctx.draw(
                        Text(label(face.region))
                            .font(.system(size: max(7, side * 0.12), weight: .semibold)),
                        at: face.center
                    )
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = cube.region(at: p)
                case .ended: hovered = nil
                }
            }
            #endif
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if let region = cube.region(at: value.location) {
                            controller.goToRegion(region)
                        }
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Navigation cube")
    }

    private func faceColor(depth: Float, hovered: Bool) -> Color {
        if hovered { return Color.accentColor.opacity(0.85) }
        // Brighter for the most camera-facing face.
        let shade = 0.55 + Double(max(0, min(1, depth))) * 0.35
        return Color.gray.opacity(shade)
    }

    private func label(_ region: ViewCubeRegion) -> String {
        switch region {
        case .top: return "TOP"
        case .bottom: return "BOT"
        case .front: return "FRONT"
        case .back: return "BACK"
        case .right: return "RIGHT"
        case .left: return "LEFT"
        default: return ""
        }
    }
}

#if DEBUG
struct NavigationCubeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationCubeView(controller: ViewportController())
            .frame(width: 100, height: 100)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
#endif
