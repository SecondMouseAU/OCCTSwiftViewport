// SpikeBenchApp — benchmark and test app for two spikes, depending only on OCCTSwiftViewport
// (no OCCT, so it builds in seconds), on macOS and iOS.
//
//   #141 transforms   Issue #141: what does it cost to move a body every frame, by changing
//                     `ViewportBody.transform` and re-assigning the bodies array the view reads?
//                     Files: Bench141*.swift.
//   #139 heightfield  Issue #139 spike: a 2000 x 2000 field you can orbit, edit and pick.
//                     Files: BenchHeightfield*.swift.
//   Shared            BenchReport.swift (results table: stdout + in-app + Copy), BenchSupport.swift.
//
// IMPORTANT: build RELEASE for any number you will quote. A debug build is 10x slower on the CPU,
// which also idles the GPU between frames and lowers its clock (issue #238). The app says so on
// screen and in the report when it was built with DEBUG.
//
// RUN IT (macOS)
//   xcodegen --spec project-bench.yml          # writes SpikeBench.xcodeproj (untracked)
//   xcodebuild -project SpikeBench.xcodeproj -scheme SpikeBench_macOS -configuration Release \
//       -derivedDataPath build/SpikeBench build
//   open build/SpikeBench/Build/Products/Release/SpikeBench.app
// Pick a tab at the top. "#141 transforms": choose how the bodies change and press Start 60 Hz.
// "#139 heightfield": drag to orbit, click or tap the field to see the pick payload, change the
// controls. "Run table" on either tab runs that tab's whole benchmark and fills "Results" (Copy,
// and Close or Escape to dismiss it). "Cancel" (or Command-.) stops a run.
//
// FOR A TRUSTWORTHY #141 RUN keep the SpikeBench window frontmost and uncovered, and run only one
// copy of the app. The system does not draw a hidden, minimised or fully covered window, so the
// run would measure nothing: the app notices and stops with a message instead of a blank table.
// Each table ends with a line saying whether the window stayed visible and whether another copy
// was running. The #139 table renders off-screen and does not depend on the window.
//
// RUN IT HEADLESS (prints the whole table to stdout, then exits)
//   build/SpikeBench/Build/Products/Release/SpikeBench.app/Contents/MacOS/SpikeBench --auto
//   options: --only141  --only139  --quick (fewer frames, for a smoke test)
//            --tab139 (open on the #139 tab)  --log-live (GUI: print the live readout to stdout)
//            --size 1668x1194 (off-screen render size of the #139 runs; default 1668x1194 on
//            macOS, the screen's native pixels on iOS)  --frames 150  --warmup 30
//            --ignore-other-instances (run although another copy is open; the table says so)
//            test hooks: --press-run-table  --exit-when-done  --hide-window
// Every row is also one greppable line: `... | grep '^BENCH 139.gpu '`.
//
// DEPLOY TO AN iPHONE OR iPAD (unlock it and keep it awake; list ids with `xcrun devicectl list devices`)
//   xcodebuild -project SpikeBench.xcodeproj -scheme SpikeBench_iOS -configuration Release \
//       -destination 'generic/platform=iOS' -derivedDataPath build/SpikeBench \
//       -allowProvisioningUpdates build
//   xcrun devicectl device install app --device <id> \
//       build/SpikeBench/Build/Products/Release-iphoneos/SpikeBench.app
//   xcrun devicectl device process launch --console --terminate-existing --device <id> \
//       com.occtswift.spike-bench --auto
// `--console` streams the app's stdout, so the table arrives in the terminal. Without `--auto`
// the same launch opens the GUI.
//
// HOW FRAMES ARE MEASURED
//   #141: a 60 Hz display link changes the bodies; the main thread's CPU time is totalled across
//         the run-loop turns of each frame (SwiftUI update, draw callback, commit), next to the
//         renderer's own encode time. The "static" rows are the same scene left alone.
//   #139 table: frames are rendered off-screen through the live renderer's draw path, queued
//         back to back (three in flight, no sleeps), so the GPU clock stays up. The live readouts
//         on the #139 tab are display-paced instead, and read high on GPU time.

import Metal
import OCCTSwiftViewport
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// MARK: - Launch options

struct LaunchOptions {
    var auto = false
    var only141 = false
    var only139 = false
    var quick = false
    var tab139 = false
    var logLive = false
    /// Test hooks: press "Run table" on launch, quit when it ends, keep the window hidden.
    var pressRun = false
    var exitWhenDone = false
    var hideWindow = false
    var ignoreOtherInstances = false
    var size: (width: Int, height: Int)?
    var frames: Int?
    var warmup: Int?

    init(arguments: [String] = CommandLine.arguments) {
        var it = arguments.dropFirst().makeIterator()
        while let argument = it.next() {
            switch argument {
            case "--auto": auto = true
            case "--only141": only141 = true
            case "--only139": only139 = true
            case "--quick": quick = true
            case "--tab139": tab139 = true
            case "--log-live": logLive = true
            case "--press-run-table": pressRun = true
            case "--exit-when-done": exitWhenDone = true
            case "--hide-window": hideWindow = true
            case "--ignore-other-instances": ignoreOtherInstances = true
            case "--frames": frames = it.next().flatMap(Int.init)
            case "--warmup": warmup = it.next().flatMap(Int.init)
            case "--size":
                let parts = (it.next() ?? "").split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { size = (parts[0], parts[1]) }
            default: break
            }
        }
    }

    static let current = LaunchOptions()
}

// MARK: - App

@main
struct SpikeBenchApp: App {
    init() {
        // Line-buffered stdout so `devicectl --console` and pipes see each row as it is produced.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// MARK: - Root

struct RootView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transforms = "#141 transforms"
        case heightfield = "#139 heightfield"
        var id: String { rawValue }
    }

    @State private var tab: Tab = LaunchOptions.current.tab139 ? .heightfield : .transforms
    @State private var busy = false
    @State private var showResults = false
    @State private var progress = ""
    @State private var runTask: Task<Void, Never>?
    // Held in @State, not @StateObject: this view must not observe the models, or every body
    // change the #141 benchmark makes would re-evaluate the whole window around the viewport.
    @State private var report = BenchReport()
    @State private var models = Models()

    private let launch = LaunchOptions.current

    @MainActor
    final class Models {
        let m141 = Bench141Model()
        private var field: BenchHeightfieldModel?
        /// Built on first use: it holds a 2000 x 2000 field, which `--auto` on the #141 side
        /// has no need of.
        var m139: BenchHeightfieldModel {
            if let field { return field }
            let made = BenchHeightfieldModel()
            field = made
            return made
        }
        var existing139: BenchHeightfieldModel? { field }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Benchmark", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(busy)
            .padding(8)

            HStack {
                Text(BuildStamp.value)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Button("Cancel", role: .destructive) { cancelRun() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Run table") { startRun() }
                }
                Button("Results") { showResults = true }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            ZStack {
                switch tab {
                case .transforms:
                    Bench141View(model: models.m141)
                case .heightfield:
                    if busy {
                        VStack(spacing: 12) {
                            Text("Running the #139 table off-screen").font(.headline)
                            Text(progress).font(.system(.caption, design: .monospaced))
                            Text("The live view is hidden so it does not compete for the GPU.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        BenchHeightfieldView(model: models.m139)
                    }
                }
            }
        }
        .sheet(isPresented: $showResults) {
            BenchReportView(report: report, busy: busy, status: progress, onCancel: cancelRun)
                #if os(macOS)
                    .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        .onAppear { if tab == .heightfield && !busy { models.m139.startTicking() } }
        .onChange(of: tab) { _, new in
            if new == .heightfield {
                if !busy { models.m139.startTicking() }
            } else {
                models.existing139?.stopTicking()
            }
            if new != .transforms { models.m141.stopTicking() }
        }
        .task {
            #if os(macOS)
                if launch.hideWindow {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    for window in NSApp.windows { window.orderOut(nil) }
                }
            #endif
            if launch.auto {
                await runAuto()
            } else if launch.pressRun {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                startRun()
            }
        }
    }

    // MARK: Running

    private func describeEnvironment() {
        #if DEBUG
            let config = "DEBUG (NOT REPRESENTATIVE: build Release)"
        #else
            let config = "RELEASE"
        #endif
        let info = ProcessInfo.processInfo
        report.environment([
            ("app", "SpikeBench"), ("build", BuildStamp.value), ("config", config),
        ])
        report.environment([
            ("machine", Self.hardwareIdentifier()),
            ("gpu", MTLCreateSystemDefaultDevice()?.name ?? "none"),
            ("os", info.operatingSystemVersionString),
            ("cores", "\(info.activeProcessorCount)"),
            ("thermal", "\(info.thermalState.rawValue) (0 nominal, 1 fair, 2 serious, 3 critical)"),
            ("lowPower", "\(info.isLowPowerModeEnabled)"),
            ("loadavg", Self.loadAverage()),
        ])
        let window = RunEnvironment.visibility()
        report.environment([
            ("screenLocked", "\(RunEnvironment.screenLocked())"),
            ("windowBeforeRun", "visible=\(window.visible) key=\(window.key)"),
            ("otherInstances", "\(RunEnvironment.otherInstances().count)"),
        ])
    }

    /// The 1, 5 and 15 minute load averages: a busy machine makes GPU and CPU figures noisy.
    private static func loadAverage() -> String {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 3 else { return "?" }
        return load.map { String(format: "%.1f", $0) }.joined(separator: "/")
    }

    private static func hardwareIdentifier() -> String {
        #if os(macOS)
            let key = "hw.model"
        #else
            let key = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &bytes, &size, nil, 0)
        return String(
            decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func offscreenSize() -> (Int, Int) {
        if let size = launch.size { return (size.width, size.height) }
        #if os(iOS)
            let native = UIScreen.main.nativeBounds
            return (Int(max(native.width, native.height)), Int(min(native.width, native.height)))
        #else
            return (1668, 1194)
        #endif
    }

    private func run141() async {
        tab = .transforms
        let quick = launch.quick
        await models.m141.runCases(
            report: report, warmup: launch.warmup ?? (quick ? 20 : 60),
            frames: launch.frames ?? (quick ? 60 : 240)
        ) { progress = $0 }
    }

    private func run139() async {
        busy = true
        models.existing139?.stopTicking()
        tab = .heightfield
        // Let SwiftUI tear the live viewport down before the off-screen runs start.
        try? await Task.sleep(nanoseconds: 300_000_000)
        var options = BenchHeightfieldRunner.Options()
        let size = offscreenSize()
        options.width = size.0
        options.height = size.1
        options.warmup = launch.warmup ?? (launch.quick ? 8 : 30)
        options.frames = launch.frames ?? (launch.quick ? 20 : 150)
        let runner = BenchHeightfieldRunner(options: options)
        report.note(
            "#139 off-screen size \(options.width)x\(options.height), \(options.frames) frames after \(options.warmup) warm-up, median per row")
        await runner.runAll(report: report) { progress = $0 }
        if tab == .heightfield, !launch.auto, !RunControl.shared.cancelled {
            models.m139.startTicking()
        }
    }

    /// Why a run must not start, or `nil`: a second copy of the app on the same Mac shares the
    /// GPU and the CPU and spoils every number in both.
    private func reasonNotToStart() -> String? {
        let others = RunEnvironment.otherInstances()
        guard !others.isEmpty, !launch.ignoreOtherInstances else { return nil }
        return
            "another SpikeBench is already running (pid \(others.map(String.init).joined(separator: ", "))). "
            + "Two copies share the GPU and every figure from either is wrong. Quit the other copy and run again."
    }

    private func startRun() {
        guard runTask == nil else { return }
        runTask = Task {
            await runTable()
            runTask = nil
        }
    }

    private func cancelRun() {
        RunControl.shared.cancel()
        runTask?.cancel()
        progress = "cancelling..."
    }

    /// The Run table button: the current tab's benchmark.
    private func runTable() async {
        report.reset()
        describeEnvironment()
        if let reason = reasonNotToStart() {
            report.note("NOT STARTED: \(reason)")
            report.printTables()
            showResults = true
            return
        }
        RunControl.shared.reset()
        RunEnvironment.begin()
        busy = true
        switch tab {
        case .transforms:
            await run141()
        case .heightfield:
            await run139()
        }
        busy = false
        RunEnvironment.end()
        if RunControl.shared.cancelled { report.note("Run cancelled: the tables hold what finished.") }
        if !report.hasRows {
            report.note(
                "NO RESULTS COLLECTED. The notes above say why; no benchmark window produced a row.")
        }
        report.printTables()
        showResults = true
        if launch.exitWhenDone { exit(0) }
    }

    /// Runs `--auto` once per process, however many windows the system opens (a second launch
    /// of the same bundle can make the app open another window, whose view would start a second,
    /// interleaved run).
    @MainActor private static var autoStarted = false

    /// `--auto`: everything, then print and exit.
    private func runAuto() async {
        guard !Self.autoStarted else { return }
        Self.autoStarted = true
        report.reset()
        describeEnvironment()
        if let reason = reasonNotToStart() {
            report.note("NOT STARTED: \(reason)")
            report.printTables()
            exit(2)
        }
        RunControl.shared.reset()
        RunEnvironment.begin()
        report.note("mode --auto: \(launch.quick ? "quick, " : "")tables follow")
        if !launch.only139 { await run141() }
        if !launch.only141 { await run139() }
        busy = false
        RunEnvironment.end()
        if !report.hasRows { report.note("NO RESULTS COLLECTED. The notes above say why.") }
        report.printTables()
        let path = NSTemporaryDirectory() + "spike-bench-report.txt"
        try? report.text.write(toFile: path, atomically: true, encoding: .utf8)
        print("BENCH-NOTE report also written to \(path)")
        fflush(stdout)
        exit(report.hasRows ? 0 : 1)
    }
}
