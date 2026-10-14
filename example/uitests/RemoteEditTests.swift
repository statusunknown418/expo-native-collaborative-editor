import XCTest

/// A scripted remote replica edits the document through the delivery harness while a person types.
final class RemoteEditTests: XCTestCase {
  func testRemoteEditsKeepTheCaretAtItsLogicalPosition() {
    let family = "👨‍👩‍👧‍👦 "
    let app = launch(remoteEdits: [
      (offset: 0, deleteCount: 0, text: family),  // Before the caret.
      (offset: (family + "Hello1").utf16.count, deleteCount: 0, text: " 🌍"),  // At the caret.
      (offset: (family + "Hello12 🌍").utf16.count, deleteCount: 0, text: "!"),  // After the caret.
      (offset: (family + "Hel").utf16.count, deleteCount: "lo123 🌍".utf16.count, text: ""),  // Spanning it.
    ])
    let editor = app.textViews["editing-surface"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    editor.tap()
    editor.typeText("Hello")

    remoteEdit(app, expecting: family + "Hello")
    editor.typeText("1")
    XCTAssertEqual(editor.value as? String, family + "Hello1")

    remoteEdit(app, expecting: family + "Hello1 🌍")
    editor.typeText("2")
    XCTAssertEqual(editor.value as? String, family + "Hello12 🌍")

    remoteEdit(app, expecting: family + "Hello12 🌍!")
    editor.typeText("3")
    XCTAssertEqual(editor.value as? String, family + "Hello123 🌍!")

    remoteEdit(app, expecting: family + "Hel!")
    editor.typeText("4")
    XCTAssertEqual(editor.value as? String, family + "Hel4!")
  }

  func testRemoteEditsOutsideTheVisibleAreaKeepTheScrollPosition() {
    let lines = (1...300).map { "Line \($0)" }.joined(separator: "\n")
    let above = "Remote line above\n"
    let app = launch(remoteEdits: [
      (offset: 0, deleteCount: 0, text: lines),
      (offset: 0, deleteCount: 0, text: above),
      (offset: (above + lines).utf16.count, deleteCount: 0, text: "\nRemote line below"),
    ])
    let editor = app.textViews["editing-surface"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    remoteEdit(app, expecting: lines)
    // Scroll into the middle without focusing the editor, then let the scroll indicator fade.
    let top = editor.screenshot().pngRepresentation
    editor.swipeUp(velocity: .slow)
    editor.swipeUp(velocity: .slow)
    Thread.sleep(forTimeInterval: 3)
    let scrolled = editor.screenshot().pngRepresentation
    XCTAssertNotEqual(scrolled, top, "the swipes did not scroll")

    remoteEdit(app, expecting: above + lines)
    XCTAssertEqual(editor.screenshot().pngRepresentation, scrolled, "an edit above the visible area moved it")
    remoteEdit(app, expecting: above + lines + "\nRemote line below")
    XCTAssertEqual(editor.screenshot().pngRepresentation, scrolled, "an edit below the visible area moved it")
  }

  /// Launches the example on a fresh document with a remote replica that makes `remoteEdits`, one per
  /// tap on "Remote edit". Offsets and counts are UTF-16 code units in the replica's text.
  private func launch(remoteEdits: [(offset: Int, deleteCount: Int, text: String)]) -> XCUIApplication {
    let script = remoteEdits.map { edit -> [String: Any] in
      ["offset": edit.offset, "deleteCount": edit.deleteCount, "text": edit.text]
    }
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: script), as: UTF8.self)
    let app = XCUIApplication()
    app.launchArguments = [
      "-documentId", "ui-test-\(UUID().uuidString)",
      "-remoteEdits", json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
    ]
    app.launch()
    return app
  }

  /// Triggers the replica's next edit and waits until the editing surface shows `expected`.
  private func remoteEdit(_ app: XCUIApplication, expecting expected: String, line: UInt = #line) {
    app.buttons["Remote edit"].tap()
    let shown = expectation(
      for: NSPredicate(format: "value == %@", expected), evaluatedWith: app.textViews["editing-surface"])
    XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, "never showed \(expected)", line: line)
  }
}
