import XCTest
@testable import EliteKit

/// Pages captured from the Windows Xbox Accessories app (upstream xbelite2
/// dumps/) and from a real controller over macOS.
enum Captured {
    static func page(_ hex: String) -> [UInt8] { [UInt8](hexString: hex)! }

    static let restoredDefault = page("11 05 07 04 06 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 00 00 00 00 00 00 00 00 00 00 00 64 64 64 64 ff 00 ff 00 00 00 ff 00 ff 00 00 00 64 ff 00 00 00 30 30 00 00 00 00 00")
    /// "remapped right stick to be inverted, and remapped right stick click": Y->A, RS->B, one paddle changed.
    static let rightStickClickToB = page("11 04 06 06 07 04 05 06 04 08 09 0a 0b 0c 0d 0e 05 00 00 00 00 00 00 00 00 00 00 00 64 64 64 64 ff 00 ff 00 00 00 ff 00 ff 00 00 00 64 00 f5 e2 03 30 30 00 00 00 00 00")
    static let rightStickInverted = page("11 2b 2b 7f 7f bf bf 2b 2b 7f 7f bf bf 2b 2b 7f 7f bf bf 2b 2b 7f 7f bf bf 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
    /// "assinged another paddle button as a Shift button".
    static let paddleShiftNormal = page("11 01 06 06 07 04 05 06 04 08 09 0a 0b 0c 0d 0e 0f 00 00 00 00 00 00 00 00 00 00 00 64 64 64 64 ff 00 ff 00 00 00 ff 00 ff 00 00 00 64 00 f5 e2 03 30 30 00 00 00 00 00")
    static let paddleShiftShift = page("11 01 07 04 06 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 00 00 00 00 00 00 00 00 00 00 00 64 64 64 64 ff 00 ff 00 00 00 ff 00 ff 00 00 00 64 00 f5 e2 03 30 30 00 00 00 00 00")
    /// "remapped trigger to the F key on the keyboard".
    static let rightTriggerF = page("11 05 07 04 06 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 00 09 00 00 00 00 00 00 00 00 00 64 64 64 64 ff 00 ff 00 00 00 ff 00 ff 00 00 00 64 ff 00 00 00 30 30 00 00 00 00 80")
    /// "changed controller xbox LED color and set brightness" (also has 67% trigger range).
    static let orangeLight = page("11 05 07 04 06 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 00 00 00 00 00 00 00 00 00 00 00 64 64 64 64 ab 00 ab 00 00 00 ab 00 ab 00 00 00 2d 00 ff 6d 20 1c 15 00 00 00 00 00")
    /// "restored profile to default and then set the triggers to 67 percent".
    static let triggers67 = page("11 05 07 04 06 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 00 00 00 00 00 00 00 00 00 00 00 64 64 64 64 ab 00 ab 00 00 00 ab 00 ab 00 00 00 64 ff 00 00 00 30 30 00 00 00 00 00")
    /// Profile 1 read from the test controller on macOS.
    static let macProfile1 = page("11 0d 07 04 06 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 00 00 00 00 00 00 00 00 00 00 00 64 64 64 64 ff 00 ff 00 00 00 ff 00 ff 00 00 00 64 00 00 ff 00 30 30 00 00 00 00 00")

    /// The same page as firmware older than 5.21.3242.0 keeps it: version 1.0, curves cut to 28 bytes.
    static func version1_0(_ page: [UInt8]) -> [UInt8] {
        var page = Array(page.prefix(page.count == MappingLayout.size ? page.count : ProfileFormat.v1_0.curvesSize))
        page[0] = 0x10
        return page
    }

    static func slot(normal: [UInt8], shift: [UInt8]? = nil, curves: [UInt8] = CurvesLayout.defaultPage) -> SlotPages {
        SlotPages(normalMapping: normal, normalCurves: curves, shiftMapping: shift ?? restoredDefault, shiftCurves: CurvesLayout.defaultPage)
    }
}

final class FrameTests: XCTestCase {
    func testParseAndSerialize() {
        let bytes = Captured.page("4d 10 07 01 05")
        let frame = GIPFrame(bytes: bytes)!
        XCTAssertEqual(frame.command, 0x4D)
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.payload, [0x05])
        XCTAssertEqual(frame.bytes, bytes)
        XCTAssertTrue(frame.needsAck)
    }

    func testAcknowledgementMatchesWindows() {
        // The Accessories app answered `4d 10 5a 3c ...` with this ACK.
        let frame = GIPFrame(command: 0x4D, options: 0x10, sequence: 0x5A, payload: [UInt8](repeating: 0, count: 0x3C))
        XCTAssertEqual(frame.acknowledgement.bytes, Captured.page("01 20 5a 09 00 4d 00 3c 00 00 00 00 00"))
    }

    func testInitSequence() {
        let frames = GIPPackets.initSequence(GIPSequence(start: 1)).map(\.bytes)
        XCTAssertEqual(frames, [
            Captured.page("05 20 01 01 00"),
            Captured.page("05 20 00 0f 06"),
            Captured.page("4d 10 02 02 07 00"),
            Captured.page("0a 20 03 03 00 01 14"),
            Captured.page("06 20 04 02 01 00"),
            Captured.page("0e 00 05 05 01 00 00 00 00"),
        ])
        XCTAssertEqual(GIPPackets.usbToBluetooth(GIPSequence()).bytes, Captured.page("05 20 00 0f 00"))
        XCTAssertEqual(GIPPackets.keepalive(GIPSequence(start: 0x1a)).bytes, Captured.page("09 00 1a 09 00 0f 00 00 00 00 ff 00 eb"))
    }

    func testChunkedAcknowledgement() {
        // First chunk of the 177-byte identify reply from client 1.
        let bytes = Captured.page("04 f1 f7 3a b1 01") + [UInt8](repeating: 0xAA, count: 58)
        let frame = GIPFrame(bytes: bytes)!
        XCTAssertEqual(frame.chunkOffset, 177)
        XCTAssertEqual(frame.payload.count, 58)
        XCTAssertEqual(frame.acknowledgement.bytes, Captured.page("01 21 f7 09 00 04 21 3a 00 00 00 77 00"))
        // A later chunk at offset 58 with 58 more bytes.
        let next = GIPFrame(bytes: Captured.page("04 b1 f8 3a 3a") + [UInt8](repeating: 0xBB, count: 58))!
        XCTAssertEqual(next.acknowledgement(totalLength: 177).bytes, Captured.page("01 21 f8 09 00 04 21 74 00 00 00 3d 00"))
    }

    func testRejectsMalformedFrames() {
        // Offset 65535 plus one byte overflows the ACK's u16 "received" field: clamp, don't trap.
        let edge = GIPFrame(bytes: Captured.page("04 b1 01 01 ff ff 03 aa"))!
        XCTAssertEqual(edge.chunkOffset, 0xFFFF)
        XCTAssertEqual(Array(edge.acknowledgement.payload[3...4]), [0xFF, 0xFF])
        // Offsets past 16 bits are rejected outright.
        XCTAssertNil(GIPFrame(bytes: Captured.page("04 b1 01 01 80 80 04 aa")))
        // Length says 10 bytes but only 2 arrived.
        XCTAssertNil(GIPFrame(bytes: Captured.page("4d 00 01 0a 03 00")))
        XCTAssertNil(GIPFrame(bytes: Captured.page("4d 00 01")))
    }

    func testLongLengthVarint() {
        let frame = GIPFrame(command: 0x20, options: 0, sequence: 1, payload: [UInt8](repeating: 7, count: 200))
        XCTAssertEqual(GIPFrame(bytes: frame.bytes), frame)
    }

    func testHelloParsing() {
        let hello = GIPFrame(bytes: Captured.page("02 21 01 1c 7e ed 83 72 15 38 00 00 5e 04 02 0b 05 00 16 00 10 00 00 00 05 06 01 00 01 00 01 00"))!
        let info = DeviceInfo(hello: hello.payload)!
        XCTAssertEqual(info.vendorID, 0x045E)
        XCTAssertEqual(info.productID, 0x0B02)
        XCTAssertEqual(info.firmware, "5.22.16.0")
    }

    func testInputReport() {
        var state = InputState()
        // A + LB + upper-left paddle, LT half pulled, left stick full right.
        state.apply(input: Captured.page("10 10 00 02 00 00 ff 7f 00 00 00 00 00 00 04"))
        XCTAssertEqual(state.buttons, [.a, .leftBumper, .paddleUpperLeft])
        XCTAssertEqual(state.leftTrigger, 512)
        XCTAssertEqual(state.leftStickX, 32767)
        state.apply(guide: [0x01])
        XCTAssertTrue(state.buttons.contains(.guide))
        XCTAssertEqual(RemappableControl.allCases.filter(state.isPressed), [.a, .leftBumper, .leftTrigger, .paddleUpperLeft])
    }

    func testEliteReport() {
        var state = InputState()
        // Default profile, left lock at short, right lock at half.
        state.apply(elite: Array(repeating: 0, count: 15) + [0x00, 0x06])
        XCTAssertEqual(state.activeSlot, 0)
        XCTAssertEqual(state.leftTriggerStop, .short)
        XCTAssertEqual(state.rightTriggerStop, .mid)
        state.apply(elite: Array(repeating: 0, count: 15) + [0x00, 0x00])
        XCTAssertEqual(state.leftTriggerStop, .full)
        XCTAssertEqual(state.rightTriggerStop, .full)
    }

    func testEliteReportCarriesRawAxes() {
        // Captured on profile 3 with a 30% left trigger range: 0x20 reported
        // LT 1023 while this report had the physical 319.
        let payload = [UInt8](hexString: "00 00 3f 01 00 00 8a fd 96 01 84 05 21 fe 00 03 00")!
        var state = InputState()
        state.apply(elite: payload)
        XCTAssertEqual(state.rawLeftTrigger, 319)
        XCTAssertEqual(state.rawRightTrigger, 0)
        XCTAssertEqual(state.rawLeftStickX, -630)
        XCTAssertEqual(state.rawLeftStickY, 406)
        XCTAssertEqual(state.rawRightStickX, 1412)
        XCTAssertEqual(state.rawRightStickY, -479)
        XCTAssertEqual(state.activeSlot, 3)
        XCTAssertEqual(state.leftTrigger, 0, "the processed values come from 0x20 only")
    }
}

final class CodecTests: XCTestCase {
    let captured: [[UInt8]] = [
        Captured.restoredDefault, Captured.rightStickClickToB, Captured.paddleShiftNormal, Captured.paddleShiftShift,
        Captured.rightTriggerF, Captured.orangeLight, Captured.triggers67, Captured.macProfile1,
    ]

    func testRoundTripPreservesEveryCapturedByte() throws {
        for page in captured {
            let pages = SlotPages(normalMapping: page, normalCurves: Captured.rightStickInverted, shiftMapping: page, shiftCurves: CurvesLayout.defaultPage)
            let profile = try ProfileCodec.decode(pages, name: "x")
            XCTAssertEqual(ProfileCodec.encode(profile, format: .v1_1), pages, page.hexString)
        }
    }

    func testDefaultDecodesToNoChanges() throws {
        let profile = try ProfileCodec.decode(.factoryDefault, name: "x")
        XCTAssertTrue(profile.buttons.isEmpty)
        XCTAssertTrue(profile.shiftButtons.isEmpty)
        XCTAssertEqual(profile.leftStick.curve.preset, .standard)
        XCTAssertEqual(profile.leftTrigger.range, 0xFF)
        XCTAssertEqual(profile.vibration, VibrationSettings())
        XCTAssertEqual(profile.light, LightSettings(brightness: 100, color: nil))
    }

    func testDecodeRemaps() throws {
        let profile = try ProfileCodec.decode(Captured.slot(normal: Captured.rightStickClickToB, curves: Captured.rightStickInverted), name: "x")
        XCTAssertEqual(profile.buttons[.y], .button(.a))
        XCTAssertEqual(profile.buttons[.rightStick], .button(.b))
        XCTAssertNil(profile.buttons[.a])
        XCTAssertTrue(profile.rightStick.invertY)
        XCTAssertFalse(profile.leftStick.invertY)
    }

    func testDecodeShiftAndKeyboard() throws {
        let shift = try ProfileCodec.decode(Captured.slot(normal: Captured.paddleShiftNormal, shift: Captured.paddleShiftShift), name: "x")
        XCTAssertEqual(shift.shiftControl, .paddleUpperRight)
        XCTAssertEqual(shift.shiftButtons[.paddleUpperRight], .shift)

        let key = try ProfileCodec.decode(Captured.slot(normal: Captured.rightTriggerF), name: "x")
        XCTAssertEqual(key.buttons[.rightTrigger], .key(KeyCombination(KeyboardKey(usage: 0x09))))
        XCTAssertEqual(KeyboardKey(usage: 0x09).label, "F")
    }

    func testDecodeLightAndTriggerRange() throws {
        let profile = try ProfileCodec.decode(Captured.slot(normal: Captured.orangeLight), name: "x")
        XCTAssertEqual(profile.light.brightness, 45)
        XCTAssertEqual(profile.light.color, RGBColor(red: 0xFF, green: 0x6D, blue: 0x20))
        XCTAssertEqual(profile.leftTrigger.rangePercent, 67)
        XCTAssertEqual(profile.rightTrigger.rangePercent, 67)
    }

    func testTriggers67PercentIsMaxABMinZeroAtFullAndHalf() throws {
        let pages = Captured.slot(normal: Captured.triggers67, shift: Captured.triggers67)
        let profile = try ProfileCodec.decode(pages, name: "x")
        for trigger in [profile.leftTrigger, profile.rightTrigger] {
            XCTAssertEqual([trigger.range, trigger.deadZone], [0xAB, 0])
        }
        XCTAssertEqual(ProfileCodec.encode(profile, format: .v1_1), pages)
        let page = MappingPage(Captured.triggers67)
        XCTAssertEqual(page.leftTrigger, TriggerLockPairs(full: TriggerPair(max: 0xAB, min: 0), half: TriggerPair(max: 0xAB, min: 0), short: TriggerPair(max: 0, min: 0)))
        XCTAssertEqual(page.rightTrigger, page.leftTrigger)
    }

    func testEditsProduceAccessoriesBytes() throws {
        // Start from default and make the same edits as the Windows captures.
        var profile = try ProfileCodec.decode(.factoryDefault, name: "x")
        profile.setAssignment(.key(KeyCombination(KeyboardKey(usage: 0x09))), for: .rightTrigger, shift: false)
        XCTAssertEqual(ProfileCodec.encode(profile, format: .v1_1).normalMapping, Captured.rightTriggerF)
        XCTAssertEqual(ProfileCodec.encode(profile, format: .v1_1).shiftMapping, Captured.restoredDefault)

        profile = try ProfileCodec.decode(.factoryDefault, name: "x")
        profile.rightStick.invertY = true
        XCTAssertEqual(ProfileCodec.encode(profile, format: .v1_1).normalCurves, Captured.rightStickInverted)
    }

    func testTriggerRangesFollowTheAccessoriesLayout() throws {
        // Bytes outside the trigger pairs that the app doesn't model stay as they were.
        var normal = Captured.triggers67
        var shift = Captured.restoredDefault
        normal[49] = 0x22
        normal[51] = 0x5A
        shift[51] = 0xA5
        let base = Captured.slot(normal: normal, shift: shift)
        var profile = try ProfileCodec.decode(base, name: "x")
        profile.leftTrigger = TriggerSettings(range: 0x80, deadZone: 0x20)
        profile.rightTrigger = TriggerSettings(range: 0x40)
        let encoded = ProfileCodec.encode(profile, format: .v1_1)
        for (original, updated) in [(normal, encoded.normalMapping), (shift, encoded.shiftMapping)] {
            var expected = original
            expected.replaceSubrange(32..<44, with: Captured.page("80 20 80 20 00 00 40 00 40 00 00 00"))
            XCTAssertEqual(updated, expected)
        }
        XCTAssertEqual(encoded.normalCurves, base.normalCurves)
        XCTAssertEqual(encoded.shiftCurves, base.shiftCurves)
        let decoded = try ProfileCodec.decode(encoded, name: "x")
        XCTAssertEqual([decoded.leftTrigger.range, decoded.leftTrigger.deadZone, decoded.rightTrigger.range, decoded.rightTrigger.deadZone], [0x80, 0x20, 0x40, 0])
    }

    func testTriggerPairsTheFirmwareWouldRewriteAreRepairedTheSameWay() throws {
        // Firmware 0x1005078c: max not above min becomes min + 1 while min is
        // below full; (0, full) becomes (full, 0); otherwise min drops to max - 1.
        func pair(_ settings: TriggerSettings) -> [UInt8] { [settings.range, settings.deadZone] }
        XCTAssertEqual(pair(TriggerSettings(range: 0, deadZone: 0)), [1, 0])
        XCTAssertEqual(pair(TriggerSettings(range: 0x40, deadZone: 0x80)), [0x81, 0x80])
        XCTAssertEqual(pair(TriggerSettings(range: 0x80, deadZone: 0x80)), [0x81, 0x80])
        XCTAssertEqual(pair(TriggerSettings(range: 0, deadZone: 0xFF)), [0xFF, 0])
        XCTAssertEqual(pair(TriggerSettings(range: 0x10, deadZone: 0xFF)), [0x10, 0x0F])
        XCTAssertEqual(pair(TriggerSettings(range: 0xAB, deadZone: 0)), [0xAB, 0])

        // Dragging one end past the other stops one step short of it.
        var trigger = TriggerSettings(range: 0x80, deadZone: 0x20)
        trigger.setRange(0x10)
        XCTAssertEqual(pair(trigger), [0x21, 0x20])
        XCTAssertTrue(trigger.isOnOff)
        trigger.setRange(0xFF)
        trigger.setDeadZone(0xFF)
        XCTAssertEqual(pair(trigger), [0xFF, 0xFE])

        // A page holding a pair the firmware would rewrite is written back repaired, at full and half.
        var page = Captured.restoredDefault
        page.replaceSubrange(32..<38, with: Captured.page("00 00 ff 00 80 7f"))
        let profile = try ProfileCodec.decode(Captured.slot(normal: page), name: "x")
        XCTAssertEqual(pair(profile.leftTrigger), [1, 0])
        XCTAssertEqual(Array(ProfileCodec.encode(profile, format: .v1_1).normalMapping[32..<38]), Captured.page("01 00 01 00 00 00"))
    }

    func testShiftIsExclusiveAndInBothLayers() {
        var profile = EliteProfile.factoryDefault()
        profile.setAssignment(.shift, for: .paddleLowerLeft, shift: false)
        profile.setAssignment(.shift, for: .leftBumper, shift: true)
        XCTAssertEqual(profile.shiftControl, .leftBumper)
        XCTAssertNil(profile.buttons[.paddleLowerLeft])
        XCTAssertEqual(profile.shiftButtons[.leftBumper], .shift)
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual(pages.normalMapping[RemappableControl.leftBumper.mappingOffset], MappingLayout.codeShift)
        XCTAssertEqual(pages.shiftMapping[RemappableControl.leftBumper.mappingOffset], MappingLayout.codeShift)

        profile.setAssignment(.standard, for: .leftBumper, shift: false)
        XCTAssertNil(profile.shiftControl)
        XCTAssertNil(profile.shiftButtons[.leftBumper])
    }

    func testDefaultsUseRecommendedDeadZone() throws {
        let profile = EliteProfile.factoryDefault(name: "x")
        XCTAssertEqual(profile.leftStick.deadZonePercent, 11)
        XCTAssertEqual(profile.rightStick.deadZonePercent, 11)
        XCTAssertEqual(profile.leftStick.preset, .standard)
        XCTAssertTrue(profile.hasDefaultSettings)
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual(Array(pages.normalCurves[1..<3]), [28, 0])
        XCTAssertEqual(Array(pages.normalCurves[13..<15]), [28, 0])
        XCTAssertTrue(try ProfileCodec.decode(pages, name: "x").hasDefaultSettings)
        // A slot that was never written has no dead zone, so it isn't "default" any more.
        XCTAssertFalse(try ProfileCodec.decode(.factoryDefault, name: "x").hasDefaultSettings)
    }

    func testNameKeepsWholeCharacters() {
        // 14 letters and an emoji (two UTF-16 units) don't fit in 15 units;
        // the emoji is dropped whole instead of being cut in half.
        let bytes = ControllerSession.encodeName("ABCDEFGHIJKLMN😀")
        XCTAssertEqual(ControllerSession.decodeName(bytes), "ABCDEFGHIJKLMN")
        XCTAssertEqual(ControllerSession.decodeName(ControllerSession.encodeName("Pad 😀")), "Pad 😀")
    }

    func testTriggerRange() {
        XCTAssertEqual(TriggerSettings.position(percent: 67), 0xAB)
        XCTAssertEqual(TriggerSettings.position(percent: 100), 0xFF)
        let half = TriggerSettings(range: TriggerSettings.position(percent: 50))
        XCTAssertEqual(half.output(forPull: 0.25), 0.5, accuracy: 0.01)
        XCTAssertEqual(half.output(forPull: 0.75), 1)
        XCTAssertEqual(TriggerSettings(range: 0).output(forPull: 0.01), 1)

        // 10-bit positions b * 4 + (b >> 6): 0x40 is 257, 0xC0 is 771.
        let middle = TriggerSettings(range: 0xC0, deadZone: 0x40)
        XCTAssertEqual(middle.output(forPull: 257.0 / 1023), 0)
        XCTAssertEqual(middle.output(forPull: 514.0 / 1023), 0.5, accuracy: 1e-9)
        XCTAssertEqual(middle.output(forPull: 771.0 / 1023), 1)
    }

    func testRejectsCurveWithWrongPointCount() {
        let json = Data(#"{"points":[{"x":10,"y":10}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StickCurve.self, from: json))
    }

    func testIndependentYCurveSurvivesUnrelatedEdit() throws {
        var curves = CurvesLayout.defaultPage
        let yCurve: [UInt8] = [0x40, 0x20, 0x80, 0x60, 0xC0, 0xB0]
        curves.replaceSubrange(7..<13, with: yCurve)
        let pages = SlotPages(normalMapping: MappingLayout.defaultPage, normalCurves: curves, shiftMapping: MappingLayout.defaultPage, shiftCurves: curves)
        var profile = try ProfileCodec.decode(pages, name: "x")
        profile.setAssignment(.button(.b), for: .a, shift: false)
        let encoded = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual(Array(encoded.normalCurves[7..<13]), yCurve)
        XCTAssertEqual(Array(encoded.shiftCurves[7..<13]), yCurve)

        profile.leftStick.curve = CurvePreset.aggressive.curve
        let edited = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual(Array(edited.normalCurves[1..<7]), Array(edited.normalCurves[7..<13]))
    }

    func testSavingWritesTheFirmwaresFormatToEveryPage() throws {
        // A slot last written in format 1.0, saved for 1.1 firmware and for older firmware.
        let old = SlotPages(normalMapping: Captured.version1_0(Captured.restoredDefault), normalCurves: Captured.version1_0(Captured.rightStickInverted),
                            shiftMapping: Captured.version1_0(Captured.restoredDefault), shiftCurves: Captured.version1_0(CurvesLayout.defaultPage))
        var profile = try ProfileCodec.decode(old, name: "x")
        XCTAssertTrue(profile.rightStick.invertY)
        profile.setAssignment(.button(.a), for: .y, shift: false)

        let current = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual([current.normalMapping[0], current.normalCurves[0], current.shiftMapping[0], current.shiftCurves[0]], [0x11, 0x11, 0x11, 0x11])
        XCTAssertEqual(current.normalCurves, Captured.rightStickInverted, "bytes 28-42 are added from the default page")
        XCTAssertEqual(current.shiftCurves, CurvesLayout.defaultPage)

        let older = ProfileCodec.encode(try ProfileCodec.decode(current, name: "x"), format: .v1_0)
        XCTAssertEqual([older.normalMapping[0], older.normalCurves[0], older.shiftMapping[0], older.shiftCurves[0]], [0x10, 0x10, 0x10, 0x10])
        XCTAssertEqual(older.normalCurves, Captured.version1_0(Captured.rightStickInverted))
        XCTAssertEqual(Array(older.normalMapping[1...]), Array(current.normalMapping[1...]))
    }

    func testVersion1_0PagesRoundTrip() throws {
        for page in captured {
            let pages = SlotPages(normalMapping: Captured.version1_0(page), normalCurves: Captured.version1_0(Captured.rightStickInverted),
                                  shiftMapping: Captured.version1_0(page), shiftCurves: Captured.version1_0(CurvesLayout.defaultPage))
            XCTAssertTrue(pages.isValid)
            XCTAssertEqual(ProfileCodec.encode(try ProfileCodec.decode(pages, name: "x"), format: .v1_0), pages, page.hexString)
        }
        // Curves pages of different formats, or of neither size, aren't a slot.
        var mixed = Captured.slot(normal: Captured.restoredDefault)
        mixed.shiftCurves = Captured.version1_0(CurvesLayout.defaultPage)
        XCTAssertFalse(mixed.isValid)
        mixed.shiftCurves = Array(CurvesLayout.defaultPage.prefix(30))
        mixed.normalCurves = mixed.shiftCurves
        XCTAssertFalse(mixed.isValid)
    }

    func testFormatFollowsTheFirmware() {
        // The Accessories app's threshold is 5.21.3242.0 (Devices.App.dll 0x180c21b78).
        XCTAssertEqual(ProfileFormat(firmware: "5.21.3242.0"), .v1_1)
        XCTAssertEqual(ProfileFormat(firmware: "5.22.16.0"), .v1_1)
        XCTAssertEqual(ProfileFormat(firmware: "6.0.0.0"), .v1_1)
        XCTAssertEqual(ProfileFormat(firmware: "5.21.3241.9"), .v1_0)
        XCTAssertEqual(ProfileFormat(firmware: "5.11.3113.0"), .v1_0)
        XCTAssertEqual(ProfileFormat(firmware: "4.8.1908.0"), .v1_0)
        XCTAssertNil(ProfileFormat(firmware: nil))
        XCTAssertNil(ProfileFormat(firmware: "5.21"))
        XCTAssertNil(ProfileFormat(firmware: "5.x.3242.0"))
        // The firmware as the controller announces it in HELLO.
        let hello = [UInt8](repeating: 0, count: 12) + [5, 0, 21, 0, 0x99, 0x0C, 0, 0] + [UInt8](repeating: 1, count: 8)
        XCTAssertEqual(ProfileFormat(firmware: DeviceInfo(hello: hello)?.firmware), .v1_0, "5.21.3225.0")
    }

    func testWritesNeedTheFirmware() throws {
        // A write chooses the format from the firmware, and refuses without it.
        XCTAssertEqual(try ProfileFormat.forWriting(firmware: "5.21.3225.0"), .v1_0)
        XCTAssertEqual(try ProfileFormat.forWriting(firmware: "5.22.16.0"), .v1_1)
        for unknown in [nil, "", "5.21"] {
            XCTAssertThrowsError(try ProfileFormat.forWriting(firmware: unknown)) { error in
                XCTAssertEqual(error as? ControllerError, .firmwareUnknown)
            }
        }
    }

    func testRawPagesMustMatchTheFirmwaresFormat() throws {
        let current = SlotPages.factoryDefault
        let older = SlotPages(normalMapping: Captured.version1_0(Captured.restoredDefault), normalCurves: Captured.version1_0(CurvesLayout.defaultPage),
                              shiftMapping: Captured.version1_0(Captured.restoredDefault), shiftCurves: Captured.version1_0(CurvesLayout.defaultPage))
        XCTAssertNoThrow(try current.checkWritable(firmware: "5.22.16.0"))
        XCTAssertNoThrow(try older.checkWritable(firmware: "5.21.3225.0"))
        XCTAssertThrowsError(try current.checkWritable(firmware: "5.21.3225.0")) { XCTAssertEqual($0 as? ControllerError, .wrongPageFormat(expected: .v1_0)) }
        XCTAssertThrowsError(try older.checkWritable(firmware: "5.22.16.0")) { XCTAssertEqual($0 as? ControllerError, .wrongPageFormat(expected: .v1_1)) }
        XCTAssertThrowsError(try current.checkWritable(firmware: nil)) { XCTAssertEqual($0 as? ControllerError, .firmwareUnknown) }

        // Only the layout is checked: pages read back keep the version byte they were saved with.
        var oldVersionByte = current
        oldVersionByte.normalMapping[0] = 0x10
        oldVersionByte.normalCurves[0] = 0x10
        XCTAssertNoThrow(try oldVersionByte.checkWritable(firmware: "5.22.16.0"))
    }

    func testDeadZoneLivesInTheFirstCurvePoint() throws {
        var stick = StickSettings()
        XCTAssertEqual(stick.deadZone, 0)
        stick.deadZone = 38
        XCTAssertEqual(stick.curve.points[0], CurvePoint(x: 38, y: 0))
        XCTAssertEqual(stick.curve.output(for: 0.1), 0, accuracy: 0.001)
        XCTAssertGreaterThan(stick.curve.output(for: 0.5), 0.3)
        // Points 2 and 3 keep their bytes; the firmware fits them in after the dead zone.
        stick.deadZone = 255
        XCTAssertEqual(stick.deadZone, StickSettings.maxDeadZone)
        XCTAssertEqual(Array(stick.curve.points[1...]), Array(CurvePreset.standard.curve.points[1...]))
        XCTAssertGreaterThan(stick.curve.placedPoints[1].x, stick.curve.placedPoints[0].x)
        stick.deadZone = 0
        XCTAssertEqual(stick.deadZone, 0)
        XCTAssertEqual(stick.curve, CurvePreset.standard.curve)

        // The dead zone survives a preset change, and the preset survives
        // dead zone changes.
        var tuned = StickSettings()
        tuned.deadZone = 28
        tuned.apply(.instant)
        XCTAssertEqual(tuned.deadZone, 28)
        XCTAssertEqual(tuned.preset, .instant)
        tuned.deadZone = 40
        XCTAssertEqual(tuned.preset, .instant)
        tuned.deadZone = 0
        XCTAssertEqual(tuned.curve, CurvePreset.instant.curve)

        // Out-of-order points from a file don't crash; the dead zone only moves point 1.
        var imported = StickSettings(curve: StickCurve(points: [CurvePoint(x: 43, y: 43), CurvePoint(x: 255, y: 200), CurvePoint(x: 191, y: 191)]))
        imported.deadZone = 30
        XCTAssertEqual(imported.curve.points, [CurvePoint(x: 30, y: 0), CurvePoint(x: 255, y: 200), CurvePoint(x: 191, y: 191)])

        // It reaches the curves page for both axes of the stick.
        var profile = try ProfileCodec.decode(.factoryDefault, name: "x")
        profile.leftStick.deadZone = 38
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertEqual(Array(pages.normalCurves[1..<3]), [38, 0])
        XCTAssertEqual(Array(pages.normalCurves[7..<9]), [38, 0])
        XCTAssertEqual(try ProfileCodec.decode(pages, name: "x").leftStick.deadZone, 38)
    }

    func testProfileJSONRoundTrip() throws {
        var profile = EliteProfile.factoryDefault(name: "FPS")
        profile.setAssignment(.button(.y), for: .paddleLowerRight, shift: false)
        profile.setAssignment(.key(KeyCombination(KeyboardKey(usage: 0x2C))), for: .leftTrigger, shift: true)
        profile.setAssignment(.key(KeyCombination(KeyboardKey(usage: 0x09), modifiers: [.control, .alt])), for: .b, shift: false)
        profile.setAssignment(.button(.rightTrigger), for: .x, shift: false)
        profile.setAssignment(.code(0x12), for: .y, shift: true)
        profile.setSticky(true, for: .paddleLowerRight, shift: true)
        profile.swapSticks = true
        profile.light.color = RGBColor(red: 1, green: 2, blue: 3)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(EliteProfile.self, from: data), profile)
    }

    func testTriggerLinkOnlyChangesWhenToggled() {
        func percent(_ value: Int) -> UInt8 { TriggerSettings.position(percent: value) }
        var profile = EliteProfile.factoryDefault()
        profile.leftTrigger = TriggerSettings(range: percent(40))
        profile.rightTrigger = TriggerSettings(range: percent(60))
        var link = TriggerRangeLink(profile)
        XCTAssertFalse(link.isOn)

        // Dragging LT through RT's 60% on the way to 80% leaves RT alone.
        for value in [50, 60, 70, 80] {
            link.update(\.leftTrigger, in: &profile) { $0.setRange(percent(value)) }
        }
        XCTAssertEqual(profile.leftTrigger.rangePercent, 80)
        XCTAssertEqual(profile.rightTrigger.rangePercent, 60)
        XCTAssertFalse(link.isOn)

        link.turnOn(in: &profile)
        XCTAssertEqual(profile.rightTrigger.rangePercent, 80)
        link.update(\.rightTrigger, in: &profile) { $0.setRange(percent(30)) }
        XCTAssertEqual([profile.leftTrigger.rangePercent, profile.rightTrigger.rangePercent], [30, 30])
        // The link covers both ends of the range.
        link.update(\.leftTrigger, in: &profile) { $0.setDeadZone(percent(10)) }
        XCTAssertEqual([profile.leftTrigger.deadZonePercent, profile.rightTrigger.deadZonePercent], [10, 10])

        link.turnOff()
        link.update(\.rightTrigger, in: &profile) { $0.setRange(percent(90)) }
        link.update(\.rightTrigger, in: &profile) { $0.setDeadZone(percent(20)) }
        XCTAssertEqual([profile.leftTrigger.rangePercent, profile.rightTrigger.rangePercent], [30, 90])
        XCTAssertEqual([profile.leftTrigger.deadZonePercent, profile.rightTrigger.deadZonePercent], [10, 20])

        XCTAssertTrue(TriggerRangeLink(EliteProfile.factoryDefault()).isOn, "matching ranges start linked")
        profile.rightTrigger = TriggerSettings(range: percent(30), deadZone: percent(15))
        XCTAssertFalse(TriggerRangeLink(profile).isOn, "same full press, different dead zone")
    }

    func testUnmappedEssentialButtons() {
        var profile = EliteProfile.factoryDefault()
        XCTAssertEqual(profile.unmappedEssentialButtons, [])

        // P3 still gives A by default, so moving A elsewhere isn't enough.
        profile.setAssignment(.button(.x), for: .a, shift: false)
        XCTAssertEqual(profile.unmappedEssentialButtons, [])
        profile.setAssignment(.disabled, for: .paddleUpperLeft, shift: false)
        XCTAssertEqual(profile.unmappedEssentialButtons, [.a])

        // Only the normal layer counts.
        profile.setAssignment(.button(.a), for: .y, shift: true)
        XCTAssertEqual(profile.unmappedEssentialButtons, [.a])
        profile.setAssignment(.button(.a), for: .y, shift: false)
        XCTAssertEqual(profile.unmappedEssentialButtons, [])

        profile.setAssignment(.shift, for: .b, shift: false)
        profile.setAssignment(.key(KeyCombination(KeyboardKey(usage: 0x05))), for: .paddleUpperRight, shift: false)
        XCTAssertEqual(profile.unmappedEssentialButtons, [.b])
        profile.setAssignment(.standard, for: .y, shift: false)
        XCTAssertEqual(profile.unmappedEssentialButtons, [.a, .b])
    }

    func testHexColour() {
        let orange = EliteKit.RGBColor(red: 0xFF, green: 0x6D, blue: 0x20)
        XCTAssertEqual(orange.hex, "#FF6D20")
        XCTAssertEqual(EliteKit.RGBColor(hex: "#FF6D20"), orange)
        XCTAssertEqual(EliteKit.RGBColor(hex: "ff6d20"), orange)
        XCTAssertEqual(EliteKit.RGBColor(hex: " #Ff6D20 "), orange)
        XCTAssertEqual(EliteKit.RGBColor(hex: EliteKit.RGBColor(red: 0, green: 1, blue: 0xFE).hex), EliteKit.RGBColor(red: 0, green: 1, blue: 0xFE))
        for bad in ["", "#", "#FF6D2", "#FF6D200", "##FF6D20", "#FF 6D 20", "#GG6D20", "+F6D20", "#FF6D2Z"] {
            XCTAssertNil(EliteKit.RGBColor(hex: bad), bad)
        }
    }

    func testCurveInterpolation() {
        let linear = CurvePreset.standard.curve
        XCTAssertEqual(linear.output(for: 0.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(linear.output(for: 1.0), 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(CurvePreset.aggressive.curve.output(for: 0.6), 0.6)
        XCTAssertLessThan(CurvePreset.delay.curve.output(for: 0.6), 0.6)
    }

    func testPresetsWriteTheAccessoriesBytes() throws {
        let expected: [CurvePreset: String] = [
            .standard: "2b 2b 7f 7f bf bf", .delay: "2b 2b 3f 3f da 8d", .aggressive: "2b 2b 3f 3f 8c c5",
            .instant: "2b 2b 3f 3f 3f 68", .smooth: "2b 2b 8c 8c d8 9c",
        ]
        for (preset, hex) in expected {
            let axis = Captured.page(hex)
            var profile = try ProfileCodec.decode(.factoryDefault, name: "x")
            profile.leftStick.apply(preset)
            profile.rightStick.apply(preset)
            let pages = ProfileCodec.encode(profile, format: .v1_1)
            for curves in [pages.normalCurves, pages.shiftCurves] {
                XCTAssertEqual(Array(curves[1..<25]), axis + axis + axis + axis, preset.label)
            }
            let decoded = try ProfileCodec.decode(pages, name: "x")
            XCTAssertEqual([decoded.leftStick.preset, decoded.rightStick.preset], [preset, preset])

            // A dead zone replaces point 1 only, and the preset still shows.
            profile.leftStick.deadZone = 28
            let zoned = ProfileCodec.encode(profile, format: .v1_1)
            XCTAssertEqual(Array(zoned.normalCurves[1..<13]), [28, 0] + axis[2...] + [28, 0] + axis[2...], preset.label)
            XCTAssertEqual(try ProfileCodec.decode(zoned, name: "x").leftStick.preset, preset)
        }
    }

    func testCurvesFromTheOldApproximatePresetsLoadAsCustom() throws {
        // What earlier builds wrote for Fast start, with an 11% dead zone.
        let json = Data(#"{"curve":{"points":[{"x":28,"y":0},{"x":127,"y":168},{"x":191,"y":220}]},"invertY":false}"#.utf8)
        let stick = try JSONDecoder().decode(StickSettings.self, from: json)
        XCTAssertNil(stick.preset)
        XCTAssertEqual(stick.deadZone, 28)
    }

    func testCurveOutputFollowsTheFirmware() {
        // Expected values, in 15-bit units, worked through the firmware's
        // arithmetic: bytes scaled by 0x10050608, points 2 and 3 placed above
        // point 1 and the segments mapped by 0x1004e0ca (0x10050612).
        func output(_ curve: StickCurve, _ input: Int) -> Int { Int((curve.output(for: Double(input) / 32767) * 32767).rounded()) }
        func curve(_ v: [UInt8]) -> StickCurve { StickCurve(points: [CurvePoint(x: v[0], y: v[1]), CurvePoint(x: v[2], y: v[3]), CurvePoint(x: v[4], y: v[5])]) }

        let deadZone = curve([28, 0, 0x7F, 0x7F, 0xBF, 0xBF])
        XCTAssertEqual([0, 3598, 3599, 9830, 16384, 20000, 26000, 32767].map { output(deadZone, $0) }, [0, 0, 1, 7000, 14363, 18425, 25165, 32767])
        XCTAssertEqual(deadZone.placedPoints.map { [Int(($0.x * 32767).rounded()), Int(($0.y * 32767).rounded())] }, [[3598, 0], [18125, 16319], [25446, 24543]],
                       "points 2 and 3 sit in the range above the dead zone, not at their own bytes")

        let aggressive = curve([0x2B, 0x50, 0x7F, 0xA8, 0xBF, 0xDC])
        XCTAssertEqual([3598, 9830, 16384, 26000].map { output(aggressive, $0) }, [6694, 14981, 22137, 29712])

        for input in [0, 3598, 9830, 16384, 26000, 32767] {
            XCTAssertEqual(output(CurvePreset.standard.curve, input), input, "the factory curve is straight")
        }
    }

    func testMovingAPointPlacesItWhereItWasDropped() {
        let deadZone = StickCurve(points: [CurvePoint(x: 28, y: 0), CurvePoint(x: 0x7F, y: 0x7F), CurvePoint(x: 0xBF, y: 0xBF)])
        let moved = deadZone.moving(point: 1, toPlaced: 0.7, 0.6)
        XCTAssertEqual(moved.placedPoints[1].x, 0.7, accuracy: 1.0 / 255)
        XCTAssertEqual(moved.placedPoints[1].y, 0.6, accuracy: 1.0 / 255)
        XCTAssertEqual(moved.points[0], deadZone.points[0])

        // Point 2 stops short of point 3, and point 3 can't pass point 2.
        XCTAssertEqual(deadZone.moving(point: 1, toPlaced: 0.95, 0.5).points[1].x, 0xBE)
        XCTAssertEqual(deadZone.moving(point: 2, toPlaced: 0.2, 0.5).points[2].x, 0x80)
        // Point 1 moves on its own; the others follow it because they're stored relative to it.
        let raised = deadZone.moving(point: 0, toPlaced: 0.2, 0)
        XCTAssertEqual(raised.points[0], CurvePoint(x: 51, y: 0))
        XCTAssertGreaterThan(raised.placedPoints[1].x, deadZone.placedPoints[1].x)
    }

    func testPresetsUseAccessoriesNamesAndKeepRawValues() throws {
        XCTAssertEqual(CurvePreset.allCases.map(\.label), ["Default", "Slow start", "Fast start", "Instant", "Smooth"])
        let decoded = try JSONDecoder().decode([CurvePreset].self, from: Data(#"["standard", "aggressive", "delay"]"#.utf8))
        XCTAssertEqual(decoded.map(\.label), ["Default", "Fast start", "Slow start"])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(CurvePreset.delay), as: UTF8.self), #""delay""#)
    }
}

final class SessionTests: XCTestCase {
    func makeSession(_ sim: SimulatedController) -> ControllerSession {
        let session = ControllerSession(link: sim, inbox: sim.inbox)
        session.timeout = 0.05
        return session
    }

    func testWriteSlotFollowsAccessoriesSequence() throws {
        let sim = SimulatedController()
        let session = makeSession(sim)
        var profile = EliteProfile.factoryDefault()
        profile.setAssignment(.button(.a), for: .y, shift: false)
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        try session.writeSlot(2, pages: pages)

        XCTAssertEqual(try session.readSlot(2), pages)
        XCTAssertEqual(sim.pages[0x22], pages.normalMapping)
        XCTAssertEqual(sim.pages[0x20], MappingLayout.defaultPage, "other slots untouched")

        let vendorSubs = sim.sent.filter { $0.command == GIPCommand.vendor }.map { $0.payload[0] }
        XCTAssertEqual(Array(vendorSubs.prefix(9)), [0x07, 0x03, 0x03, 0x01, 0x01, 0x01, 0x01, 0x07, 0x03])
        XCTAssertEqual(sim.sent.last { $0.command == GIPCommand.power }?.payload, [0x05])
    }

    func testLateDuplicateReplyDoesNotBreakVerification() throws {
        let sim = SimulatedController()
        let session = makeSession(sim)
        // The first read times out; its answer arrives with the retry's, so
        // the controller has answered twice.
        sim.delayNextReply = true
        _ = try session.readSlot(1)
        // Saving the same slot reads its pages back to verify; an old reply
        // with the previous contents must not be mistaken for the new one.
        var profile = EliteProfile.factoryDefault()
        profile.setAssignment(.button(.b), for: .a, shift: false)
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertNoThrow(try session.writeSlot(1, pages: pages))
        XCTAssertEqual(sim.pages[0x20], pages.normalMapping)
    }

    func testVeryLateRetryReplyDoesNotBreakVerification() throws {
        let sim = SimulatedController()
        let session = makeSession(sim)
        // The first read's answer comes just after the retry is sent and is
        // taken as the reply; the retry's own answer turns up much later,
        // while later requests are running.
        sim.replyDelays = [0.07, 0.3]
        _ = try session.readSlot(1)
        var profile = EliteProfile.factoryDefault()
        profile.setAssignment(.button(.x), for: .a, shift: false)
        let pages = ProfileCodec.encode(profile, format: .v1_1)
        XCTAssertNoThrow(try session.writeSlot(1, pages: pages))
        XCTAssertEqual(try session.readSlot(1), pages)
    }

    func testOwedAnswerRecordedWhenRetrySendFails() throws {
        let sim = SimulatedController()
        let session = makeSession(sim)
        let page: UInt8 = 0x20
        // First read: its answer is late, and the retry's send fails.
        sim.replyDelays = [0.07, 0.04]
        sim.failVendorSend = 2
        XCTAssertThrowsError(try session.readPage(page, size: MappingLayout.size))
        // The page changes; the next read must not take the old late answer.
        var updated = MappingLayout.defaultPage
        updated[5] = 0x05
        sim.pages[page] = updated
        XCTAssertEqual(try session.readPage(page, size: MappingLayout.size), updated)
    }

    func testCustomProfileActive() throws {
        let sim = SimulatedController()
        sim.activeSlot = 1
        let session = makeSession(sim)
        // Reads of the active slot still work (flagged 0x80 on the wire).
        XCTAssertEqual(try session.readSlot(1), .factoryDefault)
        XCTAssertThrowsError(try session.writeSlot(2, pages: .factoryDefault)) { error in
            XCTAssertEqual(error as? ControllerError, .customProfileActive)
        }
        sim.activeSlot = 0
        XCTAssertNoThrow(try session.writeSlot(2, pages: .factoryDefault))
    }

    func testProbeActiveSlot() throws {
        let sim = SimulatedController()
        let session = makeSession(sim)
        for slot in 0...3 {
            sim.activeSlot = slot
            XCTAssertEqual(try session.probeActiveSlot(), slot)
        }
    }

    func testReadsAndWritesAVersion1_0Slot() throws {
        let sim = SimulatedController()
        let session = makeSession(sim)
        let address = ProfilePages.addresses(slot: 2)!
        for page in [address.normalMapping, address.shiftMapping] { sim.pages[page] = Captured.version1_0(MappingLayout.defaultPage) }
        for page in [address.normalCurves, address.shiftCurves] { sim.pages[page] = Captured.version1_0(Captured.rightStickInverted) }

        var profile = try ProfileCodec.decode(try session.readSlot(2), name: "x")
        XCTAssertEqual(profile.basePages.normalCurves.count, 28)
        XCTAssertTrue(profile.rightStick.invertY)
        profile.setAssignment(.button(.b), for: .a, shift: false)
        let pages = ProfileCodec.encode(profile, format: .v1_0)
        try session.writeSlot(2, pages: pages)
        XCTAssertEqual(sim.pages[address.normalCurves], Captured.version1_0(Captured.rightStickInverted))
        XCTAssertEqual(sim.pages[address.normalMapping]?[5], 0x05)
    }

    func testRejectsDefaultSlot() {
        let session = makeSession(SimulatedController())
        XCTAssertThrowsError(try session.writeSlot(0, pages: .factoryDefault)) { error in
            XCTAssertEqual(error as? ControllerError, .invalidSlot(0))
        }
    }

    func testVerifyFailure() {
        let sim = SimulatedController()
        sim.corruptPage = 0x24
        XCTAssertThrowsError(try makeSession(sim).writeSlot(3, pages: .factoryDefault)) { error in
            XCTAssertEqual(error as? ControllerError, .verifyFailed(page: 0x24))
        }
    }

    func testRetriesWhenAReplyIsLost() throws {
        let sim = SimulatedController()
        sim.dropNextReplies = 2
        XCTAssertEqual(try makeSession(sim).readName(), "Elite")
    }

    func testTimeoutAfterRetries() {
        let sim = SimulatedController()
        sim.dropNextReplies = 10
        XCTAssertThrowsError(try makeSession(sim).readName()) { error in
            XCTAssertEqual(error as? ControllerError, .timeout("read name"))
        }
    }

    func testIgnoresReplyWithoutStatus() {
        let sim = SimulatedController()
        let session = makeSession(sim)
        sim.dropNextReplies = 10
        // A truncated unlock reply must not count as success.
        sim.inbox.push(GIPFrame(command: GIPCommand.vendor, options: 0, sequence: 1, payload: [VendorCommand.unlock]))
        XCTAssertThrowsError(try session.unlock())
    }

    func testNameRoundTrip() throws {
        let sim = SimulatedController()
        let session = makeSession(sim)
        XCTAssertEqual(try session.writeName("Himothy's Elite 2 long"), "Himothy's Elite")
        // Bytes the real controller returned on macOS.
        let reply = Captured.page("48 00 69 00 6d 00 6f 00 74 00 68 00 79 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(ControllerSession.decodeName(reply), "Himothy")
    }
}

final class StickCheckTests: XCTestCase {
    func testRestOffsetAndSuggestedDeadZone() {
        var check = StickCheck()
        XCTAssertNil(check.suggestedDeadZone)
        check.addRest(x: 300, y: -200)
        XCTAssertNil(check.suggestedDeadZone, "about 1% off centre needs no dead zone")
        check.addRest(x: 1966, y: 0) // 6%
        XCTAssertEqual(check.restOffset, 1966.0 / 32767, accuracy: 1e-9)
        XCTAssertEqual(check.suggestedDeadZone, 8)
        XCTAssertEqual(check.restCentre!.x, (300.0 + 1966) / 2 / 32767, accuracy: 1e-9)
    }

    func testCircleReachAndShortDirections() {
        var check = StickCheck()
        XCTAssertEqual(check.coverage, 0)
        XCTAssertNil(check.averageReach)
        // A full circle, except up only reaches 90%.
        for step in 0..<720 {
            let angle = Double(step) / 720 * 2 * .pi
            let radius = abs(angle - .pi / 2) < 0.2 ? 0.9 : 1.0
            check.addMotion(x: Int16(cos(angle) * radius * 32767), y: Int16(sin(angle) * radius * 32767))
        }
        XCTAssertEqual(check.coverage, 1)
        XCTAssertEqual(check.minimumReach!, 0.9, accuracy: 0.001)
        XCTAssertEqual(check.shortDirections, [.up])
        // Small pushes don't count as visiting a direction.
        var small = StickCheck()
        small.addMotion(x: 8000, y: 0)
        XCTAssertEqual(small.coverage, 0)
        XCTAssertEqual(StickCheck.sector(dx: 0, dy: 1), 18)
        XCTAssertEqual(StickCheck.sector(dx: 1, dy: -0.0001), 71)
    }

    func testTriggerCheck() {
        var check = TriggerCheck()
        check.addRest(12)
        check.addRest(4)
        check.addMotion(1001)
        check.addMotion(400)
        XCTAssertEqual(check.rest, 12)
        XCTAssertEqual(check.peak, 1001)
    }
}

final class CalibrationTests: XCTestCase {
    func testParsesCapturedReplies() {
        // Payloads from the Windows capture of the Accessories app.
        let stick = CalibrationReading(reply: [UInt8](hexString: "0f 00 00 01 51 03 a1 0c 73 03 b0 0c")!)
        XCTAssertEqual(stick, CalibrationReading(target: .leftStick, state: .idle, values: [849, 3233, 883, 3248]))
        let trigger = CalibrationReading(reply: [UInt8](hexString: "0f 00 10 04 04 ed 03 5a 05 84 07 03 0d")!)
        XCTAssertEqual(trigger, CalibrationReading(target: .leftTrigger, state: .finished, values: [1005, 1370, 1924, 3331]))
        // Read right after a start: the state is the target being calibrated.
        let started = CalibrationReading(reply: [UInt8](hexString: "0f 00 04 04 04 00 00 00 00 00 00 00 00")!)
        XCTAssertEqual(started?.state, .collecting(0x04))
        XCTAssertTrue(started!.isCollecting)
        // On macOS, with the right stick's calibration unfinished, every read
        // reported it; the left stick still had its stored values.
        let other = CalibrationReading(reply: [UInt8](hexString: "0f 00 02 01 8a 03 a3 0c 48 03 97 0c")!)
        XCTAssertEqual(other?.state, .collecting(0x02))
        XCTAssertFalse(other!.isCollecting)
        XCTAssertNil(CalibrationReading(reply: [0x0F, 0x00, 0x00, 0x03, 0x00, 0x00]), "not a known target")
    }

    func testCalibrationSequence() throws {
        let controller = SimulatedController()
        let session = ControllerSession(link: controller, inbox: controller.inbox)
        XCTAssertEqual(try session.readCalibration(.leftStick).state, .idle)
        controller.calibrationMovementDone = false
        try session.startCalibration(.leftStick)
        let early = try session.readCalibration(.leftStick)
        XCTAssertTrue(early.isCollecting)
        XCTAssertEqual(early.values, [0, 0, 0, 0])
        controller.calibrationMovementDone = true
        let result = try session.readCalibration(.leftStick)
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.values, [849, 3233, 883, 3248])
        let sent = controller.sent.filter { $0.command == GIPCommand.system }.map(\.payload)
        XCTAssertEqual(sent, [[0x0F, 0x01], [0x10, 0x01], [0x0F, 0x01], [0x0F, 0x01]])
        XCTAssertEqual(controller.sent.last?.options, GIPOptions.needsAck)
        XCTAssertEqual(try session.readCalibration(.leftTrigger).values, [1070, 1353, 1896, 3341])
    }
}

final class QuickRemapTests: XCTestCase {
    let start = ContinuousClock.now

    func input(_ buttons: Set<InputButton>, slot: Int? = 0) -> InputState {
        var state = InputState()
        state.buttons = buttons
        state.activeSlot = slot
        return state
    }

    func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    func testHoldPicksTheControlOnce() {
        var detector = QuickRemapDetector()
        XCTAssertNil(detector.update(input([.x]), at: at(0)))
        XCTAssertEqual(detector.deadline, at(1000))
        XCTAssertNil(detector.update(input([.x]), at: at(999)))
        XCTAssertEqual(detector.update(input([.x]), at: at(1000)), .x)
        XCTAssertNil(detector.deadline)
        XCTAssertNil(detector.update(input([.x]), at: at(3000)), "still the same press")

        XCTAssertNil(detector.update(input([]), at: at(3100)))
        XCTAssertNil(detector.update(input([.x]), at: at(3200)))
        XCTAssertEqual(detector.update(input([.x]), at: at(4200)), .x, "a new press picks it again")
    }

    func testAPickedControlStaysPickedUntilReleased() {
        var detector = QuickRemapDetector()
        _ = detector.update(input([.x]), at: at(0))
        XCTAssertEqual(detector.update(input([.x]), at: at(1000)), .x)
        XCTAssertNil(detector.update(input([.x, .b]), at: at(1200)), "tapping B while X is still down")
        XCTAssertNil(detector.update(input([.x]), at: at(1400)))
        XCTAssertNil(detector.deadline)
        XCTAssertNil(detector.update(input([.x]), at: at(2400)), "X hasn't been let go")
        XCTAssertNil(detector.update(input([.x]), at: at(5000)))

        XCTAssertNil(detector.update(input([]), at: at(5100)))
        _ = detector.update(input([.x]), at: at(5200))
        XCTAssertEqual(detector.update(input([.x]), at: at(6200)), .x)
    }

    func testOtherReportsDuringTheHoldKeepItsStart() {
        // Stick and trigger movement sends reports with the same buttons.
        var detector = QuickRemapDetector()
        var moved = input([.dpadLeft])
        _ = detector.update(moved, at: at(0))
        moved.leftStickX = 9000
        moved.rightTrigger = 400
        XCTAssertNil(detector.update(moved, at: at(600)))
        XCTAssertEqual(detector.update(moved, at: at(1000)), .dpadLeft)
    }

    func testChangingOrAddingAControlRestarts() {
        var detector = QuickRemapDetector()
        _ = detector.update(input([.a]), at: at(0))
        XCTAssertNil(detector.update(input([.a, .b]), at: at(500)))
        XCTAssertNil(detector.deadline, "two controls at once isn't a quick remap")
        XCTAssertNil(detector.update(input([.b]), at: at(800)))
        XCTAssertNil(detector.update(input([.b]), at: at(1500)))
        XCTAssertEqual(detector.update(input([.b]), at: at(1800)), .b)
    }

    func testPaddleOutranksTheButtonItReports() {
        var detector = QuickRemapDetector()
        _ = detector.update(input([.rightBumper, .paddleUpperRight]), at: at(0))
        XCTAssertEqual(detector.update(input([.rightBumper, .paddleUpperRight]), at: at(1000)), .paddleUpperRight)
    }

    func testIgnoresButtonsThatCantBeRemapped() {
        var detector = QuickRemapDetector()
        _ = detector.update(input([.menu, .leftStick]), at: at(0))
        XCTAssertEqual(detector.update(input([.leftStick, .guide]), at: at(1000)), .leftStick)
        XCTAssertNil(detector.update(input([.view]), at: at(1100)))
        XCTAssertNil(detector.deadline)
    }

    func testOnlyOnTheDefaultProfile() {
        var detector = QuickRemapDetector()
        for slot in [1, nil] {
            _ = detector.update(input([.a], slot: slot), at: at(0))
            XCTAssertNil(detector.update(input([.a], slot: slot), at: at(2000)))
            XCTAssertNil(detector.deadline)
        }
        _ = detector.update(input([.a]), at: at(2000))
        XCTAssertNil(detector.update(input([.a], slot: 2), at: at(2500)), "switching profile mid-hold cancels it")
        XCTAssertNil(detector.update(input([.a]), at: at(3000)))
        XCTAssertNil(detector.update(input([.a]), at: at(3999)))
        XCTAssertEqual(detector.update(input([.a]), at: at(4000)), .a)
    }
}

@MainActor
final class RumbleSequencerTests: XCTestCase {
    struct StartFailed: Error {}

    @MainActor final class Motors {
        var requests: [String] = []
    }

    func testFailedStartDoesNotKeepTheMotorsRunning() async throws {
        let sequencer = RumbleSequencer()
        let motors = Motors()
        let test = Task {
            try await sequencer.play(for: .milliseconds(300), start: { motors.requests.append("start test") }, stop: { motors.requests.append("stop") })
        }
        try await Task.sleep(for: .milliseconds(100))
        do {
            try await sequencer.play(for: .milliseconds(400), start: { throw StartFailed() }, stop: { motors.requests.append("stop buzz") })
            XCTFail("the start error reaches the caller")
        } catch is StartFailed {}
        try await test.value
        XCTAssertEqual(motors.requests, ["start test", "stop"])
    }

    func testOnlyTheNewestRumbleStopsTheMotors() async throws {
        // A motor test, then Buzz before it ends: the test's stop would cut Buzz short.
        let sequencer = RumbleSequencer()
        let motors = Motors()
        let test = Task {
            try await sequencer.play(for: .milliseconds(300), start: { motors.requests.append("start test") }, stop: { motors.requests.append("stop test") })
        }
        try await Task.sleep(for: .milliseconds(100))
        try await sequencer.play(for: .milliseconds(400), start: { motors.requests.append("start buzz") }, stop: { motors.requests.append("stop buzz") })
        try await test.value
        XCTAssertEqual(motors.requests, ["start test", "start buzz", "stop buzz"])
    }
}
