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
}
