import XCTest
import EliteIPC
import EliteKit

/// Stands in for the helper: it knows the firmware only once a capture has
/// seen the controller's HELLO. Before that it can still show what an
/// earlier capture reported.
final class FakeHelper {
    private let captured: DeviceInfo?
    private let earlier: DeviceInfo?
    private var attached = false

    /// Versions are the HELLO's four numbers; nil for a capture with no HELLO.
    init(firmware: [UInt16]?, earlier: [UInt16]? = nil) {
        captured = firmware.flatMap(Self.info)
        self.earlier = earlier.flatMap(Self.info)
    }

    static func info(_ version: [UInt16]) -> DeviceInfo? {
        DeviceInfo(hello: [UInt8](repeating: 0, count: 12) + version.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [UInt8](repeating: 1, count: 8))
    }

    func perform(_ request: HelperRequest) throws -> HelperReply {
        if case .attach = request { attached = true }
        return .status(ControllerStatus(present: true, attached: attached, info: attached ? captured : earlier))
    }
}

final class HelperRequestTests: XCTestCase {
    func testFirmwareIsAskedForAfterCapturing() throws {
        let firmware = try HelperRequest.capturedFirmware(using: FakeHelper(firmware: [5, 21, 3225, 0]).perform)
        XCTAssertEqual(firmware, "5.21.3225.0")
        XCTAssertEqual(try ProfileFormat.forWriting(firmware: firmware), .v1_0, "28-byte curves pages, not 1.1")
    }

    func testOnlyThisCapturesHelloAuthorizesAWrite() throws {
        // An earlier capture reported 5.21.3225.0, but this one has seen no HELLO.
        let firmware = try HelperRequest.capturedFirmware(using: FakeHelper(firmware: nil, earlier: [5, 21, 3225, 0]).perform)
        XCTAssertNil(firmware)
        XCTAssertThrowsError(try ProfileFormat.forWriting(firmware: firmware)) { XCTAssertEqual($0 as? ControllerError, .firmwareUnknown) }

        // A released controller's status still shows its firmware, for display, but no write may use it.
        let released = ControllerStatus(present: true, attached: false, info: FakeHelper.info([5, 22, 16, 0]))
        XCTAssertEqual(released.info?.firmware, "5.22.16.0")
        XCTAssertNil(released.writableFirmware)
        XCTAssertEqual(ControllerStatus(present: true, attached: true, info: FakeHelper.info([5, 22, 16, 0])).writableFirmware, "5.22.16.0")
    }
}
