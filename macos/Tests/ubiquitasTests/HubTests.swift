import XCTest
@testable import ubiquitas

final class HubTests: XCTestCase {
    let mac = Screen(name: "mac", x: 0, y: 0, w: 1000, h: 600, online: true)
    func pc(_ x: Int, _ y: Int) -> Screen { Screen(name: "pc", x: x, y: y, w: 800, h: 450, online: true) }

    func testSnapPutsScreenFlushAgainstNearestSide() {
        XCTAssert(snap(pc(100, -900), to: [mac]) == (100, -450)) // dropped above → sits on the top edge
        XCTAssert(snap(pc(1100, 50), to: [mac]) == (1000, 50)) // gap on the right → closed
        XCTAssert(snap(pc(300, 200), to: [mac]) == (300, 600)) // overlapping → pushed out the nearest way
        XCTAssert(snap(pc(5000, 5000), to: [mac]) == (1000, 599)) // far away → still touches by a pixel
        XCTAssert(snap(pc(7, 9), to: []) == (7, 9))
    }

    func testIncomingFilesStayInDirectoryAndNeverOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(createUnique(in: dir, name: "../../etc/passwd")?.1.lastPathComponent, "passwd")
        XCTAssertEqual(createUnique(in: dir, name: "passwd")?.1.lastPathComponent, "passwd (1)")
        XCTAssertEqual(createUnique(in: dir, name: "..")?.1.lastPathComponent, "file")
        XCTAssertEqual(createUnique(in: dir, name: "a.tar.gz")?.1.lastPathComponent, "a.tar.gz")
        XCTAssertEqual(createUnique(in: dir, name: "a.tar.gz")?.1.lastPathComponent, "a.tar (1).gz")
    }
}
