// BenchHeightfieldModel.swift
// The #139 tab's state: a 2000 x 2000 field in a live MetalViewportView, the controls that change
// how it is drawn and edited, and live readouts of what the frames cost.
//
// The readouts come from the library's Bench hook and describe the frames the on-screen view
// really draws, paced by the display (60 Hz here). A paced GPU idles between frames and clocks
// down, so GPU time on screen runs high against the back-to-back "Run table" figures. Use the
// table for numbers; use this view to look at the surface, edit it and pick it.

import Combine
import OCCTSwiftViewport
import SwiftUI

@_spi(Bench) import OCCTSwiftViewport

@MainActor
final class BenchHeightfieldModel: ObservableObject {

    struct Settings: Equatable {
        var msaa = 4
        var shadows = false
        var ssao = false
        var silhouettes = false
        var float16 = false
        var rampPainted = false
        var picking = true
        var targetPixels: Float = 4
        var editsPerFrame = 0
        var pattern = BenchHeightfieldScene.EditPattern.sliding
        var autoOrbit = false
    }

    struct Readout {
        var encodeMs = 0.0
        var gpuMs = 0.0
        var uploadKB = 0.0
        var tiles = 0
        var drawCalls = 0
        var replaceMs = 0.0
        var framesPerSecond = 0.0
    }

    @Published var settings = Settings() {
        didSet { if oldValue != settings { settingsChanged(from: oldValue) } }
    }
    @Published var bodies: [ViewportBody] = []
    @Published private(set) var controller: ViewportController
    /// Changes whenever the viewport has to be rebuilt (MSAA, silhouettes, precision, picking).
    @Published private(set) var viewID = 0
    @Published private(set) var readout = Readout()
    @Published private(set) var pickText = "Click or tap the field to pick a cell"

    private static let heights = BenchHeightfieldScene.terrainHeights()
    private var field: Heightfield
    private var editLoad: BenchHeightfieldScene.EditLoad?
    private let ticker = FrameTicker()
    private var pickSubscription: AnyCancellable?
    private var ticks = 0
    private var replaceTotal = 0.0
    private var replaceCount = 0
    private var lastReadout = DispatchTime.now().uptimeNanoseconds

    init() {
        let settings = Settings()
        field = BenchHeightfieldScene.makeField(
            heights: Self.heights, float16: settings.float16, rampPainted: settings.rampPainted,
            tracksIDs: true)
        controller = ViewportController(configuration: ViewportConfiguration())
        rebuild(camera: nil)
    }

    var renderer: ViewportRenderer? { controller.benchRenderer }

    // MARK: Lifecycle

    func startTicking() {
        guard !ticker.isRunning else { return }
        ticker.start(framesPerSecond: 60) { [weak self] in self?.tick() }
    }

    func stopTicking() { ticker.stop() }

    // MARK: Settings

    private func settingsChanged(from old: Settings) {
        let new = settings
        if old.msaa != new.msaa || old.silhouettes != new.silhouettes
            || old.float16 != new.float16 || old.rampPainted != new.rampPainted
            || old.picking != new.picking
        {
            rebuild(camera: controller.cameraState)
            return
        }
        if old.shadows != new.shadows || old.ssao != new.ssao {
            var lighting = controller.lightingConfiguration
            lighting.shadowsEnabled = new.shadows
            lighting.enableSSAO = new.ssao
            controller.lightingConfiguration = lighting
        }
        if old.editsPerFrame != new.editsPerFrame || old.pattern != new.pattern {
            rebuildEditLoad()
        }
    }

    /// A new field, controller and viewport for the current settings, keeping `camera`.
    private func rebuild(camera: CameraState?) {
        let s = settings
        field = BenchHeightfieldScene.makeField(
            heights: Self.heights, float16: s.float16, rampPainted: s.rampPainted, tracksIDs: true)
        bodies = [BenchHeightfieldScene.body(field)]

        var config = ViewportConfiguration()
        config.preferredFramesPerSecond = 60
        config.msaaSampleCount = s.msaa
        config.enableSilhouettes = s.silhouettes
        config.pickingConfiguration = PickingConfiguration(isEnabled: s.picking)
        config.initialCameraState = camera ?? BenchHeightfieldScene.orbitCamera(frame: 0)
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = s.shadows
        lighting.enableSSAO = s.ssao
        config.lightingConfiguration = lighting
        let fresh = ViewportController(configuration: config)
        fresh.showGrid = false
        fresh.showAxes = false
        fresh.enableTAA = false
        controller = fresh
        viewID += 1
        pickSubscription = fresh.$pickResult.sink { [weak self] result in
            self?.pickText = Self.describe(result)
        }
        pickText = "Click or tap the field to pick a cell"
        rebuildEditLoad()
    }

    private func rebuildEditLoad() {
        editLoad =
            settings.editsPerFrame > 0
            ? BenchHeightfieldScene.EditLoad(
                count: settings.editsPerFrame, pattern: settings.pattern, field: field)
            : nil
    }

    private static func describe(_ result: PickResult?) -> String {
        guard let result else { return "no pick" }
        guard let hit = result.heightfield else {
            return "picked \(result.bodyID), not a field cell"
        }
        return String(
            format: "cell (%d, %d)  index %d  height %.3f  attribute %d  id %@", hit.cell.x,
            hit.cell.y, hit.cellIndex, hit.height, hit.attribute, hit.id.map { "\($0)" } ?? "-")
    }

    // MARK: Per frame

    private func tick() {
        ticks += 1
        if settings.autoOrbit {
            controller.animateTo(BenchHeightfieldScene.orbitCamera(frame: ticks), duration: 0)
        }
        if let renderer {
            renderer.benchHeightfieldTargetPixels = settings.targetPixels
        }
        if let editLoad {
            let start = DispatchTime.now().uptimeNanoseconds
            editLoad.apply(to: field, frame: ticks)
            replaceTotal += Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-6
            replaceCount += 1
        }
        if ticks % 30 == 0 { publishReadout() }
    }

    private func publishReadout() {
        guard let renderer else { return }
        let samples = renderer.benchRestartRecording()
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = Double(now - lastReadout) * 1e-9
        lastReadout = now
        guard !samples.isEmpty else { return }
        var r = Readout()
        r.encodeMs = Stats.median(samples.map { $0.encodeSeconds * 1e3 })
        r.gpuMs = Stats.median(samples.map { $0.gpuSeconds * 1e3 }.filter { $0 > 0 })
        r.uploadKB = Stats.mean(samples.map { Double($0.heightfieldUploadedBytes) }) / 1024
        r.tiles = Int(Stats.median(samples.map { Double($0.heightfieldTilesDrawn) }))
        r.drawCalls = Int(Stats.median(samples.map { Double($0.heightfieldDrawCalls) }))
        r.replaceMs = replaceCount > 0 ? replaceTotal / Double(replaceCount) : 0
        r.framesPerSecond = Double(samples.count) / max(seconds, 1e-3)
        replaceTotal = 0
        replaceCount = 0
        readout = r
        if LaunchOptions.current.logLive {
            print(
                String(
                    format:
                        "BENCH-LIVE 139 | cpu=%.2f gpu=%.2f uploadKB=%.0f tiles=%d draws=%d replace=%.2f fps=%.0f",
                    r.encodeMs, r.gpuMs, r.uploadKB, r.tiles, r.drawCalls, r.replaceMs,
                    r.framesPerSecond))
            fflush(stdout)
        }
    }
}
