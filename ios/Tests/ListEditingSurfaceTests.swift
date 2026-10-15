import SwiftUI
import UIKit
import XCTest

@testable import ExpoNativeCollaborativeEditor

@MainActor
final class ListEditingSurfaceTests: XCTestCase {
  func testNativeReturnSplitsEveryKindAfterItsChildrenKeepingLeftIdentityAndCompletion() throws {
    for kind in ListKind.allCases {
      let session = try makeSession()
      try seed(session, [
        Line("parent", "Parent", kind, checked: kind == .checklist),
        Line("child", "Child", .checklist, depth: 1, checked: true),
        Line("other", "Other", .unordered),
      ])
      let surface = ListSurface(session: session)
      surface.textView.selectedRange = NSRange(location: 3, length: 0)
      surface.textView.insertText("\n")
      XCTAssertEqual(surface.textView.text, "Par\nChild\nent\nOther\n")
      XCTAssertEqual(session.text, surface.textView.text)
      let items = try XCTUnwrap(session.snapshot.listItems)
      XCTAssertEqual(items.prefix(2).map(\.id), ["parent", "child"])
      XCTAssertEqual(items[0].checked, kind == .checklist ? true : nil)
      XCTAssertEqual(items[1].parent, "parent")
      XCTAssertEqual(items[1].checked, true)
      XCTAssertEqual(items[2].kind, kind)
      XCTAssertNil(items[2].parent)
      XCTAssertNotEqual(items[2].id, "parent")
      XCTAssertEqual(items[2].checked, kind == .checklist ? false : nil)
      XCTAssertEqual(surface.textView.selectedRange.location, items[2].offset)
      XCTAssertEqual(items[3].id, "other")
      surface.textView.undoManager?.undo()
      XCTAssertEqual(surface.textView.text, "Parent\nChild\nOther\n")
      XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["parent", "child", "other"])
    }
  }

  func testNativeReturnOnEmptyItemOutdentsThenExitsAllKindsAndPromotesChildren() throws {
    for kind in ListKind.allCases {
      let session = try makeSession()
      try seed(session, [
        Line("root", "Root", .ordered), Line("empty", "", kind, depth: 1),
        Line("grandchild", "Grand", .checklist, depth: 2, checked: true),
      ])
      let surface = ListSurface(session: session)
      select("empty", session, surface)
      surface.textView.insertText("\n")
      XCTAssertNil(try item("empty", session).parent)
      XCTAssertEqual(try item("grandchild", session).parent, "empty")
      XCTAssertEqual(try item("grandchild", session).depth, 1)
      surface.textView.insertText("\n")
      XCTAssertNil(session.snapshot.listItems?.first { $0.id == "empty" })
      XCTAssertNil(try item("grandchild", session).parent)
      XCTAssertEqual(try item("grandchild", session).depth, 0)
      XCTAssertEqual(try item("grandchild", session).checked, true)
      XCTAssertEqual(surface.textView.text, session.text)
      XCTAssertEqual(session.text, "Root\n\nGrand\n")
    }
  }

  func testNativeBackspaceJoinsTextsAndBothChildGroupsUnderLeftItem() throws {
    let session = try makeSession()
    try seed(session, [
      Line("left", "Left", .checklist, checked: true),
      Line("left-child", "LC", .ordered, depth: 1),
      Line("right", "Right", .unordered),
      Line("right-child", "RC", .checklist, depth: 1, checked: true),
    ])
    let surface = ListSurface(session: session)
    select("right", session, surface)
    surface.textView.deleteBackward()
    XCTAssertEqual(session.text, "LeftRight\nLC\nRC\n")
    XCTAssertEqual(surface.textView.text, session.text)
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["left", "left-child", "right-child"])
    XCTAssertEqual(try item("left", session).kind, .checklist)
    XCTAssertEqual(try item("left", session).checked, true)
    XCTAssertEqual(try item("left-child", session).parent, "left")
    XCTAssertEqual(try item("right-child", session).parent, "left")
    XCTAssertEqual(try item("right-child", session).checked, true)
    XCTAssertEqual(surface.textView.selectedRange, NSRange(location: 4, length: 0))
  }

  func testNativeBackspaceAtFirstNestedItemOutdentsAndFirstRootExitsList() throws {
    let session = try makeSession()
    try seed(session, [Line("root", "Root", .ordered), Line("child", "Child", .unordered, depth: 1)])
    let surface = ListSurface(session: session)
    select("child", session, surface)
    surface.textView.deleteBackward()
    XCTAssertNil(try item("child", session).parent)
    XCTAssertEqual(session.text, "Root\nChild\n")
    select("root", session, surface)
    surface.textView.deleteBackward()
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["child"])
    XCTAssertEqual(surface.textView.text, "Root\nChild\n")
  }

  func testIndentAndOutdentMoveMixedSubtreeAndPreserveCompletionAndNativeGeometry() throws {
    let session = try makeSession()
    try seed(session, [
      Line("first", "First", .ordered), Line("parent", "Parent", .unordered),
      Line("child", "Child", .checklist, depth: 1, checked: true),
      Line("grand", "Grand", .ordered, depth: 2),
    ])
    let surface = ListSurface(session: session)
    select("parent", session, surface)
    try session.indentListItem()
    XCTAssertEqual(try item("parent", session).parent, "first")
    XCTAssertEqual(try item("child", session).parent, "parent")
    XCTAssertEqual(try item("grand", session).depth, 3)
    XCTAssertEqual(try item("child", session).checked, true)
    try session.outdentListItem()
    XCTAssertNil(try item("parent", session).parent)
    XCTAssertEqual(try item("grand", session).depth, 2)
    XCTAssertEqual(try item("child", session).checked, true)
    XCTAssertEqual(surface.textView.text, session.text)
  }

  func testUITextInputParentDeletionPromotesUnselectedChildren() throws {
    let session = try makeSession()
    try seed(session, tree)
    let surface = ListSurface(session: session)
    try replace(0..<7, in: surface.textView, with: "")
    XCTAssertEqual(session.text, "Child\nGrand\nOther\n")
    XCTAssertEqual(surface.textView.text, session.text)
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["child", "grand", "other"])
    XCTAssertNil(try item("child", session).parent)
    XCTAssertEqual(try item("grand", session).parent, "child")
    XCTAssertEqual(try item("grand", session).depth, 1)
    XCTAssertEqual(try item("child", session).checked, true)
    surface.textView.undoManager?.undo()
    XCTAssertEqual(surface.textView.text, "Parent\nChild\nGrand\nOther\n")
    XCTAssertEqual(try item("child", session).parent, "parent")
  }

  func testUITextInputSelectedParentAndDescendantsDeleteOnlySelectedSubtree() throws {
    let session = try makeSession()
    try seed(session, tree)
    let surface = ListSurface(session: session)
    try replace(0..<19, in: surface.textView, with: "")
    XCTAssertEqual(session.text, "Other\n")
    XCTAssertEqual(surface.textView.text, session.text)
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["other"])
    XCTAssertNil(try item("other", session).parent)
    surface.textView.undoManager?.undo()
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["parent", "child", "grand", "other"])
  }

  func testCheckboxHitTargetsIndependentStatesAccessibilityActionAndDisabledAuthoring() throws {
    let session = try makeSession()
    try seed(session, [
      Line("parent", "Parent", .checklist), Line("child", "Child", .checklist, depth: 1),
      Line("empty", "", .checklist),
    ])
    let surface = ListSurface(session: session)
    let parent = try surface.checkbox("parent")
    let child = try surface.checkbox("child")
    XCTAssertEqual(try surface.checkbox("empty").accessibilityLabel, "Empty checklist item")
    for button in [parent, child] {
      XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
      XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
      let point = button.convert(CGPoint(x: 2, y: 2), to: surface.window)
      XCTAssertTrue(surface.window.hitTest(point, with: nil) === button)
      XCTAssertTrue(button.accessibilityTraits.contains(.button))
      XCTAssertEqual(button.accessibilityValue, "Unchecked")
      XCTAssertEqual(button.accessibilityCustomActions?.map(\.name), ["Toggle"])
    }
    XCTAssertGreaterThan(child.frame.minX, parent.frame.minX)
    let selection = surface.textView.selectedRange
    parent.sendActions(for: .touchUpInside)
    XCTAssertEqual(try item("parent", session).checked, true)
    XCTAssertEqual(try item("child", session).checked, false)
    XCTAssertEqual(parent.accessibilityLabel, "Parent")
    XCTAssertEqual(parent.accessibilityValue, "Checked")
    XCTAssertTrue(parent.accessibilityTraits.contains(.selected))
    XCTAssertEqual(surface.textView.selectedRange, selection)
    let toggle = try XCTUnwrap(child.accessibilityCustomActions?.first)
    XCTAssertEqual(toggle.actionHandler?(toggle), true)
    XCTAssertEqual(try item("parent", session).checked, true)
    XCTAssertEqual(try item("child", session).checked, true)
    try session.setPlugins(FeaturePlugins())
    parent.sendActions(for: .touchUpInside)
    XCTAssertEqual(try item("parent", session).checked, false)
    XCTAssertEqual(try item("child", session).checked, true)
    XCTAssertTrue(surface.textView.isFirstResponder)
  }

  func testRemoteMarkOnlyUpdatesAndCompositionRefreshCheckboxesWithoutReplacingInput() throws {
    let local = try makeSession()
    let remote = try makeSession()
    let harness = DeliveryHarness(seed: 9, faults: .none)
    for session in [local, remote] { try harness.connect(session) }
    try seed(local, [Line("parent", "Parent", .checklist), Line("child", "Child", .checklist, depth: 1)])
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    let surface = ListSurface(session: local)
    surface.textView.selectedRange = NSRange(location: 2, length: 0)
    try remote.toggleChecklistItem("parent")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(try surface.checkbox("parent").accessibilityValue, "Checked")
    XCTAssertEqual(try surface.checkbox("child").accessibilityValue, "Unchecked")
    XCTAssertEqual(surface.textView.selectedRange, NSRange(location: 2, length: 0))
    surface.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
    try remote.toggleChecklistItem("child")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(surface.textView.text(in: try XCTUnwrap(surface.textView.markedTextRange)), "に")
    surface.textView.insertText("日本")
    XCTAssertNil(surface.textView.markedTextRange)
    XCTAssertEqual(local.text, "Pa日本rent\nChild\n")
    XCTAssertEqual(try surface.checkbox("child").accessibilityValue, "Checked")
    XCTAssertEqual(try surface.checkbox("parent").accessibilityLabel, "Pa日本rent")
  }

  func testCheckboxGeometryFollowsScrollingResizeAndDynamicType() throws {
    let session = try makeSession()
    try seed(session, (0..<25).map { Line("item-\($0)", "Task \($0)", .checklist) })
    let surface = ListSurface(session: session)
    let first = try surface.checkbox("item-0")
    let manager = try XCTUnwrap(surface.textView.textLayoutManager)
    let content = try XCTUnwrap(manager.textContentManager)
    let start = content.documentRange.location
    let end = try XCTUnwrap(content.location(start, offsetBy: 1))
    let glyphRange = try XCTUnwrap(NSTextRange(location: start, end: end))
    var baseline: CGFloat?
    manager.enumerateTextSegments(in: glyphRange, type: .standard, options: []) {
      _, _, value, _ in
      baseline = value
      return false
    }
    let original = first.frame.minY
    let initialFont = try XCTUnwrap(surface.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    XCTAssertEqual(first.frame.midY,
      try XCTUnwrap(baseline) + surface.textView.textContainerInset.top - initialFont.capHeight / 2, accuracy: 1)
    surface.textView.contentOffset.y = 100
    surface.window.layoutIfNeeded()
    XCTAssertEqual(first.frame.minY, original - 100, accuracy: 1)
    surface.window.frame.size.width = 300
    surface.window.rootViewController?.view.setNeedsLayout()
    surface.window.layoutIfNeeded()
    let controller = try XCTUnwrap(surface.window.rootViewController)
    controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    controller.view.layoutIfNeeded()
    let largerFont = try XCTUnwrap(surface.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    XCTAssertGreaterThan(largerFont.pointSize, initialFont.pointSize)
    for button in surface.buttons {
      XCTAssertGreaterThanOrEqual(button.frame.width, 44)
      XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    }
    XCTAssertEqual(surface.textView.text, session.text)
  }

  private var tree: [Line] {
    [Line("parent", "Parent", .ordered), Line("child", "Child", .checklist, depth: 1, checked: true),
      Line("grand", "Grand", .unordered, depth: 2), Line("other", "Other", .ordered)]
  }

  private struct Line {
    let id: String
    let text: String
    let kind: ListKind
    let depth: Int
    let checked: Bool

    init(_ id: String, _ text: String, _ kind: ListKind, depth: Int = 0, checked: Bool = false) {
      self.id = id
      self.text = text
      self.kind = kind
      self.depth = depth
      self.checked = checked
    }
  }

  private func makeSession() throws -> DocumentSession {
    let session = try replica()
    try session.setPlugins(FeaturePlugins(registrations: [
      ["id": "lists", "capability": "lists", "version": 1, "options": [String: Any]()],
    ]))
    return session
  }

  private func seed(_ session: DocumentSession, _ lines: [Line]) throws {
    try session.replaceText(with: lines.map(\.text).joined(separator: "\n") + "\n")
    var offset = 0
    for line in lines {
      session.selection = offset..<offset
      try session.setListKind(line.kind, itemID: line.id)
      for _ in 0..<line.depth { try session.indentListItem() }
      if line.checked { try session.toggleChecklistItem(line.id) }
      offset += line.text.utf16.count + 1
    }
  }

  private func item(_ id: String, _ session: DocumentSession) throws -> SemanticListItem {
    try XCTUnwrap(session.snapshot.listItems?.first { $0.id == id })
  }

  private func select(_ id: String, _ session: DocumentSession, _ surface: ListSurface) {
    let offset = session.snapshot.listItems!.first { $0.id == id }!.offset
    surface.textView.selectedRange = NSRange(location: offset, length: 0)
  }

  private func replace(_ range: Range<Int>, in view: UITextView, with text: String) throws {
    view.selectedRange = NSRange(range)
    let start = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: range.lowerBound))
    let end = try XCTUnwrap(view.position(from: start, offset: range.count))
    view.replace(try XCTUnwrap(view.textRange(from: start, to: end)), withText: text)
  }
}

@MainActor
private final class ListSurface {
  let window: UIWindow
  let textView: UITextView

  init(session: DocumentSession) {
    let controller = UIHostingController(rootView: CollaborativeTextView(session: session))
    window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    textView = Self.descendants(controller.view).compactMap { $0 as? UITextView }.first!
    textView.becomeFirstResponder()
    controller.view.layoutIfNeeded()
  }

  var buttons: [UIButton] { Self.descendants(window).compactMap { $0 as? UIButton } }

  func checkbox(_ id: String) throws -> UIButton {
    try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "checklist-\(id)" })
  }

  private static func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  deinit {
    MainActor.assumeIsolated {
      textView.resignFirstResponder()
      window.isHidden = true
      window.rootViewController = nil
    }
  }
}
