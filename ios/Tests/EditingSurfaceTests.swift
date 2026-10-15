import Combine
import SwiftUI
import SwiftYrs
import UIKit
import XCTest

@testable import ExpoNativeCollaborativeEditor

@MainActor
final class EditingSurfaceTests: XCTestCase {
  func testFormattingCommandsAndTypingAttributesReachTheNativeSurface() throws {
    let session = try replica()
    try session.setPlugins(formattingPlugins())
    let surface = Surface(session: session)
    let view = surface.textView
    try session.toggleBold()
    try session.toggleItalic()
    try session.setHeading(1)
    view.insertText("Title")
    XCTAssertEqual(session.snapshot.marks, [
      SemanticMark(offset: 0, length: 5, formatting: TextFormatting(bold: true, italic: true, heading: 1))
    ])
    let font = try XCTUnwrap(view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains([.traitBold, .traitItalic]))
    XCTAssertGreaterThan(font.pointSize, UIFont.preferredFont(forTextStyle: .body).pointSize)
    view.selectedRange = NSRange(location: 0, length: 5)
    try session.toggleBold()
    XCTAssertEqual(session.selectedFormatting.bold, false)
    try session.setPlugins(FeaturePlugins())
    surface.window.isHidden = true
    let remounted = Surface(session: session)
    let remountedFont = try XCTUnwrap(remounted.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    XCTAssertTrue(remountedFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
    XCTAssertGreaterThan(remountedFont.pointSize, UIFont.preferredFont(forTextStyle: .body).pointSize)
    try session.undo()
    XCTAssertEqual(session.snapshot.formatting(at: 0).bold, true)
    waitUntil { session.isSavedOnThisPhone }
  }

  func testRemoteFormattingOnlyUpdatePreservesSelectionAndRefreshesFonts() throws {
    let local = try replica()
    let remote = try replica()
    try remote.setPlugins(formattingPlugins())
    let harness = DeliveryHarness(seed: 8, faults: .unreliable)
    for session in [local, remote] { try harness.connect(session) }
    try local.replaceText(with: "Left right")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    let surface = Surface(session: local)
    surface.textView.selectedRange = NSRange(location: 0, length: 4)
    remote.selection = 0..<4
    try remote.toggleItalic()
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(surface.textView.selectedRange, NSRange(location: 0, length: 4))
    XCTAssertEqual(local.selectedFormatting.italic, true)
    let font = try XCTUnwrap(surface.textView.textStorage.attribute(.font, at: 1, effectiveRange: nil) as? UIFont)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    XCTAssertEqual(surface.textView.text, "Left right")
  }

  func testRemoteFormattingDuringCompositionPreservesProvisionalTypingMarks() throws {
    let local = try replica()
    let remote = try replica()
    for session in [local, remote] { try session.setPlugins(formattingPlugins()) }
    let harness = DeliveryHarness(seed: 3, faults: .none)
    for session in [local, remote] { try harness.connect(session) }
    try local.replaceText(with: "Left right")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    let surface = Surface(session: local)
    let view = surface.textView
    view.selectedRange = NSRange(location: 5, length: 0)
    try local.toggleBold()
    view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
    remote.selection = 0..<4
    try remote.toggleItalic()
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(view.text(in: try XCTUnwrap(view.markedTextRange)), "に")
    view.insertText("日本")
    XCTAssertEqual(local.text, "Left 日本right")
    XCTAssertEqual(local.snapshot.formatting(at: 5).bold, true)
    let left = try XCTUnwrap(view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    XCTAssertTrue(left.fontDescriptor.symbolicTraits.contains(.traitItalic))
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(remote.snapshot, local.snapshot)
  }

  func testMarkedTextStaysOutOfTheDocumentUntilOneIncrementalCommit() throws {
    let storage = DispatchQueue(label: "test.composition.storage")
    let session = try DocumentSessionRegistry(store: DocumentStore(url: temporaryStoreURL(), queue: storage))
      .session(accountNamespace: "input", documentID: "composition")
    try session.replaceText(with: "Left right")
    waitUntil { session.isSavedOnThisPhone }
    let seed = try session.pendingOperations().map(\.update)
    var saved: [Bool] = []
    let subscription = session.$isSavedOnThisPhone.removeDuplicates().sink { saved.append($0) }
    defer { subscription.cancel() }
    try session.acknowledge(try session.pendingOperations().map(\.operationID))
    let surface = Surface(session: session)
    let view = surface.textView
    view.selectedRange = NSRange(location: 5, length: 0)

    view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
    XCTAssertNotNil(view.markedTextRange)
    XCTAssertEqual(view.text, "Left にright")
    XCTAssertEqual(session.text, "Left right")
    XCTAssertTrue(try session.pendingOperations().isEmpty)
    XCTAssertFalse(session.isSavedOnThisPhone)
    view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
    XCTAssertEqual(session.text, "Left right")
    XCTAssertTrue(try session.pendingOperations().isEmpty)

    storage.suspend()
    view.unmarkText()
    XCTAssertNil(view.markedTextRange)
    XCTAssertEqual(view.text, "Left 日本right")
    XCTAssertEqual(session.text, "Left 日本right")
    XCTAssertEqual(saved, [true, false], "composition must not acknowledge unsaved input")
    storage.resume()
    waitUntil { session.isSavedOnThisPhone }
    XCTAssertEqual(try session.pendingOperations().count, 1)
    XCTAssertEqual(
      try replicaDelta(applying: seed + session.pendingOperations().map(\.update)),
      [.retain(5), .insert(.string("日本"))])
  }

  func testRemoteEditsPreserveMarkedTextAndItsSelection() throws {
    let cases: [(range: Range<Int>, text: String, document: String, committed: String)] = [
      (0..<0, "👋 ", "👋 Left old right", "👋 Left 日本語 right"),
      (14..<14, "!", "Left old right!", "Left 日本語 right!"),
      (5..<5, "[", "Left [old right", "Left [日本語 right"),
      (8..<8, "]", "Left old] right", "Left 日本語] right"),
      (0..<5, "", "old right", "日本語 right"),
      (8..<14, "", "Left old", "Left 日本語"),
      (0..<4, "New", "New old right", "New 日本語 right"),
      (9..<14, "end", "Left old end", "Left 日本語 end"),
    ]
    for (index, example) in cases.enumerated() {
      let local = try replica()
      let remote = try replica()
      let harness = DeliveryHarness(seed: 1, faults: .none)
      try harness.connect(local)
      try harness.connect(remote)
      try local.replaceText(with: "Left old right")
      waitUntil { local.isSavedOnThisPhone }
      try harness.runUntilIdle()
      let surface = Surface(session: local)
      let view = surface.textView
      view.selectedRange = NSRange(location: 5, length: 3)
      view.setMarkedText("日本", selectedRange: NSRange(location: 1, length: 0))

      try remote.replaceText(in: example.range, with: example.text)
      waitUntil { remote.isSavedOnThisPhone }
      try harness.runUntilIdle()
      XCTAssertEqual(local.text, example.document, "case \(index): remote edit must reach the document")
      let marked = try XCTUnwrap(view.markedTextRange, "case \(index)")
      XCTAssertEqual(view.text(in: marked), "日本", "case \(index)")
      XCTAssertEqual(view.offset(from: marked.start, to: view.selectedTextRange!.start), 1, "case \(index)")
      XCTAssertTrue(try local.pendingOperations().isEmpty, "case \(index)")
      XCTAssertFalse(local.isSavedOnThisPhone, "case \(index)")

      view.insertText("日本語")
      XCTAssertNil(view.markedTextRange)
      XCTAssertEqual(view.text, example.committed, "case \(index)")
      XCTAssertEqual(local.text, example.committed, "case \(index)")
      waitUntil { local.isSavedOnThisPhone }
      XCTAssertEqual(try local.pendingOperations().count, 1, "case \(index)")
      try harness.runUntilIdle()
      XCTAssertEqual(remote.text, example.committed, "case \(index)")
    }
  }

  func testSystemReplacementsKeepExactRangesInIncrementalTransactions() throws {
    let cases: [(before: String, range: NSRange, replacement: String, after: String, delta: [YTextDeltaOperation])] = [
      ("teh cat", NSRange(location: 0, length: 3), "the", "the cat", [.delete(3), .insert(.string("the"))]),
      ("I ca", NSRange(location: 2, length: 2), "cannot ", "I cannot ", [.retain(2), .delete(2), .insert(.string("cannot "))]),
      ("aa", NSRange(location: 0, length: 0), "a", "aaa", [.insert(.string("a"))]),
      ("🙂 cafe\u{301}", NSRange(location: 3, length: 5), "café", "🙂 café", [.retain(3), .delete(5), .insert(.string("café"))]),
    ]
    for (index, example) in cases.enumerated() {
      let session = try replica()
      try session.replaceText(with: example.before)
      waitUntil { session.isSavedOnThisPhone }
      let surface = Surface(session: session)
      let view = surface.textView
      let start = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: example.range.location))
      let end = try XCTUnwrap(view.position(from: start, offset: example.range.length))
      let range = try XCTUnwrap(view.textRange(from: start, to: end))

      view.replace(range, withText: example.replacement)
      XCTAssertEqual(view.text, example.after, "case \(index)")
      XCTAssertEqual(Array(session.text.unicodeScalars), Array(example.after.unicodeScalars), "case \(index)")
      waitUntil { session.isSavedOnThisPhone }
      let updates = try session.pendingOperations().map(\.update)
      XCTAssertEqual(updates.count, 2, "case \(index)")
      XCTAssertEqual(try replicaDelta(applying: updates), example.delta, "case \(index)")
    }
  }

  func testCancelledCompositionQueuesNothing() throws {
    let session = try replica()
    let surface = Surface(session: session)
    let view = surface.textView
    view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
    XCTAssertFalse(session.isSavedOnThisPhone)
    view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
    view.unmarkText()
    XCTAssertEqual(view.text, "")
    XCTAssertEqual(session.text, "")
    XCTAssertTrue(try session.pendingOperations().isEmpty)
    XCTAssertTrue(session.isSavedOnThisPhone)
  }

  func testScriptedReplicaDeliversWhileMarkedInputIsUnsaved() throws {
    let session = try replica()
    let scripted = try ScriptedReplica(connectingTo: session)
    try session.replaceText(with: "Left right")
    waitUntil { session.isSavedOnThisPhone && !session.hasPendingSynchronization }
    let surface = Surface(session: session)
    let view = surface.textView
    view.selectedRange = NSRange(location: 5, length: 0)
    view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
    scripted.edit(0..<0, with: "👋 ")
    withExtendedLifetime(scripted) {
      waitUntil { session.text == "👋 Left right" }
    }
    XCTAssertEqual(view.text(in: try XCTUnwrap(view.markedTextRange)), "中文")
    XCTAssertTrue(try session.pendingOperations().isEmpty)
    view.unmarkText()
    XCTAssertEqual(view.text, "👋 Left 中文right")
    XCTAssertEqual(session.text, "👋 Left 中文right")
    view.insertText("!")
    XCTAssertEqual(view.text, "👋 Left 中文!right")
    XCTAssertEqual(session.text, "👋 Left 中文!right")
    withExtendedLifetime(scripted) {
      waitUntil { session.isSavedOnThisPhone && !session.hasPendingSynchronization }
    }
  }

  func testSeveralRemoteEditsAtAnInsertionPointKeepCommittedTypingTogether() throws {
    let local = try replica()
    let remote = try replica()
    let harness = DeliveryHarness(seed: 1, faults: .none)
    try harness.connect(local)
    try harness.connect(remote)
    try local.replaceText(with: "aa")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    let surface = Surface(session: local)
    let view = surface.textView
    view.selectedRange = NSRange(location: 0, length: 0)
    view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0))
    try remote.replaceText(in: 0..<0, with: "R")
    try remote.replaceText(in: 3..<3, with: "Z")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(view.text(in: try XCTUnwrap(view.markedTextRange)), "a")
    XCTAssertTrue(try local.pendingOperations().isEmpty)

    view.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))
    view.unmarkText()
    XCTAssertEqual(view.text, "あRaaZ")
    XCTAssertEqual(local.text, "あRaaZ")
    XCTAssertEqual(view.selectedRange, NSRange(location: 1, length: 0))
    view.insertText("!")
    XCTAssertEqual(local.text, "あ!RaaZ")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(remote.text, "あ!RaaZ")
  }

  func testNativeUndoAndRedoPreserveRemoteEditsAndSynchronize() throws {
    let local = try replica()
    let remote = try replica()
    let harness = DeliveryHarness(seed: 1, faults: .none)
    try harness.connect(local)
    try harness.connect(remote)
    try remote.replaceText(with: "Base")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    let surface = Surface(session: local)
    let view = surface.textView
    let manager = try XCTUnwrap(view.undoManager)
    XCTAssertFalse(manager.canUndo, "remote text must not enter native or local history")
    view.selectedRange = NSRange(location: 4, length: 0)
    view.insertText(" local")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    try remote.replaceText(in: 0..<0, with: "Remote ")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(view.text, "Remote Base local")

    manager.undo()
    XCTAssertEqual(view.text, "Remote Base")
    XCTAssertEqual(local.text, "Remote Base")
    XCTAssertFalse(manager.canUndo)
    manager.undo()
    XCTAssertEqual(view.text, "Remote Base", "no UIKit text stack may undo remote characters")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(remote.text, "Remote Base")

    manager.redo()
    XCTAssertEqual(view.text, "Remote Base local")
    XCTAssertEqual(local.text, "Remote Base local")
    XCTAssertFalse(manager.canRedo)
    manager.redo()
    XCTAssertEqual(view.text, "Remote Base local", "redo must not replay a native text stack")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(remote.text, "Remote Base local")
  }

  func testRemountAndNativeStackClearingKeepSessionHistory() throws {
    let session = try replica()
    var surface: Surface? = Surface(session: session)
    surface!.textView.insertText("Kept")
    XCTAssertEqual(session.text, "Kept")
    surface!.textView.undoManager?.removeAllActions()
    surface!.textView.undoManager?.removeAllActions(withTarget: surface!.textView)
    XCTAssertFalse(try XCTUnwrap(surface!.textView.undoManager).isUndoRegistrationEnabled)
    surface = nil

    let remounted = Surface(session: session)
    let view = remounted.textView
    let manager = try XCTUnwrap(view.undoManager)
    XCTAssertEqual(view.text, "Kept")
    XCTAssertTrue(manager.canUndo)
    manager.undo()
    XCTAssertEqual(view.text, "")
    XCTAssertEqual(session.text, "")
    manager.redo()
    XCTAssertEqual(view.text, "Kept")
    XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 0))
    view.insertText("!")
    XCTAssertEqual(view.text, "Kept!")
    manager.undo()
    XCTAssertEqual(view.text, "Kept")
    manager.undo()
    XCTAssertEqual(view.text, "")
    XCTAssertFalse(manager.canUndo)
  }

  func testSessionHistoryCommandsPatchMountedSurfaceAndCloseDisablesEditing() throws {
    let registry = try DocumentSessionRegistry(store: DocumentStore(url: temporaryStoreURL()))
    let session = try registry.session(accountNamespace: "input", documentID: "history")
    let surface = Surface(session: session)
    let view = surface.textView
    view.insertText("Hello")

    try session.undo()
    XCTAssertEqual(view.text, "")
    XCTAssertTrue(try XCTUnwrap(view.undoManager).canRedo)
    try session.redo()
    XCTAssertEqual(view.text, "Hello")
    waitUntil { session.isSavedOnThisPhone }
    try registry.close(session)
    XCTAssertFalse(view.isEditable)
    XCTAssertFalse(try XCTUnwrap(view.undoManager).canUndo)
    XCTAssertFalse(try XCTUnwrap(view.undoManager).canRedo)
  }

  func testNativeUndoCommitsMarkedInputBeforeUndoAndRedo() throws {
    let local = try replica()
    let remote = try replica()
    let harness = DeliveryHarness(seed: 1, faults: .none)
    try harness.connect(local)
    try harness.connect(remote)
    try remote.replaceText(with: "Left right")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    let surface = Surface(session: local)
    let view = surface.textView
    let manager = try XCTUnwrap(view.undoManager)
    view.selectedRange = NSRange(location: 5, length: 0)
    view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
    try remote.replaceText(in: 0..<0, with: "👋 ")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertTrue(manager.canUndo, "provisional input must expose native undo")

    manager.undo()
    XCTAssertNil(view.markedTextRange)
    XCTAssertEqual(view.text, "👋 Left right")
    XCTAssertEqual(local.text, "👋 Left right")
    XCTAssertTrue(manager.canRedo)
    manager.redo()
    XCTAssertEqual(view.text, "👋 Left 日本right")
    XCTAssertEqual(local.text, "👋 Left 日本right")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(remote.text, "👋 Left 日本right")
  }

  func testRedoMovesCaretToTheRedoneEditAfterRemoteChanges() throws {
    let cases: [(range: Range<Int>, replacement: String, redone: String, typed: String, caret: Int)] = [
      (5..<5, "🙂", "👋 Left 🙂old right", "👋 Left 🙂!old right", 10),
      (5..<8, "🙂", "👋 Left 🙂 right", "👋 Left 🙂! right", 10),
      (5..<8, "", "👋 Left  right", "👋 Left ! right", 8),
    ]
    for (index, example) in cases.enumerated() {
      let local = try replica()
      let remote = try replica()
      let harness = DeliveryHarness(seed: 1, faults: .none)
      try harness.connect(local)
      try harness.connect(remote)
      try remote.replaceText(with: "Left old right")
      waitUntil { remote.isSavedOnThisPhone }
      try harness.runUntilIdle()
      let surface = Surface(session: local)
      let view = surface.textView
      let start = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: example.range.lowerBound))
      let end = try XCTUnwrap(view.position(from: start, offset: example.range.count))
      view.replace(try XCTUnwrap(view.textRange(from: start, to: end)), withText: example.replacement)
      let manager = try XCTUnwrap(view.undoManager)
      manager.undo()
      waitUntil { local.isSavedOnThisPhone }
      try harness.runUntilIdle()
      try remote.replaceText(in: 0..<0, with: "👋 ")
      waitUntil { remote.isSavedOnThisPhone }
      try harness.runUntilIdle()
      view.selectedRange = NSRange(location: 0, length: 3)

      if index == 1 {
        try local.redo()
      } else {
        manager.redo()
      }
      XCTAssertEqual(view.text, example.redone, "case \(index)")
      XCTAssertEqual(view.selectedRange, NSRange(location: example.caret, length: 0), "case \(index)")
      XCTAssertEqual(local.selection, example.caret..<example.caret, "case \(index)")
      view.insertText("!")
      XCTAssertEqual(view.text, example.typed, "case \(index): typing must follow the redone edit")
      waitUntil { local.isSavedOnThisPhone }
      try harness.runUntilIdle()
      XCTAssertEqual(remote.text, example.typed, "case \(index)")
    }
  }
}

/// Hosts the same SwiftUI representable as the example, with a real first-responder UITextView.
@MainActor
private final class Surface {
  let window: UIWindow
  let textView: UITextView

  init(session: DocumentSession) {
    let controller = UIHostingController(rootView: CollaborativeTextView(session: session))
    window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    func find(_ view: UIView) -> UITextView? {
      (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first
    }
    textView = find(controller.view)!
    textView.becomeFirstResponder()
  }

  deinit {
    MainActor.assumeIsolated {
      textView.resignFirstResponder()
      window.isHidden = true
      window.rootViewController = nil
    }
  }
}
