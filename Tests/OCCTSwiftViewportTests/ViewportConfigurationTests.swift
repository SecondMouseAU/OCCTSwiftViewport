import Testing
@testable import OCCTSwiftViewport

@Suite("ViewportConfiguration presets")
struct ViewportConfigurationTests {

    @Test("performance preset disables the expensive per-frame passes (#42)")
    func performancePresetDisablesHeavyPasses() {
        let config = ViewportConfiguration.performance
        #expect(config.lightingConfiguration.shadowsEnabled == false)
        #expect(config.lightingConfiguration.enableSSAO == false)
        #expect(config.msaaSampleCount == 1)
        #expect(config.enableSilhouettes == false)
    }

    @Test("Default (.cad) keeps the quality passes on")
    func cadKeepsQualityOn() {
        let config = ViewportConfiguration.cad
        #expect(config.msaaSampleCount > 1)
        #expect(config.enableSilhouettes == true)
    }

    @Test("cadHighQuality enables adaptive GPU tessellation for smooth curves (#48)")
    func cadHighQualityEnablesTessellation() {
        let config = ViewportConfiguration.cadHighQuality
        #expect(config.renderingQuality == .enhanced)
        #expect(config.adaptiveTessellation == true)
        #expect(config.tessellationMaxFactor >= 32)
        // Plain .cad stays on the cheaper standard path (no auto-tessellation).
        #expect(ViewportConfiguration.cad.renderingQuality == .standard)
    }
}
