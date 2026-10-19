import XCTest
import EliteIPC
import EliteKit

/// Stands in for the helper: like the real one after a fresh start, it
/// knows the firmware only once a capture has seen the controller's HELLO.
final class FakeHelper {
    private let hello: [UInt8]
    private var attached = false

    /// `firmware` is the HELLO's four version numbers.
    init(firmware: [UInt16]) {
        hello = [UInt8](repeating: 0, count: 12) + firmware.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [UInt8](repeating: 1, count: 8)
    }

    func perform(_ request: HelperRequest) throws -> HelperReply {
        if case .attach = request { attached = true }
        return .status(ControllerStatus(present: true, attached: attached, info: attached ? DeviceInfo(hello: hello) : nil))
    }
}

final class HelperRequestTests: XCTestCase {
    func testFirmwareIsAskedForAfterCapturing() throws {
        let firmware = try HelperRequest.capturedFirmware(using: FakeHelper(firmware: [5, 21, 3225, 0]).perform)
        XCTAssertEqual(firmware, "5.21.3225.0")
        XCTAssertEqual(try ProfileFormat.forWriting(firmware: firmware), .v1_0, "28-byte curves pages, not 1.1")
    }
}
