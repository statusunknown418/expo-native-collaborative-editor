import XCTest

final class ProofScreenTests: XCTestCase {
  func testLaunchShowsEditingSurface() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.descendants(matching: .any)["editing-surface"].waitForExistence(timeout: 30))
  }
}
