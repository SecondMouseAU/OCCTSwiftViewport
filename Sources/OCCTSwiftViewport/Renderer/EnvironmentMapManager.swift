// EnvironmentMapManager.swift
// ViewportKit
//
// Manages HDR environment maps for image-based lighting (IBL).
// Loads equirectangular HDR → cube map, generates prefiltered specular
// mip chain, diffuse irradiance map, and BRDF LUT.

@preconcurrency import Metal

@MainActor
final class EnvironmentMapManager {

    private let device: MTLDevice
    private let equirectToCubePipeline: MTLComputePipelineState?
    private let prefilterPipeline: MTLComputePipelineState?
    private let irradiancePipeline: MTLComputePipelineState?
    private let brdfPipeline: MTLComputePipelineState?

    private(set) var cubeMap: MTLTexture?
    private(set) var prefilteredSpecularMap: MTLTexture?
    private(set) var irradianceMap: MTLTexture?
    private(set) var brdfLUT: MTLTexture?

    var hasEnvironmentMap: Bool { cubeMap != nil }

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device

        self.equirectToCubePipeline = Self.makeComputePipeline(
            device: device, library: library, name: "equirect_to_cubemap")
        self.prefilterPipeline = Self.makeComputePipeline(
            device: device, library: library, name: "prefilter_environment")
        self.irradiancePipeline = Self.makeComputePipeline(
            device: device, library: library, name: "irradiance_convolution")
        self.brdfPipeline = Self.makeComputePipeline(
            device: device, library: library, name: "brdf_integration")

        // Pre-generate BRDF LUT (resolution-independent, only needs to be done once)
        generateBRDFLUT(commandQueue: device.makeCommandQueue()!)
    }

    private static func makeComputePipeline(device: MTLDevice, library: MTLLibrary, name: String)
        -> MTLComputePipelineState?
    {
        guard let function = library.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }

    func clear() {
        cubeMap = nil
        prefilteredSpecularMap = nil
        irradianceMap = nil
    }

    // MARK: - Configuration-driven loading

    /// Where a `LightingConfiguration` asks the environment map to come from.
    enum ConfiguredSource {
        case url(URL)
        case data(Data)

        /// The source `lighting` names, with `environmentMapURL` taking precedence.
        nonisolated static func from(_ lighting: LightingConfiguration) -> ConfiguredSource? {
            if let url = lighting.environmentMapURL { return .url(url) }
            if let data = lighting.environmentMapData { return .data(data) }
            return nil
        }

        /// Whether two sources name the same map, cheaply enough to ask every frame.
        ///
        /// Large `Data` is compared by storage identity rather than by content, so an unchanged
        /// configuration costs a pointer compare; a fresh buffer with identical bytes reloads
        /// once, which is harmless.
        nonisolated static func same(_ a: ConfiguredSource?, _ b: ConfiguredSource?) -> Bool {
            switch (a, b) {
            case (nil, nil):
                return true
            case (.url(let x), .url(let y)):
                return x == y
            case (.data(let x), .data(let y)):
                guard x.count == y.count else { return false }
                if x.count <= 4096 { return x == y }
                let px = x.withUnsafeBytes { $0.baseAddress }
                let py = y.withUnsafeBytes { $0.baseAddress }
                return px == py
            default:
                return false
            }
        }
    }

    /// What `sync(with:commandQueue:)` should do when the configured source moves on.
    enum SyncAction: Equatable {
        case none
        case load
        case clear
    }

    /// Decides how to react to the configuration's source changing from `previous` to `current`.
    ///
    /// Nothing happens while the source is unchanged, so a map loaded explicitly through
    /// `ViewportRenderer.loadEnvironmentMap(...)` is not cleared by a configuration that never
    /// named one.
    nonisolated static func syncAction(
        previous: ConfiguredSource?, current: ConfiguredSource?
    ) -> SyncAction {
        if ConfiguredSource.same(previous, current) { return .none }
        return current == nil ? .clear : .load
    }

    /// The source last seen in a configuration, kept (with its `Data` retained) for comparison.
    private var lastConfiguredSource: ConfiguredSource?

    /// Loads or clears the environment map when the configuration's map source has changed.
    ///
    /// Called by both renderers once per frame. A URL that fails to decode is skipped, not
    /// retried every frame, and the previous environment stays.
    func sync(with lighting: LightingConfiguration, commandQueue: MTLCommandQueue) {
        let current = ConfiguredSource.from(lighting)
        let action = Self.syncAction(previous: lastConfiguredSource, current: current)
        lastConfiguredSource = current
        switch (action, current) {
        case (.load, .url(let url)?):
            // A bad file leaves the previous environment in place (see loadHDR); the failure is
            // not retried until the configuration names a different source.
            try? loadHDR(url: url, commandQueue: commandQueue)
        case (.load, .data(let data)?):
            loadEquirectangular(data: data, commandQueue: commandQueue)
        case (.clear, _):
            clear()
        default:
            break
        }
    }

    /// Loads equirectangular HDR bytes and derives the cubemap and both IBL textures from them.
    ///
    /// Expects the `Int32 width | Int32 height | RGBA32Float pixels` layout. Data too short to
    /// hold that 8-byte header is ignored: the call returns silently and the existing textures
    /// are left as they were.
    func loadEquirectangular(data: Data, commandQueue: MTLCommandQueue) {
        guard data.count > 8 else { return }

        let width = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) }
        let height = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
        let pixelDataOffset = 8
        let expectedSize = pixelDataOffset + Int(width) * Int(height) * 16

        guard data.count >= expectedSize, width > 0, height > 0 else { return }

        let eqDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        eqDesc.usage = [.shaderRead]
        guard let eqTexture = device.makeTexture(descriptor: eqDesc) else { return }

        data.withUnsafeBytes { rawBuffer in
            let pixelPtr = rawBuffer.baseAddress! + pixelDataOffset
            eqTexture.replace(
                region: MTLRegionMake2D(0, 0, Int(width), Int(height)),
                mipmapLevel: 0,
                withBytes: pixelPtr,
                bytesPerRow: Int(width) * 16
            )
        }

        let cubeSize = 256
        generateCubeMap(from: eqTexture, size: cubeSize, commandQueue: commandQueue)
    }

    /// Loads a Radiance `.hdr` (RGBE) file from disk and builds the IBL textures from it.
    ///
    /// On success `cubeMap`, `prefilteredSpecularMap` and `irradianceMap` are all populated.
    /// Parse failures propagate out of `HDRLoader` before any texture is touched, so the
    /// previously loaded environment survives a bad file.
    func loadHDR(url: URL, commandQueue: MTLCommandQueue) throws {
        let (width, height, pixels) = try HDRLoader.loadFromURL(url)
        loadEquirectangular(
            width: width, height: height, pixels: pixels, commandQueue: commandQueue)
    }

    /// Loads pre-decoded equirectangular RGBA32Float pixels into the IBL pipeline.
    /// `pixels` length must be `width * height * 4`.
    func loadEquirectangular(
        width: Int,
        height: Int,
        pixels: [Float],
        commandQueue: MTLCommandQueue
    ) {
        guard pixels.count == width * height * 4, width > 0, height > 0 else { return }

        let eqDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        eqDesc.usage = [.shaderRead]
        guard let eqTexture = device.makeTexture(descriptor: eqDesc) else { return }

        pixels.withUnsafeBufferPointer { ptr in
            eqTexture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width * 16
            )
        }

        let cubeSize = 256
        generateCubeMap(from: eqTexture, size: cubeSize, commandQueue: commandQueue)
    }

    private func generateCubeMap(
        from equirect: MTLTexture, size: Int, commandQueue: MTLCommandQueue
    ) {
        guard let pipeline = equirectToCubePipeline else { return }

        // Create cube map
        let cubeDesc = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba16Float,
            size: size,
            mipmapped: true
        )
        cubeDesc.usage = [.shaderRead, .shaderWrite]
        cubeDesc.storageMode = .private
        guard let cube = device.makeTexture(descriptor: cubeDesc) else { return }
        self.cubeMap = cube

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(equirect, index: 0)
        encoder.setTexture(cube, index: 1)

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (size + 15) / 16,
            height: (size + 15) / 16,
            depth: 6
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        // Generate mipmaps
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: cube)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Generate prefiltered specular and irradiance
        generatePrefilteredSpecular(from: cube, commandQueue: commandQueue)
        generateIrradiance(from: cube, commandQueue: commandQueue)
    }

    private func generatePrefilteredSpecular(from cube: MTLTexture, commandQueue: MTLCommandQueue) {
        guard let pipeline = prefilterPipeline else { return }

        let size = 128
        let mipLevels = 8

        let desc = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba16Float,
            size: size,
            mipmapped: true
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        desc.mipmapLevelCount = mipLevels
        guard let prefiltered = device.makeTexture(descriptor: desc) else { return }
        self.prefilteredSpecularMap = prefiltered

        for mip in 0..<mipLevels {
            let mipSize = max(size >> mip, 1)
            let roughness = Float(mip) / Float(mipLevels - 1)

            // Create a view for this mip level
            guard
                let mipView = prefiltered.makeTextureView(
                    pixelFormat: .rgba16Float,
                    textureType: .typeCube,
                    levels: mip..<(mip + 1),
                    slices: 0..<6
                )
            else { continue }

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeComputeCommandEncoder()
            else { continue }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(cube, index: 0)
            encoder.setTexture(mipView, index: 1)
            var roughnessValue = roughness
            encoder.setBytes(&roughnessValue, length: MemoryLayout<Float>.size, index: 0)

            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: max((mipSize + 15) / 16, 1),
                height: max((mipSize + 15) / 16, 1),
                depth: 6
            )
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
    }

    private func generateIrradiance(from cube: MTLTexture, commandQueue: MTLCommandQueue) {
        guard let pipeline = irradiancePipeline else { return }

        let size = 32

        let desc = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba16Float,
            size: size,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let irr = device.makeTexture(descriptor: desc) else { return }
        self.irradianceMap = irr

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(cube, index: 0)
        encoder.setTexture(irr, index: 1)

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (size + 15) / 16,
            height: (size + 15) / 16,
            depth: 6
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func generateBRDFLUT(commandQueue: MTLCommandQueue) {
        guard let pipeline = brdfPipeline else { return }

        let size = 256
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,
            width: size,
            height: size,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let lut = device.makeTexture(descriptor: desc) else { return }
        self.brdfLUT = lut

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(lut, index: 0)

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (size + 15) / 16,
            height: (size + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
