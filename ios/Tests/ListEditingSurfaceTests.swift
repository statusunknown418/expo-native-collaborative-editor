import SwiftUI
import UIKit
import XCTest

@testable import ExpoNativeCollaborativeEditor

@MainActor
final class ListEditingSurfaceTests: XCTestCase {
  func testNativeHyphenSpaceCreatesEmptyUnorderedItemForTypingAndUITextInputReplacement() throws {
    for useReplacement in [false, true] {
      let session = try makeSession()
      let surface = ListSurface(session: session)
      let view = surface.textView
      view.insertText("-")
      if useReplacement {
        try replace(1..<1, in: view, with: " ")
      } else {
        view.insertText(" ")
      }
      XCTAssertEqual(session.text, "")
      XCTAssertEqual(view.text, "")
      XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
      XCTAssertEqual(session.selection, 0..<0)
      let items = try XCTUnwrap(session.snapshot.listItems)
      XCTAssertEqual(items.count, 1)
      let item = try XCTUnwrap(items.first)
      XCTAssertFalse(item.id.isEmpty)
      XCTAssertEqual(item.kind, .unordered)
      XCTAssertEqual(item.offset, 0)
      XCTAssertEqual(item.length, 0)
      XCTAssertEqual(item.depth, 0)
      XCTAssertNil(item.parent)
      surface.window.layoutIfNeeded()
      XCTAssertEqual(surface.labels.map(\.text), ["-"])
      view.insertText("Task")
      XCTAssertEqual(session.text, "Task")
      XCTAssertEqual(view.text, "Task")
      XCTAssertEqual(session.snapshot.listItems?.map(\.id), [item.id])
      XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 0))
    }
  }

  func testNativeHyphenSpacePreservesMarkedSuffixCaretAndSelectiveUndoRedo() throws {
    let session = try makeSession()
    try session.setPlugins(FeaturePlugins(registrations: [
      ["id": "lists", "capability": "lists", "version": 1, "options": [String: Any]()],
      ["id": "formatting", "capability": "formatting", "version": 1, "options": [String: Any]()],
    ]))
    try session.replaceText(with: "Above\n-Tail\nAfter")
    session.selection = 7..<11
    try session.toggleBold()
    try session.toggleItalic()
    let surface = ListSurface(session: session)
    let view = surface.textView
    view.selectedRange = NSRange(location: 7, length: 0)
    view.insertText(" ")
    XCTAssertEqual(session.text, "Above\nTail\nAfter")
    XCTAssertEqual(view.text, session.text)
    XCTAssertEqual(view.selectedRange, NSRange(location: 6, length: 0))
    let items = try XCTUnwrap(session.snapshot.listItems)
    XCTAssertEqual(items.count, 1)
    let item = try XCTUnwrap(items.first)
    XCTAssertEqual(item.kind, .unordered)
    XCTAssertEqual(item.offset, 6)
    XCTAssertEqual(item.length, 4)
    XCTAssertEqual(session.snapshot.marks, [
      SemanticMark(offset: 6, length: 4, formatting: TextFormatting(bold: true, italic: true)),
    ])
    let font = try XCTUnwrap(view.textStorage.attribute(.font, at: 6, effectiveRange: nil) as? UIFont)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains([.traitBold, .traitItalic]))
    let converted = session.snapshot
    let undo = try XCTUnwrap(view.undoManager)
    undo.undo()
    XCTAssertEqual(session.text, "Above\n- Tail\nAfter")
    XCTAssertEqual(view.text, session.text)
    XCTAssertNil(session.snapshot.listItems)
    XCTAssertEqual(session.snapshot.marks, [
      SemanticMark(offset: 8, length: 4, formatting: TextFormatting(bold: true, italic: true)),
    ])
    undo.redo()
    XCTAssertEqual(session.snapshot, converted)
    XCTAssertEqual(view.text, "Above\nTail\nAfter")
    XCTAssertEqual(view.selectedRange, NSRange(location: 6, length: 0))
  }

  func testConvertedItemUsesNativeReturnAndBackspaceRules() throws {
    let session = try makeSession()
    let surface = ListSurface(session: session)
    let view = surface.textView
    view.insertText("-")
    view.insertText(" ")
    let firstID = try XCTUnwrap(session.snapshot.listItems?.first?.id)
    view.insertText("Task")
    view.insertText("\n")
    XCTAssertEqual(view.text, "Task\n")
    let items = try XCTUnwrap(session.snapshot.listItems)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].id, firstID)
    XCTAssertNotEqual(items[1].id, firstID)
    XCTAssertEqual(items.map(\.kind), [.unordered, .unordered])
    XCTAssertEqual(view.selectedRange, NSRange(location: 5, length: 0))
    view.insertText("\n")
    XCTAssertEqual(session.text, "Task\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), [firstID])
    view.selectedRange = NSRange(location: 0, length: 0)
    view.deleteBackward()
    XCTAssertEqual(session.text, "Task\n")
    XCTAssertEqual(view.text, session.text)
    XCTAssertNil(session.snapshot.listItems)

    let empty = try makeSession()
    let emptySurface = ListSurface(session: empty)
    emptySurface.textView.insertText("-")
    emptySurface.textView.insertText(" ")
    XCTAssertNotNil(empty.snapshot.listItems?.first)
    emptySurface.textView.deleteBackward()
    XCTAssertEqual(empty.text, "")
    XCTAssertEqual(emptySurface.textView.text, "")
    XCTAssertNil(empty.snapshot.listItems)
    XCTAssertEqual(emptySurface.textView.selectedRange, NSRange(location: 0, length: 0))
  }

  func testNativeHyphenSpaceRemainsLiteralWithoutUnorderedAuthoring() throws {
    for plugins in [
      FeaturePlugins(),
      try FeaturePlugins(registrations: [
        ["id": "lists", "capability": "lists", "version": 1, "options": ["unordered": false]],
      ]),
    ] {
      let session = try replica()
      try session.setPlugins(plugins)
      let surface = ListSurface(session: session)
      surface.textView.insertText("-")
      surface.textView.insertText(" ")
      XCTAssertEqual(session.text, "- ")
      XCTAssertEqual(surface.textView.text, "- ")
      XCTAssertNil(session.snapshot.listItems)
      XCTAssertEqual(surface.textView.selectedRange, NSRange(location: 2, length: 0))
    }
  }

  func testNativeHyphenSpaceDoesNotConvertCompositionIncludingItsCommit() throws {
    for commitWithInsertion in [false, true] {
      let session = try makeSession()
      let surface = ListSurface(session: session)
      let view = surface.textView
      view.insertText("-")
      view.setMarkedText(" ", selectedRange: NSRange(location: 1, length: 0))
      XCTAssertNotNil(view.markedTextRange)
      XCTAssertEqual(view.text, "- ")
      XCTAssertEqual(session.text, "-")
      XCTAssertNil(session.snapshot.listItems)
      if commitWithInsertion {
        view.insertText(" ")
      } else {
        view.unmarkText()
      }
      XCTAssertNil(view.markedTextRange)
      XCTAssertEqual(session.text, "- ")
      XCTAssertEqual(view.text, "- ")
      XCTAssertNil(session.snapshot.listItems)
      XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 0))
    }
  }

  func testNativeHyphenSpaceRejectsPasteOtherPrefixesSelectionsAndExistingItems() throws {
    let cases: [(String, Range<Int>, String, String)] = [
      ("", 0..<0, "- ", "- "),
      ("a-", 2..<2, " ", "a- "),
      ("--", 2..<2, " ", "-- "),
      (" -", 2..<2, " ", " - "),
      ("*", 1..<1, " ", "* "),
      ("+", 1..<1, " ", "+ "),
      ("1.", 2..<2, " ", "1. "),
      ("–", 1..<1, " ", "– "),
      ("-", 1..<1, "\u{00a0}", "-\u{00a0}"),
      ("-X", 1..<2, " ", "- "),
      ("- ", 0..<2, " ", " "),
    ]
    for (text, range, insertion, expected) in cases {
      let session = try makeSession()
      try session.replaceText(with: text)
      let surface = ListSurface(session: session)
      surface.textView.selectedRange = NSRange(range)
      surface.textView.insertText(insertion)
      XCTAssertEqual(session.text, expected, "Input: \(text.debugDescription)")
      XCTAssertEqual(surface.textView.text, expected)
      XCTAssertNil(session.snapshot.listItems)
    }
    for kind in ListKind.allCases {
      let session = try makeSession()
      try seed(session, [Line("existing", "-", kind)], trailingLF: false)
      let surface = ListSurface(session: session)
      surface.textView.selectedRange = NSRange(location: 1, length: 0)
      surface.textView.insertText(" ")
      XCTAssertEqual(session.text, "- ")
      XCTAssertEqual(surface.textView.text, "- ")
      XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["existing"])
      XCTAssertEqual(session.snapshot.listItems?.map(\.kind), [kind])
    }
  }

  func testUnorderedHyphensAndCaretMatchOrdinaryTextWithoutChangingDocumentOnRemount() throws {
    let session = try makeSession()
    try session.replaceText(with: "Added\nAdded")
    var surface = ListSurface(session: session)
    let plain = try [5, 11].map { try caretAndBaseline(in: surface.textView, at: $0) }
    session.selection = 0..<11
    try session.setListKind(.unordered)
    let snapshot = session.snapshot
    let selection = session.selection
    let canUndo = session.canUndo
    let canRedo = session.canRedo
    waitUntil { session.isSavedOnThisPhone }
    var updates = 0
    let changes = session.surfaceChanges.sink { _ in updates += 1 }
    defer { changes.cancel() }
    surface = ListSurface(session: session)
    XCTAssertEqual(session.snapshot, snapshot)
    XCTAssertEqual(session.selection, selection)
    XCTAssertEqual(surface.textView.selectedRange, NSRange(selection))
    XCTAssertEqual(session.canUndo, canUndo)
    XCTAssertEqual(session.canRedo, canRedo)
    XCTAssertEqual(updates, 0)
    XCTAssertEqual(surface.labels.map(\.text), ["-", "-"])
    var previous: CGRect?
    for (index, offset) in [5, 11].enumerated() {
      let (caret, baseline) = try caretAndBaseline(in: surface.textView, at: offset)
      XCTAssertEqual(caret.height, plain[index].0.height, accuracy: 1)
      XCTAssertEqual(baseline - caret.minY, plain[index].1 - plain[index].0.minY, accuracy: 1)
      if let previous { XCTAssertGreaterThanOrEqual(caret.minY, previous.maxY) }
      previous = caret
    }
    surface.textView.undoManager?.undo()
    XCTAssertEqual(session.text, "Added\nAdded")
    XCTAssertNil(session.snapshot.listItems)
    surface.textView.undoManager?.redo()
    XCTAssertEqual(session.snapshot, snapshot)
  }

  func testListFirstLineMarkersAndNativeCaretsSurviveWrappingNestingResizeScrollAndDynamicType() throws {
    let session = try makeSession()
    try seed(session, [
      Line("empty", "", .checklist),
      Line("wrapped", String(repeating: "Added ", count: 12), .unordered, depth: 1),
      Line("ordered", "Added", .ordered),
      Line("final", "Added", .unordered, depth: 1),
    ], trailingLF: false)
    let snapshot = session.snapshot
    let surface = ListSurface(session: session)
    let textView = surface.textView
    let controller = try XCTUnwrap(surface.window.rootViewController)
    for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
      controller.traitOverrides.preferredContentSizeCategory = category
      for width in [CGFloat(393), 300] {
        surface.window.frame.size.width = width
        controller.view.setNeedsLayout()
        surface.window.layoutIfNeeded()
        for scroll in [CGFloat(0), 60] {
          textView.contentOffset.y = scroll
          surface.window.layoutIfNeeded()
          XCTAssertEqual(surface.labels.map(\.text), ["-", "1.", "-"])
          let markers: [UIView] = [try surface.checkbox("empty")] + surface.labels
          var rootX: CGFloat?
          for (item, marker) in zip(try XCTUnwrap(session.snapshot.listItems), markers) {
            let start = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: item.offset))
            let firstCaret = textView.caretRect(for: start)
            let (_, baseline) = try caretAndBaseline(in: textView, at: item.offset + 1)
            let font = try XCTUnwrap(textView.textStorage.attribute(.font, at: item.offset, effectiveRange: nil) as? UIFont)
            let frame = marker.convert(marker.bounds, to: textView)
            XCTAssertEqual(frame.midY, baseline - font.capHeight / 2, accuracy: 1)
            XCTAssertLessThanOrEqual(frame.maxX, firstCaret.minX)
            if item.depth == 0 { rootX = firstCaret.minX }
            if item.depth == 1 {
              XCTAssertGreaterThan(firstCaret.minX, try XCTUnwrap(rootX))
            }
            let (endCaret, _) = try caretAndBaseline(in: textView, at: item.offset + item.length)
            let ordinary = UITextView()
            ordinary.frame = textView.bounds
            ordinary.font = font
            ordinary.text = "Added"
            ordinary.layoutIfNeeded()
            let reference = ordinary.caretRect(for: ordinary.endOfDocument)
            XCTAssertEqual(firstCaret.height, reference.height, accuracy: 2)
            XCTAssertEqual(endCaret.height, reference.height, accuracy: 2)
            if item.id == "wrapped" {
              XCTAssertGreaterThan(endCaret.minY, firstCaret.maxY)
              XCTAssertGreaterThanOrEqual(endCaret.minX, firstCaret.minX - 1)
            }
          }
          let checkbox = try surface.checkbox("empty")
          XCTAssertGreaterThanOrEqual(checkbox.bounds.width, 44)
          XCTAssertGreaterThanOrEqual(checkbox.bounds.height, 44)
          XCTAssertEqual(session.snapshot, snapshot)
          XCTAssertEqual(textView.text, snapshot.text)
        }
      }
    }
  }

  private func caretAndBaseline(in textView: UITextView, at offset: Int) throws -> (CGRect, CGFloat) {
    let position = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: offset))
    textView.selectedRange = NSRange(location: offset, length: 0)
    let caret = textView.caretRect(for: position)
    let manager = try XCTUnwrap(textView.textLayoutManager)
    let content = try XCTUnwrap(manager.textContentManager)
    let start = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: max(0, offset - 1)))
    let end = try XCTUnwrap(content.location(start, offsetBy: 1))
    let range = try XCTUnwrap(NSTextRange(location: start, end: end))
    var baseline: CGFloat?
    manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, value, _ in
      baseline = rect.minY + value + textView.textContainerInset.top
      return false
    }
    return (caret, try XCTUnwrap(baseline))
  }

  func testEmptyFinalListItemsKeepIndentedCaretAndVisibleMarker() throws {
    for kind in ListKind.allCases {
      let session = try makeSession()
      try seed(session, [Line("root", "Added", .unordered), Line("empty", "", kind, depth: 1)],
        trailingLF: false)
      let surface = ListSurface(session: session)
      let textView = surface.textView
      let caret = textView.caretRect(for: textView.endOfDocument)
      let root = textView.caretRect(for: textView.beginningOfDocument)
      XCTAssertEqual(caret.minX, root.minX + 28, accuracy: 1)
      XCTAssertEqual(caret.height, root.height, accuracy: 1)
      let marker: UIView = kind == .checklist
        ? try surface.checkbox("empty") : try XCTUnwrap(surface.labels.last)
      XCTAssertFalse(marker.isHidden)
      let frame = marker.convert(marker.bounds, to: textView)
      XCTAssertEqual(frame.maxX, caret.minX, accuracy: 1)
      XCTAssertTrue(frame.intersects(caret.insetBy(dx: -1, dy: 0)))
      textView.insertText("Added")
      XCTAssertEqual(session.text, "Added\nAdded")
      XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["root", "empty"])
      textView.undoManager?.undo()
      XCTAssertEqual(session.text, "Added\n")
      XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["root", "empty"])
    }
  }

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

  func testAFinalItemWithoutATrailingLFRendersWhenItArrivesRemotely() throws {
    let local = try makeSession()
    let remote = try makeSession()
    let harness = DeliveryHarness(seed: 3, faults: .none)
    try harness.connect(local)
    try harness.connect(remote)
    let surface = ListSurface(session: local)
    try remote.replaceText(with: "Plan\nTask")
    remote.selection = 5..<5
    try remote.setListKind(.checklist, itemID: "task")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertEqual(surface.textView.text, "Plan\nTask")
    let style = surface.textView.textStorage.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(style?.firstLineHeadIndent, 44)
    XCTAssertEqual(try surface.checkbox("task").accessibilityValue, "Unchecked")
  }

  private func makeSession() throws -> DocumentSession {
    let session = try replica()
    try session.setPlugins(FeaturePlugins(registrations: [
      ["id": "lists", "capability": "lists", "version": 1, "options": [String: Any]()],
    ]))
    return session
  }

  private func seed(_ session: DocumentSession, _ lines: [Line], trailingLF: Bool = true) throws {
    try session.replaceText(with: lines.map(\.text).joined(separator: "\n") + (trailingLF ? "\n" : ""))
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
  var labels: [UILabel] {
    Self.descendants(window).compactMap { $0 as? UILabel }.filter { !$0.isAccessibilityElement }
      .sorted { $0.frame.minY < $1.frame.minY }
  }

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
