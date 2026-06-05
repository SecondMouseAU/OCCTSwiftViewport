import Testing
@testable import OCCTSwiftViewport

#if canImport(AppKit)
import AppKit
#endif

@Suite("Input abstraction")
struct InputAbstractionTests {

    // MARK: - ViewportModifierKeys

    @Test("OptionSet membership is independent per modifier")
    func optionSetMembership() {
        let combo: ViewportModifierKeys = [.command, .shift]
        #expect(combo.contains(.command))
        #expect(combo.contains(.shift))
        #expect(!combo.contains(.option))
        #expect(!combo.contains(.control))
        #expect(ViewportModifierKeys().isEmpty)
    }

    // MARK: - dragAction priority

    @Test("Default config: unmodified=orbit, shift=pan, option=zoom, command=select")
    func defaultMapping() {
        let gc = GestureConfiguration.default
        #expect(gc.dragAction(for: []) == .orbit)
        #expect(gc.dragAction(for: .shift) == .pan)
        #expect(gc.dragAction(for: .option) == .zoom)
        #expect(gc.dragAction(for: .command) == .select)
    }

    @Test("Command wins over shift wins over option (historical priority)")
    func priorityOrder() {
        let gc = GestureConfiguration.default
        // command beats everything
        #expect(gc.dragAction(for: [.command, .shift, .option]) == gc.commandDrag)
        // shift beats option when no command
        #expect(gc.dragAction(for: [.shift, .option]) == gc.shiftDrag)
        // option only when alone
        #expect(gc.dragAction(for: .option) == gc.optionDrag)
    }

    @Test("Control alone falls through to the unmodified action")
    func controlFallsThrough() {
        let gc = GestureConfiguration.default
        #expect(gc.dragAction(for: .control) == gc.mouseDrag)
    }

    @Test("Blender and Fusion360 presets resolve through the same seam")
    func presetMappings() {
        let blender = GestureConfiguration.blender
        #expect(blender.dragAction(for: []) == .select)
        #expect(blender.dragAction(for: .option) == .orbit)

        let fusion = GestureConfiguration.fusion360
        #expect(fusion.dragAction(for: .shift) == .orbit)
        #expect(fusion.dragAction(for: .command) == .zoom)
    }

    // MARK: - Platform bridge

    #if canImport(AppKit)
    @Test("AppKit modifier flags bridge into ViewportModifierKeys")
    func appKitBridge() {
        #expect(ViewportModifierKeys(NSEvent.ModifierFlags.command).contains(.command))
        #expect(ViewportModifierKeys(NSEvent.ModifierFlags([.shift, .option])) == [.shift, .option])
        #expect(ViewportModifierKeys(NSEvent.ModifierFlags()).isEmpty)
    }

    @Test("Bridged flags resolve identically to native modifiers")
    func bridgeResolvesSameAction() {
        let gc = GestureConfiguration.default
        let bridged = ViewportModifierKeys(NSEvent.ModifierFlags.shift)
        #expect(gc.dragAction(for: bridged) == gc.shiftDrag)
    }
    #endif
}
