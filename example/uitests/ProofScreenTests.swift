import XCTest

final class ProofScreenTests: XCTestCase {
  func testTypedTextIsSavedOnThisPhoneAndSurvivesRelaunch() {
    let app = XCUIApplication()
    // A fresh document per run; the example reads it from NSUserDefaults.
    app.launchArguments = ["-documentId", "ui-test-\(UUID().uuidString)"]
    app.launch()

    let editor = app.textViews["editing-surface"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    editor.tap()
    editor.typeText("durable42")
    XCTAssertEqual(editor.value as? String, "durable42")
    XCTAssertTrue(app.staticTexts["Saved on this phone"].waitForExistence(timeout: 10))

    // The session, not the surface, owns the document.
    app.buttons["Hide editor"].tap()
    XCTAssertFalse(editor.exists)
    app.buttons["Show editor"].tap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "durable42")

    app.terminate()
    app.launch()
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    XCTAssertEqual(editor.value as? String, "durable42")
  }
}
