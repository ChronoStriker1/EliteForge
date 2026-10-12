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
            XCTAssertEqual(ProfileCodec.encode(profile), pages, page.hexString)
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
        XCTAssertEqual(key.buttons[.rightTrigger], .key(KeyboardKey(usage: 0x09)))
        XCTAssertEqual(KeyboardKey(usage: 0x09).label, "F")
    }

    func testDecodeLightAndTriggerRange() throws {
        let profile = try ProfileCodec.decode(Captured.slot(normal: Captured.orangeLight), name: "x")
        XCTAssertEqual(profile.light.brightness, 45)
        XCTAssertEqual(profile.light.color, RGBColor(red: 0xFF, green: 0x6D, blue: 0x20))
        XCTAssertEqual(profile.leftTrigger.rangePercent, 67)
        XCTAssertEqual(profile.rightTrigger.rangePercent, 67)
    }

    func testEditsProduceAccessoriesBytes() throws {
        // Start from default and make the same edits as the Windows captures.
        var profile = try ProfileCodec.decode(.factoryDefault, name: "x")
        profile.setAssignment(.key(KeyboardKey(usage: 0x09)), for: .rightTrigger, shift: false)
        XCTAssertEqual(ProfileCodec.encode(profile).normalMapping, Captured.rightTriggerF)
        XCTAssertEqual(ProfileCodec.encode(profile).shiftMapping, Captured.restoredDefault)

        profile = try ProfileCodec.decode(.factoryDefault, name: "x")
        profile.rightStick.invertY = true
        XCTAssertEqual(ProfileCodec.encode(profile).normalCurves, Captured.rightStickInverted)
    }

    func testTriggerEditsPreserveStickRangesAndOtherMappingBytes() throws {
        var normal = Captured.triggers67
        var shift = Captured.restoredDefault
        normal[34] = 0x60
        normal[40] = 0x90
        shift[34] = 0x70
        shift[40] = 0xA0
        let base = Captured.slot(normal: normal, shift: shift)
        var profile = try ProfileCodec.decode(base, name: "x")
        profile.leftTrigger.range = 0x80
        profile.rightTrigger.range = 0x40
        let encoded = ProfileCodec.encode(profile)
        for (original, updated) in [(normal, encoded.normalMapping), (shift, encoded.shiftMapping)] {
            var expected = original
            expected[32] = 0x80
            expected[33] = 0
            expected[38] = 0x40
            expected[39] = 0
            XCTAssertEqual(updated, expected)
        }
        XCTAssertEqual(encoded.normalCurves, base.normalCurves)
        XCTAssertEqual(encoded.shiftCurves, base.shiftCurves)
    }

    func testShiftIsExclusiveAndInBothLayers() {
        var profile = EliteProfile.factoryDefault()
        profile.setAssignment(.shift, for: .paddleLowerLeft, shift: false)
        profile.setAssignment(.shift, for: .leftBumper, shift: true)
        XCTAssertEqual(profile.shiftControl, .leftBumper)
        XCTAssertNil(profile.buttons[.paddleLowerLeft])
        XCTAssertEqual(profile.shiftButtons[.leftBumper], .shift)
        let pages = ProfileCodec.encode(profile)
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
        let pages = ProfileCodec.encode(profile)
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
        XCTAssertEqual(TriggerSettings.range(percent: 67), 0xAB)
        XCTAssertEqual(TriggerSettings.range(percent: 100), 0xFF)
        let half = TriggerSettings(range: TriggerSettings.range(percent: 50))
        XCTAssertEqual(half.output(forPull: 0.25), 0.5, accuracy: 0.01)
        XCTAssertEqual(half.output(forPull: 0.75), 1)
        XCTAssertEqual(TriggerSettings(range: 0).output(forPull: 0.01), 1)
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
        let encoded = ProfileCodec.encode(profile)
        XCTAssertEqual(Array(encoded.normalCurves[7..<13]), yCurve)
        XCTAssertEqual(Array(encoded.shiftCurves[7..<13]), yCurve)

        profile.leftStick.curve = CurvePreset.aggressive.curve
        let edited = ProfileCodec.encode(profile)
        XCTAssertEqual(Array(edited.normalCurves[1..<7]), Array(edited.normalCurves[7..<13]))
    }

    func testSavingBlankSlotMarksPagesSaved() throws {
        func blank(_ page: [UInt8]) -> [UInt8] {
            var page = page
            page[0] = 0x10
            return page
        }
        let pages = SlotPages(normalMapping: blank(MappingLayout.defaultPage), normalCurves: blank(CurvesLayout.defaultPage),
                              shiftMapping: blank(MappingLayout.defaultPage), shiftCurves: blank(CurvesLayout.defaultPage))
        var profile = try ProfileCodec.decode(pages, name: "x")
        profile.setAssignment(.button(.a), for: .y, shift: false)
        let encoded = ProfileCodec.encode(profile)
        XCTAssertEqual([encoded.normalMapping[0], encoded.normalCurves[0], encoded.shiftMapping[0], encoded.shiftCurves[0]], [0x11, 0x11, 0x11, 0x11])
    }

    func testDeadZoneLivesInTheFirstCurvePoint() throws {
        var stick = StickSettings()
        XCTAssertEqual(stick.deadZone, 0)
        stick.deadZone = 38
        XCTAssertEqual(stick.curve.points[0], CurvePoint(x: 38, y: 0))
        XCTAssertEqual(stick.curve.output(for: 0.1), 0, accuracy: 0.001)
        XCTAssertGreaterThan(stick.curve.output(for: 0.5), 0.3)
        // A large dead zone pushes the second point along so the points stay ordered.
        stick.deadZone = 255
        XCTAssertEqual(stick.deadZone, StickSettings.maxDeadZone)
        XCTAssertLessThan(stick.curve.points[0].x, stick.curve.points[1].x)
        XCTAssertLessThan(stick.curve.points[1].x, stick.curve.points[2].x)
        stick.deadZone = 0
        XCTAssertEqual(stick.deadZone, 0)
        XCTAssertGreaterThan(stick.curve.points[0].y, 0)

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

        // Out-of-order points from a file don't crash, and come out ordered.
        var imported = StickSettings(curve: StickCurve(points: [CurvePoint(x: 43, y: 43), CurvePoint(x: 255, y: 200), CurvePoint(x: 191, y: 191)]))
        imported.deadZone = 30
        XCTAssertLessThan(imported.curve.points[0].x, imported.curve.points[1].x)
        XCTAssertLessThan(imported.curve.points[1].x, imported.curve.points[2].x)

        // It reaches the curves page for both axes of the stick.
        var profile = try ProfileCodec.decode(.factoryDefault, name: "x")
        profile.leftStick.deadZone = 38
        let pages = ProfileCodec.encode(profile)
        XCTAssertEqual(Array(pages.normalCurves[1..<3]), [38, 0])
        XCTAssertEqual(Array(pages.normalCurves[7..<9]), [38, 0])
        XCTAssertEqual(try ProfileCodec.decode(pages, name: "x").leftStick.deadZone, 38)
    }

    func testProfileJSONRoundTrip() throws {
        var profile = EliteProfile.factoryDefault(name: "FPS")
        profile.setAssignment(.button(.y), for: .paddleLowerRight, shift: false)
        profile.setAssignment(.key(KeyboardKey(usage: 0x2C)), for: .leftTrigger, shift: true)
        profile.light.color = RGBColor(red: 1, green: 2, blue: 3)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(EliteProfile.self, from: data), profile)
    }

    func testCurveInterpolation() {
        let linear = CurvePreset.standard.curve
        XCTAssertEqual(linear.output(for: 0.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(linear.output(for: 1.0), 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(CurvePreset.aggressive.curve.output(for: 0.3), 0.3)
        XCTAssertLessThan(CurvePreset.delay.curve.output(for: 0.3), 0.3)
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
        let pages = ProfileCodec.encode(profile)
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
        let pages = ProfileCodec.encode(profile)
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
        let pages = ProfileCodec.encode(profile)
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
