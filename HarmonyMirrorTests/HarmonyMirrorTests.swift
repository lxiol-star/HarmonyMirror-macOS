import XCTest
@testable import HarmonyMirror

final class HDCCommandTests: XCTestCase {
    func testFindHDC() {
        let hdc = HDCCommand()
        // Should find hdc from DevEco Studio
        XCTAssertNotNil(hdc.hdcPath)
    }
}
