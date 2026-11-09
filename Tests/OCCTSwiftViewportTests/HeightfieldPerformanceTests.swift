// HeightfieldPerformanceTests.swift
// OCCTSwiftViewport Tests
//
// Issue #139 spike: frame-time measurements for a 2000 x 2000-cell field, with and without 200
// edits of 130 x 120 cells per frame. Hardware-dependent, so nothing here asserts a timing and the
// whole suite runs only with `VIEWPORT_SPIKE_PERF=1`:
//
//     VIEWPORT_SPIKE_PERF=1 swift test --filter HeightfieldPerformanceTests
//
// Each scenario prints its median CPU and GPU milliseconds over the measured frames.

import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite(
    "Heightfield performance (#139 spike, VIEWPORT_SPIKE_PERF=1)",
    .enabled(if: ProcessInfo.processInfo.environment["VIEWPORT_SPIKE_PERF"] == "1"),
    .serialized)
struct HeightfieldPerformanceTests {

    struct Sample {
        var replaceMs: Double
        var updateMs: Double
        var planMs: Double
        var encodeMs: Double
        var gpuMs: Double
        var uploadedBytes: Int
        var uploadedTiles: Int
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Renders `frames` frames of a camera orbiting the field, applying `edits(frame)` before each,
    /// and returns the per-frame samples after `warmup` frames.
    private func run(
        width: Int, height: Int, msaa: Int, frames: Int, warmup: Int = 8,
        edits: (Heightfield, Int) -> Void
    ) throws -> [Sample] {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return []
        }
        let field = HeightfieldScene.terrainField(width: 2000, height: 2000)
        let body = HeightfieldScene.body(field)
        var samples: [Sample] = []
        for frame in 0..<(frames + warmup) {
            // The camera moves every frame, so every frame re-plans its levels.
            let angle = Float(frame) * 0.03
            let camera = CameraState(
                rotation: simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
                    * simd_quatf(angle: 0.9, axis: SIMD3(1, 0, 0)),
                distance: 2600, pivot: SIMD3(1000, 1000, 0))
            var options = HeightfieldScene.options(width: width, height: height, camera: camera)
            options.msaaSampleCount = msaa
            let editStart = DispatchTime.now().uptimeNanoseconds
            edits(field, frame)
            let replaceMs = Double(DispatchTime.now().uptimeNanoseconds - editStart) * 1e-6
            let state = renderer.heightfieldState(forBodyID: "field")
            let bytesBefore = state?.uploadedBytes ?? 0
            let tilesBefore = state?.uploadedTiles ?? 0
            _ = renderer.render(bodies: [body], options: options)
            guard frame >= warmup, let state = renderer.heightfieldState(forBodyID: "field") else {
                continue
            }
            samples.append(
                Sample(
                    replaceMs: replaceMs, updateMs: state.lastUpdateSeconds * 1e3,
                    planMs: state.lastPlanSeconds * 1e3,
                    encodeMs: renderer.lastEncodeSeconds * 1e3,
                    gpuMs: renderer.lastGPUSeconds * 1e3,
                    uploadedBytes: state.uploadedBytes - bytesBefore,
                    uploadedTiles: state.uploadedTiles - tilesBefore))
        }
        return samples
    }

    private func report(_ name: String, _ samples: [Sample]) {
        func m(_ key: KeyPath<Sample, Double>) -> Double {
            Self.median(samples.map { $0[keyPath: key] })
        }
        let bytes = Self.median(samples.map { Double($0.uploadedBytes) })
        let tiles = Self.median(samples.map { Double($0.uploadedTiles) })
        let line = String(
            format:
                "PERF %@: gpu %.2f ms, encode (CPU, whole render) %.2f ms [update %.2f, plan %.2f], "
                + "replace x200 %.2f ms, upload %.1f MB (%.0f tiles)",
            name, m(\.gpuMs), m(\.encodeMs), m(\.updateMs), m(\.planMs), m(\.replaceMs),
            bytes / 1_048_576, tiles)
        print(line)
    }

    @Test("2000 x 2000, camera moving, no edits")
    func cameraMoving() throws {
        for (width, height, msaa) in [(1668, 1194, 4), (1024, 768, 4), (1668, 1194, 1)] {
            let samples = try run(width: width, height: height, msaa: msaa, frames: 40) { _, _ in }
            report("static \(width)x\(height) msaa\(msaa)", samples)
        }
    }

    @Test("Where the GPU time goes: variants of the static scene")
    func variants() throws {
        guard let renderer = OffscreenRenderer() else { return }
        let field = HeightfieldScene.terrainField(width: 2000, height: 2000)
        let body = HeightfieldScene.body(field)
        func measure(
            _ name: String, mode: DisplayMode = .shaded, msaa: Int = 4, target: Float = 4,
            forced: Int? = nil, size: (Int, Int) = (1668, 1194), allPasses: Bool = false
        ) {
            renderer.heightfieldTargetPixels = target
            renderer.heightfieldForcedLevel = forced
            var gpu: [Double] = []
            var tiles = 0
            var histogram: [Int] = []
            for frame in 0..<20 {
                let angle = Float(frame) * 0.03
                let camera = CameraState(
                    rotation: simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
                        * simd_quatf(angle: 0.9, axis: SIMD3(1, 0, 0)),
                    distance: 2600, pivot: SIMD3(1000, 1000, 0))
                var options = HeightfieldScene.options(
                    width: size.0, height: size.1, camera: camera, displayMode: mode)
                options.msaaSampleCount = msaa
                if allPasses {
                    // Shadow map, SSAO and silhouettes: the shadow and depth prepasses draw the
                    // field again.
                    options.lightingConfiguration.shadowsEnabled = true
                    options.lightingConfiguration.enableSSAO = true
                    options.enableSilhouettes = true
                }
                _ = renderer.render(bodies: [body], options: options)
                if frame >= 5 { gpu.append(renderer.lastGPUSeconds * 1e3) }
                if let plan = renderer.heightfieldState(forBodyID: "field")?.lastPlan {
                    tiles = plan.tileCount
                    histogram = plan.levelHistogram
                }
            }
            print(
                String(
                    format: "VARIANT %@: gpu %.2f ms (%d tiles, levels %@)", name, Self.median(gpu),
                    tiles, "\(histogram)"))
        }
        measure("shaded msaa4 target2", target: 2)
        measure("unlit msaa4 target2", mode: .unlit, target: 2)
        measure("shaded msaa1 target2", msaa: 1, target: 2)
        measure("shaded msaa4 target4")
        measure("shaded msaa4 target4 + shadows + SSAO + silhouettes", allPasses: true)
        measure("shaded msaa4 target8", target: 8)
        measure("shaded msaa4 forced L3", forced: 3)
        measure("shaded msaa4 forced L5", forced: 5)
        measure("shaded msaa4 forced L6", forced: 6)
        measure("shaded msaa4 target2 1024x768", target: 2, size: (1024, 768))
    }

    @Test("The same surface as an ordinary mesh body, for comparison")
    func meshBaseline() throws {
        guard let renderer = OffscreenRenderer() else { return }
        // Every other cell of the 2000 x 2000 field (stride 2): the triangle count the heightfield
        // draws at level 1.
        let n = 1000
        var positions: [Float] = []
        var normals: [Float] = []
        positions.reserveCapacity(n * n * 3)
        normals.reserveCapacity(n * n * 3)
        for j in 0..<n {
            for i in 0..<n {
                positions += [
                    Float(i * 2) + 0.5, Float(j * 2) + 0.5, HeightfieldScene.terrain(i * 2, j * 2),
                ]
                normals += [0, 0, 1]
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((n - 1) * (n - 1) * 6)
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let v00 = UInt32(j * n + i)
                indices += [
                    v00, v00 + 1, v00 + UInt32(n) + 1, v00, v00 + UInt32(n) + 1, v00 + UInt32(n),
                ]
            }
        }
        let body = ViewportBody.directMesh(
            id: "mesh", positions: positions, normals: normals, indices: indices,
            color: SIMD4(0.25, 0.65, 0.3, 1))
        for msaa in [4, 1] {
            var gpu: [Double] = []
            for frame in 0..<20 {
                let camera = CameraState(
                    rotation: simd_quatf(angle: Float(frame) * 0.03, axis: SIMD3(0, 0, 1))
                        * simd_quatf(angle: 0.9, axis: SIMD3(1, 0, 0)),
                    distance: 2600, pivot: SIMD3(1000, 1000, 0))
                var options = HeightfieldScene.options(width: 1668, height: 1194, camera: camera)
                options.msaaSampleCount = msaa
                _ = renderer.render(bodies: [body], options: options)
                if frame >= 5 { gpu.append(renderer.lastGPUSeconds * 1e3) }
            }
            print(
                String(
                    format: "VARIANT mesh baseline (%d tris) msaa%d: gpu %.2f ms",
                    (n - 1) * (n - 1) * 2,
                    msaa, Self.median(gpu)))
        }
    }

    /// 200 edits of 130 x 120 per frame, with the payloads built up front so only `replace` is
    /// timed. `sliding` regions overlap almost entirely; otherwise they are disjoint.
    private func editLoad(sliding: Bool) -> (Heightfield, Int) -> Void {
        let field = HeightfieldScene.terrainField(width: 2000, height: 2000)
        let regions =
            sliding
            ? HeightfieldUpdates.overlappingRegions(
                count: 200, size: SIMD2(130, 120), from: SIMD2(700, 800))
            : HeightfieldUpdates.disjointRegions(count: 200, size: SIMD2(130, 120), in: field)
        let heights = [0, 1].map { v in
            regions.enumerated().map { HeightfieldUpdates.patch($1, seed: $0 + v * 1000) }
        }
        let attributes = regions.enumerated().map { HeightfieldUpdates.attributes($1, seed: $0) }
        return { field, frame in
            for (i, region) in regions.enumerated() {
                field.replace(
                    region: region, heights: heights[frame & 1][i], attributes: attributes[i])
            }
        }
    }

    @Test("GPU cost of the update alone: blits and pyramid for the dirty tiles")
    func updateOnly() throws {
        guard let renderer = OffscreenRenderer() else { return }
        for sliding in [true, false] {
            let field = HeightfieldScene.terrainField(width: 2000, height: 2000)
            let body = HeightfieldScene.body(field)
            let options = HeightfieldScene.options(
                width: 256, height: 256,
                camera: HeightfieldScene.camera(
                    pivot: SIMD3(1000, 1000, 0), distance: 2600, tilt: 0.9))
            _ = renderer.render(bodies: [body], options: options)
            let state = try #require(renderer.heightfieldState(forBodyID: "field"))
            let edits = editLoad(sliding: sliding)
            var gpu: [Double] = []
            var cpu: [Double] = []
            var tiles: [Double] = []
            for frame in 0..<30 {
                edits(field, frame)
                let before = state.uploadedTiles
                guard let seconds = state.timedUpdate(commandQueue: renderer.testCommandQueue)
                else { continue }
                if frame >= 5 {
                    gpu.append(seconds * 1e3)
                    cpu.append(state.lastUpdateSeconds * 1e3)
                    tiles.append(Double(state.uploadedTiles - before))
                }
            }
            print(
                String(
                    format:
                        "UPDATE-ONLY %@ x200: gpu %.2f ms, cpu encode %.2f ms, %.0f tiles, %d blit commands total",
                    sliding ? "sliding" : "disjoint", Self.median(gpu), Self.median(cpu),
                    Self.median(tiles), state.blitCommands))
        }
    }

    @Test("2000 x 2000, camera moving, 200 sliding 130 x 120 edits per frame")
    func slidingEdits() throws {
        let samples = try run(
            width: 1668, height: 1194, msaa: 4, frames: 40, edits: editLoad(sliding: true))
        report("sliding edits x200 1668x1194 msaa4", samples)
    }

    @Test("2000 x 2000, camera moving, 200 disjoint 130 x 120 edits per frame (worst case)")
    func disjointEdits() throws {
        let samples = try run(
            width: 1668, height: 1194, msaa: 4, frames: 40, edits: editLoad(sliding: false))
        report("disjoint edits x200 1668x1194 msaa4", samples)
    }
}
