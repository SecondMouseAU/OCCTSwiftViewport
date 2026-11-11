// BenchSupport.swift
// Small shared helpers: statistics, a frame ticker, and a main-thread CPU meter.

import Foundation
import QuartzCore

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// MARK: - Statistics

enum Stats {
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

/// Formats a millisecond value for a table cell.
func ms(_ value: Double) -> String { String(format: "%.2f", value) }

// MARK: - Frame ticker

/// Calls `handler` once per display refresh on the main run loop, at a fixed rate.
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var handler: (@MainActor () -> Void)?

    var isRunning: Bool { link != nil }

    func start(framesPerSecond: Int, handler: @escaping @MainActor () -> Void) {
        stop()
        self.handler = handler
        #if os(macOS)
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let link = screen.displayLink(target: self, selector: #selector(tick))
        #else
            let link = CADisplayLink(target: self, selector: #selector(tick))
        #endif
        let rate = Float(framesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        handler = nil
    }

    @objc private func tick() { handler?() }
}

// MARK: - Main-thread CPU meter

/// Accumulates the CPU time the main thread spends awake, from run-loop observers around each
/// turn of the main run loop. Everything the main thread does between two instants counts:
/// event handling, the SwiftUI update, the renderer's draw callback, Core Animation's commit.
///
/// Thread CPU time (not wall-clock), so being pre-empted or waiting on a lock does not count.
@MainActor
final class MainThreadMeter {
    private final class State: @unchecked Sendable {
        var accumulated: UInt64 = 0
        var turnStart: UInt64 = 0
        var inTurn = false
    }

    private let state = State()
    private var observers: [CFRunLoopObserver] = []

    nonisolated static func threadCPUNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    init() {
        let state = state
        // Wake: first in line. Sleep: after Core Animation's commit observer (order 2,000,000).
        let wake = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int(Int32.min)
        ) { _, _ in
            state.turnStart = MainThreadMeter.threadCPUNanos()
            state.inTurn = true
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000
        ) { _, _ in
            if state.inTurn {
                state.accumulated &+= MainThreadMeter.threadCPUNanos() &- state.turnStart
                state.inTurn = false
            }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    /// Main-thread CPU nanoseconds so far, including the turn in progress.
    func totalNanos() -> UInt64 {
        state.accumulated &+ (state.inTurn ? Self.threadCPUNanos() &- state.turnStart : 0)
    }
}

// MARK: - Run control

/// Cancellation shared by the benchmarks. Cancel buttons set it; every wait loop and frame loop
/// looks at it, so a run can always be stopped.
@MainActor
final class RunControl {
    static let shared = RunControl()
    private(set) var cancelled = false

    func cancel() { cancelled = true }
    func reset() { cancelled = false }
}

// MARK: - Run environment

/// What a run needs from the app around it: to be awake, frontmost and visible, and to be the
/// only copy running.
@MainActor
enum RunEnvironment {
    private static var activity: NSObjectProtocol?

    /// Called when a run starts: stops App Nap and idle sleep, and brings the window forward.
    static func begin() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "SpikeBench benchmark run")
        }
        #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
        #endif
        bringToFront()
    }

    static func end() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    #if os(macOS)
        static var mainWindow: NSWindow? {
            NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
        }
    #endif

    static func bringToFront() {
        #if os(macOS)
            if LaunchOptions.current.hideWindow { return }  // test hook: keep the window hidden
            NSApp.activate(ignoringOtherApps: true)
            if let window = mainWindow {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        #endif
    }

    /// Whether the login session's screen is locked. A locked Mac draws no windows at all, so a
    /// viewport on it gets no frames (the cause of an empty #141 table).
    static func screenLocked() -> Bool {
        #if os(macOS)
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
                return false
            }
            return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        #else
            return false
        #endif
    }

    /// Whether the window is at least partly on screen (so the system keeps drawing it) and
    /// whether it is the key window of the active app.
    static func visibility() -> (visible: Bool, key: Bool) {
        #if os(macOS)
            guard let window = mainWindow, !screenLocked() else { return (false, false) }
            let visible =
                window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            return (visible, window.isKeyWindow && NSApp.isActive)
        #else
            let active = UIApplication.shared.applicationState == .active
            return (active, active)
        #endif
    }

    /// Process ids of other running copies of this app. Two copies share the GPU and the CPU, and
    /// every figure from either is contaminated.
    static func otherInstances() -> [Int32] {
        #if os(macOS)
            guard let identifier = Bundle.main.bundleIdentifier else { return [] }
            let mine = ProcessInfo.processInfo.processIdentifier
            return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .map(\.processIdentifier).filter { $0 != mine }
        #else
            return []
        #endif
    }
}

/// Counts, over the ticks of a measured window, how often the window was hidden or not key.
@MainActor
final class VisibilityLog {
    private var samples = 0
    private var hidden = 0
    private var notKey = 0

    func reset() {
        samples = 0
        hidden = 0
        notKey = 0
    }

    func sample() {
        let state = RunEnvironment.visibility()
        samples += 1
        if !state.visible { hidden += 1 }
        if !state.key { notKey += 1 }
    }

    /// One line for a table footer.
    var summary: String {
        guard samples > 0 else { return "window state: not sampled" }
        if hidden == 0, notKey == 0 {
            return "window visible and key for all \(samples) measured frames: yes"
        }
        return
            "window visible and key for all \(samples) measured frames: NO (hidden on \(hidden), not key on \(notKey)). "
            + "Treat this run as suspect."
    }
}
