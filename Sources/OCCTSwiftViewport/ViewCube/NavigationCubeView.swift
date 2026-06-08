// NavigationCubeView.swift
// ViewportKit
//
// Interactive 3D navigation cube (issues #60, #62): a corner widget that tracks
// the camera. Tapping a face / edge / corner snaps to the matching view; dragging
// the cube orbits the camera (grab-and-spin). Geometry + hit-testing live in
// `NavigationCube` (unit-tested).

import SwiftUI
import simd

/// A Shapr3D / Fusion-style navigation cube. Renders the cube under the current
/// camera rotation, routes taps on faces / edges / corners to the matching
/// `ViewCubeRegion`, and orbits the camera when dragged.
public struct NavigationCubeView: View {

    @ObservedObject private var controller: ViewportController
    @State private var hovered: ViewCubeRegion?
    @State private var lastDrag: CGSize = .zero
    @State private var isOrbiting = false

    /// Movement (points) past which a press becomes an orbit rather than a tap.
    private let orbitThreshold: CGFloat = 4

    public init(controller: ViewportController) {
        self.controller = controller
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cube = NavigationCube(rotation: controller.cameraState.rotation, size: side)

            Canvas { ctx, _ in
                for face in cube.visibleFaces() {
                    let pts = face.corners
                    var path = Path()
                    path.move(to: pts[0])
                    for c in pts.dropFirst() { path.addLine(to: c) }
                    path.closeSubpath()

                    let isHovered = (hovered?.baseFaceSet.contains(face.region) ?? false)
                    ctx.fill(path, with: .color(faceColor(depth: face.depth, hovered: isHovered)))
                    ctx.stroke(path, with: .color(.primary.opacity(0.5)), lineWidth: 1.2)

                    // 3×3 grid so the edge / corner hit zones are discoverable.
                    var grid = Path()
                    for k in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                        grid.move(to: bilerp(pts, k, 0)); grid.addLine(to: bilerp(pts, k, 1))
                        grid.move(to: bilerp(pts, 0, k)); grid.addLine(to: bilerp(pts, 1, k))
                    }
                    ctx.stroke(grid, with: .color(.primary.opacity(0.18)), lineWidth: 0.75)

                    ctx.draw(
                        Text(label(face.region))
                            .font(.system(size: max(7, side * 0.11), weight: .semibold)),
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
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let moved = hypot(value.translation.width, value.translation.height)
                        if moved > orbitThreshold { isOrbiting = true }
                        if isOrbiting {
                            let dx = value.translation.width - lastDrag.width
                            let dy = value.translation.height - lastDrag.height
                            lastDrag = value.translation
                            // Grab-and-spin: always orbit (independent of the
                            // viewport's gesture-action mapping).
                            controller.handleOrbit(translation: CGSize(width: -dx, height: dy))
                        }
                    }
                    .onEnded { value in
                        if isOrbiting {
                            controller.endOrbit(velocity: CGSize(width: -value.velocity.width,
                                                                 height: value.velocity.height))
                        } else if let region = cube.region(at: value.location) {
                            controller.goToRegion(region)
                        }
                        isOrbiting = false
                        lastDrag = .zero
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Navigation cube")
    }

    /// Bilinear point within a projected face quad (corner order: −u−v, +u−v, +u+v, −u+v).
    private func bilerp(_ c: [CGPoint], _ s: CGFloat, _ t: CGFloat) -> CGPoint {
        let bottom = CGPoint(x: c[0].x + (c[1].x - c[0].x) * s, y: c[0].y + (c[1].y - c[0].y) * s)
        let top = CGPoint(x: c[3].x + (c[2].x - c[3].x) * s, y: c[3].y + (c[2].y - c[3].y) * s)
        return CGPoint(x: bottom.x + (top.x - bottom.x) * t, y: bottom.y + (top.y - bottom.y) * t)
    }

    private func faceColor(depth: Float, hovered: Bool) -> Color {
        if hovered { return Color.accentColor.opacity(0.85) }
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
            .frame(width: 110, height: 110)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
#endif
