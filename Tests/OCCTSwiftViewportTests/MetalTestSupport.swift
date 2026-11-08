import Foundation
import Metal
import Testing

/// Whether this process can run the GPU test suites.
///
/// Hosted CI runners do not always expose a Metal device. Before this trait existed, every GPU suite
/// recorded an `Issue` ("Metal device unavailable") on such a host, so the `tests` job went red for a
/// reason that says nothing about the code. A suite marked `.requiresMetalDevice` is reported as
/// *skipped* instead, and runs exactly as before wherever a device exists (every developer Mac, and
/// any CI host with a GPU).
///
/// Set `OCCTSWIFT_TEST_NO_METAL=1` to rehearse a GPU-less host locally: the marked suites skip and
/// everything else must still pass.
enum MetalTestSupport {
    static let isAvailable: Bool = {
        if ProcessInfo.processInfo.environment["OCCTSWIFT_TEST_NO_METAL"] != nil { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }()
}

extension Trait where Self == ConditionTrait {
    /// Skips the test or suite when the host has no Metal device. Put it on every suite that creates a
    /// `ViewportRenderer`, an `OffscreenRenderer`, or any other GPU object.
    static var requiresMetalDevice: Self {
        .enabled(
            if: MetalTestSupport.isAvailable,
            "No Metal device on this host (GPU-less CI runner, or OCCTSWIFT_TEST_NO_METAL is set)"
        )
    }
}
