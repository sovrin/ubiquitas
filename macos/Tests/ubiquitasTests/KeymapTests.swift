import XCTest
@testable import ubiquitas

final class KeymapTests: XCTestCase {
    /// Keys from a client are replayed with macKey, keys to a client are sent with evdevKey: both must agree.
    func testEveryMappedKeyRoundTrips() {
        for mac in UInt16(0) ... 0x7F {
            if let code = evdevKey(mac) { XCTAssertEqual(macKey(code), mac, "mac keycode \(mac)") }
        }
        XCTAssertNil(macKey(BTN_LEFT))
    }
}
