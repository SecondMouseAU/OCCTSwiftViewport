// ShaderLibraryLoadingTests.swift
// OCCTSwiftViewport Tests
//
// #212 moved library loading into `RendererSharedSetup.loadLibrary` and dropped the run-time
// compile of `Shaders.metal` that both renderers used to fall back to. SwiftPM's native build system
// copies the .metal source and builds no default.metallib, so in `swift build` / `swift test` on
// Xcode 26 and on hosted CI every `ViewportRenderer` and `OffscreenRenderer` init returned nil
// ("no default library was found"). Xcode's build system does produce the metallib, which is why
// the suite stayed green on developer Macs. These tests pin both paths.

import Foundation
import Metal
import Testing

@testable import OCCTSwiftViewport

@Suite("Shader library loading")
struct ShaderLibraryLoadingTests {

    /// The shader source in the checkout, so the test doesn't depend on how the build system
    /// packaged it into the resource bundle.
    private static let shaderSourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // OCCTSwiftViewportTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/OCCTSwiftViewport/Renderer/Shaders.metal")

    /// Makes a throwaway directory that `Bundle(path:)` accepts, optionally holding `Shaders.metal`.
    private func makeBundle(withShaderSource: Bool) throws -> (bundle: Bundle, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShaderLibraryLoadingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withShaderSource {
            try FileManager.default.copyItem(
                at: Self.shaderSourceURL, to: dir.appendingPathComponent("Shaders.metal"))
        }
        let bundle = try #require(Bundle(path: dir.path))
        return (bundle, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("The module bundle yields a library with the renderer's functions")
    func moduleBundleLoads() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = RendererSharedSetup.loadLibrary(device: device)
        #expect(library != nil)
        #expect(library?.functionNames.contains("depth_only_vertex") == true)
        #expect(library?.functionNames.contains("selection_mask_fragment") == true)
    }

    @Test("A bundle with the .metal source but no default.metallib is compiled at run time")
    func sourceFallbackCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let (bundle, cleanup) = try makeBundle(withShaderSource: true)
        defer { cleanup() }

        // Precondition: this is the plain-SwiftPM situation.
        #expect((try? device.makeDefaultLibrary(bundle: bundle)) == nil)

        let library = RendererSharedSetup.loadLibrary(device: device, bundle: bundle)
        #expect(library != nil, "Plain SwiftPM builds have no default.metallib; the source must be compiled")
        #expect(library?.functionNames.contains("depth_only_vertex") == true)
        #expect(library?.functionNames.contains("selection_mask_fragment") == true)
    }

    @Test("A bundle with neither a metallib nor the source returns nil instead of crashing")
    func nothingToLoad() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let (bundle, cleanup) = try makeBundle(withShaderSource: false)
        defer { cleanup() }
        #expect(RendererSharedSetup.loadLibrary(device: device, bundle: bundle) == nil)
    }
}
