import XCTest

final class ProofScreenTests: XCTestCase {
  func testFormattingToolbarTypingSelectionRuntimeOptionsAndUndo() {
    let app = XCUIApplication()
    app.launchArguments = ["-documentId", "formatting-\(UUID().uuidString)"]
    app.launch()
    let editor = app.textViews["editing-surface"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    editor.tap()
    app.buttons["Bold"].tap()
    waitForValue("On", in: app.buttons["Bold"])
    app.buttons["Italic"].tap()
    waitForValue("On", in: app.buttons["Italic"])
    app.buttons["Heading"].tap()
    waitForValue("Level 1", in: app.buttons["Heading"])
    editor.typeText("Rich text")
    waitForValue("Rich text", in: editor)
    XCTAssertTrue(app.staticTexts["Saved on this phone"].waitForExistence(timeout: 10))
    editor.typeKey("a", modifierFlags: .command)
    app.buttons["Italic"].tap()
    waitForValue("Off", in: app.buttons["Italic"])
    app.buttons["Disable formatting"].tap()
    XCTAssertTrue(app.buttons["Enable formatting"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Bold"].isEnabled)
    waitForValue("Rich text", in: editor)
    app.buttons["Undo"].tap()
    waitForValue("On", in: app.buttons["Italic"])
    app.buttons["Hide editor"].tap()
    app.buttons["Show editor"].tap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    waitForValue("Rich text", in: editor)
    waitForValue("Level 1", in: app.buttons["Heading"])
    app.buttons["Enable formatting"].tap()
    XCTAssertTrue(app.buttons["Disable formatting"].waitForExistence(timeout: 5))
    app.buttons["Redo"].tap()
    waitForValue("Off", in: app.buttons["Italic"])
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
    XCTAssertTrue(app.staticTexts["Saved on this phone"].waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    waitForValue("Rich text", in: editor)
    editor.tap()
    editor.typeKey("a", modifierFlags: .command)
    waitForValue("On", in: app.buttons["Bold"])
    waitForValue("Off", in: app.buttons["Italic"])
    waitForValue("Level 1", in: app.buttons["Heading"])
  }

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

  func testSelectiveUndoRedoSurvivesRemountAndResetsAfterRelaunch() throws {
    let app = XCUIApplication()
    let script: [[String: Any]] = [["offset": 0, "deleteCount": 0, "text": "R"]]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: script), as: UTF8.self)
    app.launchArguments = [
      "-documentId", "ui-test-\(UUID().uuidString)",
      "-remoteEdits", json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
    ]
    app.launch()

    let editor = app.textViews["editing-surface"]
    let undo = app.buttons["Undo"]
    let redo = app.buttons["Redo"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    XCTAssertTrue(undo.exists)
    XCTAssertTrue(redo.exists)
    XCTAssertFalse(undo.isEnabled)
    XCTAssertFalse(redo.isEnabled)

    editor.tap()
    // One character is one committed replacement and one undo step.
    editor.typeText("a")
    waitForValue("a", in: editor)
    waitForEnabled(true, button: undo)
    XCTAssertTrue(app.buttons["Remote edit"].waitForExistence(timeout: 10))
    app.buttons["Remote edit"].tap()
    waitForValue("Ra", in: editor)

    undo.tap()
    waitForValue("R", in: editor)
    waitForEnabled(false, button: undo)
    waitForEnabled(true, button: redo)
    redo.tap()
    waitForValue("Ra", in: editor)
    waitForEnabled(true, button: undo)
    waitForEnabled(false, button: redo)

    undo.tap()
    waitForValue("R", in: editor)
    waitForEnabled(true, button: redo)
    app.buttons["Hide editor"].tap()
    XCTAssertFalse(editor.exists)
    app.buttons["Show editor"].tap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    waitForValue("R", in: editor)
    waitForEnabled(true, button: redo)
    editor.tap()
    redo.tap()
    waitForValue("Ra", in: editor)
    waitForEnabled(true, button: undo)
    // Keep focus: typing without another tap must follow the redone character.
    editor.typeText("!")
    waitForValue("Ra!", in: editor)
    XCTAssertTrue(app.staticTexts["Saved on this phone"].waitForExistence(timeout: 10))

    app.terminate()
    app.launch()
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    waitForValue("Ra!", in: editor)
    XCTAssertTrue(undo.exists)
    XCTAssertTrue(redo.exists)
    XCTAssertFalse(undo.isEnabled)
    XCTAssertFalse(redo.isEnabled)
  }

  func testSystemUndoGestureAndKeyboardShortcutsPreserveRemoteText() throws {
    let app = XCUIApplication()
    let script: [[String: Any]] = [["offset": 0, "deleteCount": 0, "text": "R"]]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: script), as: UTF8.self)
    app.launchArguments = [
      "-documentId", "ui-test-\(UUID().uuidString)",
      "-remoteEdits", json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
    ]
    app.launch()
    let editor = app.textViews["editing-surface"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    editor.tap()
    editor.typeText("a")
    waitForValue("a", in: editor)
    XCTAssertTrue(app.buttons["Remote edit"].waitForExistence(timeout: 10))
    app.buttons["Remote edit"].tap()
    waitForValue("Ra", in: editor)

    editor.typeKey("z", modifierFlags: .command)
    waitForValue("R", in: editor)
    editor.typeKey("z", modifierFlags: [.command, .shift])
    waitForValue("Ra", in: editor)
    // iOS's three-finger double tap invokes system undo, not the example's command button.
    editor.tap(withNumberOfTaps: 2, numberOfTouches: 3)
    waitForValue("R", in: editor)
    editor.typeKey("z", modifierFlags: [.command, .shift])
    waitForValue("Ra", in: editor)
    XCTAssertTrue(app.staticTexts["Saved on this phone"].waitForExistence(timeout: 10))
  }

  private func waitForValue(_ value: String, in editor: XCUIElement, line: UInt = #line) {
    let shown = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: editor)
    XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, line: line)
  }

  private func waitForEnabled(_ enabled: Bool, button: XCUIElement, line: UInt = #line) {
    let changed = expectation(
      for: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), evaluatedWith: button)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed, line: line)
  }
}
