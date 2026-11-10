// Bench141Scene.swift
// Issue #141: the bodies the transform benchmark moves.

import Foundation
import OCCTSwiftViewport
import simd

enum Bench141Scene {

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    /// `count` mesh bodies. Body 0 (`mover`) is the one the benchmark moves; the others sit on a
    /// grid and never change. A mix of spheres, cylinders and boxes, 12 to 3,000 triangles each.
    static func bodies(count: Int) -> [ViewportBody] {
        var out: [ViewportBody] = []
        out.reserveCapacity(count)
        var mover = ViewportBody.sphere(
            id: "mover", radius: 0.7, segments: 48, rings: 32,
            color: SIMD4(0.95, 0.35, 0.2, 1), up: .z)
        mover.transform = translation(SIMD3(0, 0, 1.2))
        out.append(mover)

        let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
        let spacing: Float = 2.4
        for i in 1..<max(count, 1) {
            let x = (Float(i % columns) - Float(columns) / 2) * spacing
            let y = (Float(i / columns) - Float(columns) / 2) * spacing
            let id = "static-\(i)"
            let shade = 0.45 + 0.4 * Float(i % 7) / 7
            let color = SIMD4<Float>(0.3, shade, 0.9 - shade * 0.4, 1)
            var body: ViewportBody
            switch i % 3 {
            case 0:
                body = .sphere(id: id, radius: 0.6, segments: 32, rings: 20, color: color, up: .z)
            case 1:
                body = .cylinder(id: id, radius: 0.5, height: 1.4, segments: 40, color: color, up: .z)
            default:
                body = .box(id: id, width: 1.1, height: 1.1, depth: 1.1, color: color, up: .z)
            }
            body.transform = translation(SIMD3(x, y, 0.7))
            out.append(body)
        }
        return out
    }

    /// Where the mover is at `phase` radians along its circle.
    static func moverTransform(phase: Double) -> simd_float4x4 {
        translation(SIMD3(Float(cos(phase)) * 3.0, Float(sin(phase)) * 3.0, 1.2))
    }
}
