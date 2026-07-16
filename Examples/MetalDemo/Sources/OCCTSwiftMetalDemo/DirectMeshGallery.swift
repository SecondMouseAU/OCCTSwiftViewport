// DirectMeshGallery.swift
// OCCTSwiftMetalDemo
//
// On-device verification for the Option A direct-mesh render path (spike
// `spike/direct-brep-rendering`, Phase 4). Builds `ViewportBody.directMesh(...)`
// bodies — de-interleaved position@buffer0 / normal@buffer2, `vertexData` empty —
// so a physical tap exercises the GPU pick-ID texture readback on a direct body,
// and the on-screen result shows SSAO + silhouettes drawn on direct bodies (the
// passes the headless OffscreenRenderer twin can't drive).

import Foundation
import simd
import OCCTSwiftViewport

enum DirectMeshGallery {

    /// De-interleave a primitive's [px,py,pz,nx,ny,nz,...] into separate arrays.
    private static func deinterleave(_ vd: [Float]) -> (pos: [Float], nrm: [Float]) {
        var pos: [Float] = [], nrm: [Float] = []
        pos.reserveCapacity(vd.count / 2)
        nrm.reserveCapacity(vd.count / 2)
        var i = 0
        while i + 5 < vd.count {
            pos.append(vd[i]);     pos.append(vd[i + 1]); pos.append(vd[i + 2])
            nrm.append(vd[i + 3]); nrm.append(vd[i + 4]); nrm.append(vd[i + 5])
            i += 6
        }
        return (pos, nrm)
    }

    /// Rebuild an interleaved primitive as a direct-mesh body with the same geometry.
    private static func direct(from ref: ViewportBody, id: String,
                               color: SIMD4<Float>, material: PBRMaterial? = nil) -> ViewportBody {
        let d = deinterleave(ref.vertexData)
        return ViewportBody.directMesh(id: id, positions: d.pos, normals: d.nrm,
                                       indices: ref.indices, color: color, material: material)
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4<Float>(1, 0, 0, 0),
                      SIMD4<Float>(0, 1, 0, 0),
                      SIMD4<Float>(0, 0, 1, 0),
                      SIMD4<Float>(t.x, t.y, t.z, 1))
    }

    /// Three direct-mesh solids (sphere / cylinder / box) spread apart, plus one
    /// overlay-layer direct box drawn always-on-top. All are pickable, so tapping
    /// each on device verifies GPU pick readback on a `usesDirectMesh` body.
    static func optionA() -> Curve2DGallery.GalleryResult {
        let steel = SIMD4<Float>(0.55, 0.72, 0.95, 1)
        let brass = SIMD4<Float>(0.85, 0.68, 0.28, 1)
        let green = SIMD4<Float>(0.35, 0.80, 0.45, 1)
        let orange = SIMD4<Float>(1.0, 0.55, 0.15, 1)

        var sphere = direct(from: ViewportBody.sphere(id: "s", radius: 1.0, segments: 40, rings: 24, color: steel),
                            id: "direct-sphere", color: steel, material: .chromedSteel)
        sphere.transform = translation(SIMD3<Float>(-2.6, 1.0, 0))
        sphere.isPickable = true

        var cyl = direct(from: ViewportBody.cylinder(id: "c", radius: 0.7, height: 2.0, segments: 40, color: brass),
                         id: "direct-cylinder", color: brass, material: .brass)
        cyl.transform = translation(SIMD3<Float>(0, 1.0, 0))
        cyl.isPickable = true

        var box = direct(from: ViewportBody.box(id: "b", width: 1.4, height: 1.4, depth: 1.4, color: green),
                         id: "direct-box", color: green)
        box.transform = translation(SIMD3<Float>(2.6, 0.7, 0))
        box.isPickable = true

        // Always-on-top overlay-layer direct body (exercises the overlay draw pass).
        var overlay = direct(from: ViewportBody.box(id: "o", width: 0.6, height: 0.6, depth: 0.6, color: orange),
                             id: "direct-overlay", color: orange)
        overlay.renderLayer = .overlay
        overlay.isPickable = true
        overlay.transform = translation(SIMD3<Float>(0, 2.6, 0))

        return Curve2DGallery.GalleryResult(
            bodies: [sphere, cyl, box, overlay],
            description: "Direct-mesh (Option A): sphere/cylinder/box + overlay box. Tap to pick — verifies GPU pick, SSAO & silhouettes on direct bodies."
        )
    }
}
