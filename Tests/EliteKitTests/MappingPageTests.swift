import XCTest
@testable import EliteKit

/// Expected bytes come from the layout in docs/protocol.md: input byte n
/// (1-18) holds a code or a HID usage, its keyboard flag is bit 14 + (n - 1)
/// of the u32 LE at 52-55, and its modifiers are the nibble at
/// 19 + (n - 1) / 2, low for the first input of the pair.
final class MappingPageTests: XCTestCase {
    func testKeyboardTriggerCaptureIsRTToFWithNoModifiers() {
        let page = MappingPage(Captured.rightTriggerF)
        XCTAssertEqual(page.assignments, [.rightTrigger: .key(KeyCombination(KeyboardKey(usage: 0x09)))])
        XCTAssertEqual(page.bytes, Captured.rightTriggerF)
    }

    func testKeysWithModifiersOnPaddlesAndButtons() {
        var expected = Captured.restoredDefault
        expected[1] = 0x04 // P1: A
        expected[2] = 0x2C // P2: Space
        expected[5] = 0x28 // A: Return
        expected[6] = 0x29 // B: Escape
        expected[19] = 0x43 // P1 Ctrl+Shift in the low nibble, P2 Alt in the high
        expected[21] = 0x80 // A none in the low nibble, B Win in the high
        expected[53] = 0xC0 // bits 14 (P1) and 15 (P2)
        expected[54] = 0x0C // bits 18 (A) and 19 (B)

        var page = MappingPage(Captured.restoredDefault)
        page.assignments = [
            .paddleUpperRight: .key(KeyCombination(KeyboardKey(usage: 0x04), modifiers: [.control, .shift])),
            .paddleLowerRight: .key(KeyCombination(KeyboardKey(usage: 0x2C), modifiers: .alt)),
            .a: .key(KeyCombination(KeyboardKey(usage: 0x28))),
            .b: .key(KeyCombination(KeyboardKey(usage: 0x29), modifiers: .windows)),
        ]
        XCTAssertEqual(page.bytes, expected)
        XCTAssertEqual(MappingPage(expected).assignments, page.assignments)
    }

    func testKeysWithModifiersOnBothTriggers() {
        var expected = Captured.restoredDefault
        expected[17] = 0x2C // LT: Space
        expected[18] = 0x09 // RT: F
        expected[27] = 0x21 // LT Ctrl in the low nibble, RT Shift in the high
        expected[55] = 0xC0 // bits 30 (LT) and 31 (RT)

        var page = MappingPage(Captured.restoredDefault)
        page.assignments = [
            .leftTrigger: .key(KeyCombination(KeyboardKey(usage: 0x2C), modifiers: .control)),
            .rightTrigger: .key(KeyCombination(KeyboardKey(usage: 0x09), modifiers: .shift)),
        ]
        XCTAssertEqual(page.bytes, expected)
        XCTAssertEqual(MappingPage(expected).assignments, page.assignments)
    }

    func testClearingAKeyKeepsTheFlagBitsTheElite2DoesntUse() {
        var base = Captured.restoredDefault
        base[1] = 0x04
        base[19] = 0x53 // P1 Ctrl+Shift, and a nibble for P2, which isn't a key; the app writes 0 there
        base[52] = 0x3E // bits 1-5, the Adaptive Controller's mouse settings
        base[53] = 0x7F // bits 8-13 and P1's flag
        var page = MappingPage(base)
        XCTAssertEqual(page.assignments[.paddleUpperRight], .key(KeyCombination(KeyboardKey(usage: 0x04), modifiers: [.control, .shift])))
        page.assignments[.paddleUpperRight] = nil

        var expected = base
        expected[1] = 0x05 // the paddle's default, B
        expected[19] = 0x00
        expected[53] = 0x3F
        XCTAssertEqual(page.bytes, expected)
    }

    func testTriggersAsTargetsAndAsInputs() {
        var expected = Captured.restoredDefault
        expected[5] = 0x10 // A gives LT
        expected[14] = 0x11 // RB gives RT
        expected[17] = 0x04 // LT gives A
        var page = MappingPage(Captured.restoredDefault)
        page.assignments = [.a: .button(.leftTrigger), .rightBumper: .button(.rightTrigger), .leftTrigger: .button(.a)]
        XCTAssertEqual(page.bytes, expected)
        XCTAssertEqual(MappingPage(expected).assignments, page.assignments)

        XCTAssertEqual(RemappableControl.a.targets, GamepadButton.allCases)
        XCTAssertEqual(GamepadButton.allCases.count, 14)
        for trigger in RemappableControl.triggers {
            XCTAssertEqual(trigger.targets.count, 12, "a trigger gets the other trigger only by swapping them")
            XCTAssertFalse(trigger.targets.contains(.leftTrigger) || trigger.targets.contains(.rightTrigger))
        }
    }

    func testOutputsTheAppDoesntOfferAreKept() {
        var bytes = Captured.restoredDefault
        bytes[3] = 0x1A // P3 gives the P1 paddle
        bytes[7] = 0x12 // X gives left stick up
        bytes[9] = 0x02 // D-pad up gives Menu
        let page = MappingPage(bytes)
        XCTAssertEqual(page.assignments, [.paddleUpperLeft: .code(0x1A), .x: .code(0x12), .dpadUp: .code(0x02)])
        XCTAssertEqual(page.bytes, bytes)
    }

    func testSwapTriggersIsBit0WithBytes17And18AtZero() throws {
        // Swapping replaces RT's key from the keyboard capture: the bytes,
        // RT's flag and its modifier nibble all go to 0.
        var base = Captured.rightTriggerF
        base[27] = 0x20
        var expected = Captured.restoredDefault
        expected[52] = 0x01

        var profile = try ProfileCodec.decode(Captured.slot(normal: base, shift: Captured.restoredDefault), name: "x")
        XCTAssertFalse(profile.swapsTriggers)
        profile.swapsTriggers = true
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual(pages.normalMapping, expected)
        XCTAssertEqual(pages.shiftMapping, expected)

        let decoded = try ProfileCodec.decode(pages, name: "x")
        XCTAssertTrue(decoded.swapsTriggers)
        XCTAssertEqual(decoded.buttons, Assignment.swappedTriggers)

        profile.swapsTriggers = false
        XCTAssertTrue(profile.buttons.isEmpty && profile.shiftButtons.isEmpty)
        XCTAssertEqual(ProfileCodec.encode(profile, format: .v1_1).normalMapping, Captured.restoredDefault)
    }

    func testATriggerOnlyGetsTheOtherTriggerBySwapping() {
        var profile = EliteProfile.factoryDefault()
        profile.setAssignment(.button(.rightTrigger), for: .leftTrigger, shift: false)
        XCTAssertTrue(profile.swapsTriggers(shift: false))
        XCTAssertFalse(profile.swapsTriggers(shift: true), "only the layer it was set in")
        XCTAssertFalse(profile.swapsTriggers)

        // Remapping either trigger ends the swap; the other goes back to its default.
        profile.setAssignment(.button(.a), for: .rightTrigger, shift: false)
        XCTAssertEqual(profile.buttons, [.rightTrigger: .button(.a)])

        // Mapped to each other in one layer, the page holds the flag, not codes 0x10 and 0x11.
        profile.setAssignment(.button(.leftTrigger), for: .rightTrigger, shift: true)
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual([pages.shiftMapping[17], pages.shiftMapping[18], pages.shiftMapping[52]], [0, 0, 0x01])
        XCTAssertEqual([pages.normalMapping[17], pages.normalMapping[18], pages.normalMapping[52]], [0, 0x04, 0])
    }

    func testSwapSticksSetsBothSwapBitsInBothLayers() throws {
        // Right stick inverted (bit 1) from the capture; swap adds bits 2 and 3.
        let base = Captured.slot(normal: Captured.restoredDefault, curves: Captured.rightStickInverted)
        var profile = try ProfileCodec.decode(base, name: "x")
        XCTAssertFalse(profile.swapSticks)
        profile.swapSticks = true
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        var expected = Captured.rightStickInverted
        expected[27] = 0x0E
        XCTAssertEqual(pages.normalCurves, expected)
        var expectedShift = CurvesLayout.defaultPage
        expectedShift[27] = 0x0C
        XCTAssertEqual(pages.shiftCurves, expectedShift)
        XCTAssertTrue(try ProfileCodec.decode(pages, name: "x").swapSticks)
        XCTAssertEqual(pages.normalMapping, Captured.restoredDefault)

        // A page with only the X axes swapped keeps that until the setting changes.
        var xOnly = CurvesLayout.defaultPage
        xOnly[27] = 0x04
        var partial = try ProfileCodec.decode(SlotPages(normalMapping: Captured.restoredDefault, normalCurves: xOnly, shiftMapping: Captured.restoredDefault, shiftCurves: xOnly), name: "x")
        XCTAssertFalse(partial.swapSticks)
        partial.setAssignment(.button(.b), for: .a, shift: false)
        XCTAssertEqual(ProfileCodec.encode(partial, format: .v1_1).normalCurves[27], 0x04)
        partial.swapSticks = true
        XCTAssertEqual(ProfileCodec.encode(partial, format: .v1_1).normalCurves[27], 0x0C)
    }

    func testStickyInputsUseCurvesBytes28And29PerLayer() throws {
        // Bit n - 1 for input byte n: P1 bit 0 and Y bit 7 in byte 28,
        // D-pad up bit 0 and RS bit 7 in byte 29; B is bit 5 of byte 28.
        var profile = EliteProfile.factoryDefault()
        for control in [RemappableControl.paddleUpperRight, .y, .dpadUp, .rightStick] {
            profile.setSticky(true, for: control, shift: false)
        }
        profile.setSticky(true, for: .b, shift: true)
        profile.setSticky(true, for: .leftTrigger, shift: false)
        profile.setSticky(true, for: .rightTrigger, shift: true)
        XCTAssertFalse(profile.isSticky(.leftTrigger, shift: false), "the firmware ignores the trigger bits")

        let pages = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual(Array(pages.normalCurves[28...30]), [0x81, 0x81, 0x00])
        XCTAssertEqual(Array(pages.shiftCurves[28...30]), [0x20, 0x00, 0x00])
        let decoded = try ProfileCodec.decode(pages, name: "x")
        XCTAssertEqual(decoded.stickyButtons, [.paddleUpperRight, .y, .dpadUp, .rightStick])
        XCTAssertEqual(decoded.shiftStickyButtons, [.b])
        XCTAssertFalse(decoded.hasDefaultSettings)
    }

    func testStickyKeepsTheTriggerBitsAndTheRestOfByte30() throws {
        var curves = CurvesLayout.defaultPage
        curves[30] = 0xFF
        var profile = try ProfileCodec.decode(SlotPages(normalMapping: Captured.restoredDefault, normalCurves: curves, shiftMapping: Captured.restoredDefault, shiftCurves: curves), name: "x")
        XCTAssertTrue(profile.stickyButtons.isEmpty)
        profile.setSticky(true, for: .a, shift: false)
        var expected = curves
        expected[28] = 0x10 // A is input byte 5
        XCTAssertEqual(ProfileCodec.encode(profile, format: .v1_1).normalCurves, expected)
        XCTAssertEqual(ProfileCodec.encode(profile, format: .v1_1).shiftCurves, curves)
    }

    func testStickyNeedsFormat1_1() throws {
        var profile = EliteProfile.factoryDefault()
        profile.setSticky(true, for: .x, shift: false)
        let older = ProfileCodec.encode(profile, format: .v1_0)
        XCTAssertEqual(older.normalCurves.count, 28)
        XCTAssertTrue(try ProfileCodec.decode(older, name: "x").stickyButtons.isEmpty)

        // A slot read as 1.0 and saved for 1.1 firmware gets the bits once the page has room.
        var fromOlder = try ProfileCodec.decode(older, name: "x")
        fromOlder.setSticky(true, for: .x, shift: false)
        XCTAssertEqual(Array(ProfileCodec.encode(fromOlder, format: .v1_1).normalCurves[28...30]), [0x40, 0, 0])
    }
}
