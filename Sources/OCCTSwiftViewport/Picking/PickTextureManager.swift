// PickTextureManager.swift
// ViewportKit
//
// Manages the RG32Uint pick ID texture the 1x pick pass renders into.

import Metal

/// Owns and recreates the RG32Uint pick ID texture when the drawable size changes.
///
/// One texel is 8 bytes (R = object index, G = primitive index and kind; see `PickEncoding`), so
/// the texture costs `8 * width * height` bytes: 16.6 MB at 1920 x 1080 and 66.4 MB at 3840 x 2160,
/// twice what the R32Uint texture it replaced took. It is rendered in its own 1x pass (no MSAA)
/// and stored `.private`.
@MainActor
final class PickTextureManager {

    private let device: MTLDevice
    private(set) var texture: MTLTexture?
    private(set) var width: Int = 0
    private(set) var height: Int = 0

    init(device: MTLDevice) {
        self.device = device
    }

    /// Ensures the pick texture matches the given size, recreating if necessary.
    ///
    /// - Parameters:
    ///   - newWidth: Drawable width in pixels.
    ///   - newHeight: Drawable height in pixels.
    func ensureSize(width newWidth: Int, height newHeight: Int) {
        guard newWidth > 0, newHeight > 0 else { return }
        guard newWidth != width || newHeight != height else { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Uint,
            width: newWidth,
            height: newHeight,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private

        texture = device.makeTexture(descriptor: desc)
        width = newWidth
        height = newHeight
    }
}
