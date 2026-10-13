import XCTest

// G0 baseline check; M1 adds document-session tests to this target.
final class BaselineTests: XCTestCase {
  func testRunsOnIOS26OrLater() {
    XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.operatingSystemVersion.majorVersion, 26)
  }
}
