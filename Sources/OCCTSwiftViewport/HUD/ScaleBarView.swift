// ScaleBarView.swift
// ViewportKit
//
// Screen-space scale bar HUD: shows the world length of a fixed on-screen span at
// the camera's focus depth. A Graphic3d_TransMode-style overlay (ignores camera).

import SwiftUI

/// A fixed-corner scale bar reporting the world length of a ~100-point on-screen
/// span at the camera's focus (pivot) depth.
///
/// The represented length snaps to a nice 1 / 2 / 5 × 10ⁿ value via
/// `ScaleBarMetrics`. For perspective cameras the reading is exact only at the
/// pivot depth (scale varies with depth); for orthographic cameras it is exact
/// everywhere.
public struct ScaleBarView: View {

    @ObservedObject private var controller: ViewportController

    /// Viewport height in points — needed to convert camera scale to points.
    private let viewportHeightPoints: CGFloat

    /// Optional unit suffix shown after the number (library is unit-agnostic).
    private let unitLabel: String

    /// Target on-screen bar length in points; actual length snaps to a nice value.
    private let targetPoints: CGFloat

    public init(controller: ViewportController,
                viewportHeightPoints: CGFloat,
                unitLabel: String = "",
                targetPoints: CGFloat = 100) {
        self.controller = controller
        self.viewportHeightPoints = viewportHeightPoints
        self.unitLabel = unitLabel
        self.targetPoints = targetPoints
    }

    public var body: some View {
        let wpp = controller.cameraState.worldUnitsPerPoint(
            viewportHeightPoints: Float(viewportHeightPoints)
        )
        if let metrics = ScaleBarMetrics(worldUnitsPerPoint: wpp,
                                         targetPoints: targetPoints,
                                         unitLabel: unitLabel) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metrics.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                bar(length: metrics.pointLength)
            }
        }
    }

    /// A horizontal bar with end ticks.
    private func bar(length: CGFloat) -> some View {
        let tick: CGFloat = 5
        return Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: tick))
            path.move(to: CGPoint(x: 0, y: tick / 2))
            path.addLine(to: CGPoint(x: length, y: tick / 2))
            path.move(to: CGPoint(x: length, y: 0))
            path.addLine(to: CGPoint(x: length, y: tick))
        }
        .stroke(Color.secondary, lineWidth: 1.5)
        .frame(width: length, height: tick)
    }
}

#if DEBUG
struct ScaleBarView_Previews: PreviewProvider {
    static var previews: some View {
        ScaleBarView(controller: ViewportController(),
                     viewportHeightPoints: 600,
                     unitLabel: "mm")
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
#endif
