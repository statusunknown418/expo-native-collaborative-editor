import Combine
import SwiftYrs
import XCTest

@testable import ExpoNativeCollaborativeEditor

@MainActor
final class ListTests: XCTestCase {
  func testEveryMixedKindNestingPreservesIdentityAndMovesWholeSubtrees() throws {
    for parentKind in ListKind.allCases {
      for childKind in ListKind.allCases {
        for grandchildKind in ListKind.allCases {
          let session = try listReplica([
            ("Parent", parentKind, "parent", 0),
            ("Child", childKind, "child", 1),
            ("Grandchild", grandchildKind, "grandchild", 2),
            ("Sibling", .checklist, "sibling", 0),
          ])
          XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "parent", "child", nil])
          XCTAssertEqual(session.snapshot.listItems?.map(\.kind), [parentKind, childKind, grandchildKind, .checklist])
          try select("child", in: session)
          try session.outdentListItem()
          XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["parent", "child", "grandchild", "sibling"])
          XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 0, 1, 0])
          XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, nil, "child", nil])
          try session.indentListItem()
          XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 1, 2, 0])
          XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "parent", "child", nil])
          waitUntil { session.isSavedOnThisPhone }
        }
      }
    }
  }

  func testReturnKeepsLeftIdentityCheckedStateChildrenAndMarkedSuffixAfterSubtree() throws {
    let session = try listReplica([
      ("LeftRight", .checklist, "left", 0), ("Child", .unordered, "child", 1),
      ("Grandchild", .ordered, "grandchild", 2), ("Next", .ordered, "next", 0),
    ])
    try session.toggleChecklistItem("left")
    session.selection = 4..<9
    try session.toggleBold()
    session.selection = 4..<4
    let before = session.snapshot
    var rendered = session.text
    let subscription = session.surfaceChanges.sink { edits in
      for edit in edits {
        rendered = (rendered as NSString).replacingCharacters(in:
          NSRange(location: edit.utf16Offset, length: edit.utf16Length), with: edit.replacement)
      }
    }
    defer { subscription.cancel() }
    try session.insertReturn()
    XCTAssertEqual(session.text, "Left\nChild\nGrandchild\nRight\nNext\n")
    XCTAssertEqual(rendered, session.text, "the surface must receive only incremental edits in application order")
    let items = try XCTUnwrap(session.snapshot.listItems)
    XCTAssertEqual(items.map(\.id).prefix(3), ["left", "child", "grandchild"])
    XCTAssertEqual(items.map(\.parent), [nil, "left", "child", nil, nil])
    XCTAssertEqual(items[0].checked, true)
    XCTAssertEqual(items[3].kind, .checklist)
    XCTAssertEqual(items[3].checked, false)
    XCTAssertFalse(before.listItems!.map(\.id).contains(items[3].id))
    XCTAssertEqual(session.selection, items[3].offset..<items[3].offset)
    XCTAssertTrue(session.snapshot.formatting(at: items[3].offset).bold)
    XCTAssertFalse(session.snapshot.formatting(at: 0).bold)
    let after = session.snapshot
    try session.undo()
    XCTAssertEqual(session.snapshot.text, before.text)
    XCTAssertEqual(session.snapshot.listItems, before.listItems)
    XCTAssertEqual(session.snapshot.marks, before.marks)
    try session.redo()
    XCTAssertEqual(session.snapshot, after)
    XCTAssertEqual(rendered, session.text)
  }

  func testReturnReplacesSelectedTextAndUsesUTF16Boundaries() throws {
    let session = try listReplica([("A👍🏽BC", .unordered, "item", 0)])
    session.selection = 1..<5
    try session.insertReturn()
    XCTAssertEqual(session.text, "A\nBC\n")
    let items = try XCTUnwrap(session.snapshot.listItems)
    XCTAssertEqual(items[0].id, "item")
    XCTAssertEqual(items.map(\.length), [1, 2])
    XCTAssertEqual(session.selection, 2..<2)
    session.selection = 4..<4
    try session.insertReturn()
    XCTAssertEqual(session.text, "A\nBC\n\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.length), [1, 2, 0])
  }

  func testEmptyNestedReturnMovesDescendantsBeyondRemainingSiblingsThenRootReturnExits() throws {
    let session = try listReplica([
      ("Parent", .ordered, "parent", 0), ("", .checklist, "empty", 1),
      ("Child", .unordered, "child", 2), ("Remaining", .ordered, "remaining", 1),
      ("Next", .checklist, "next", 0),
    ])
    try session.toggleChecklistItem("empty")
    try select("empty", in: session)
    try session.insertReturn()
    XCTAssertEqual(session.text, "Parent\nRemaining\n\nChild\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["parent", "remaining", "empty", "child", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "parent", nil, "empty", nil])
    XCTAssertEqual(session.snapshot.listItems?.first(where: { $0.id == "empty" })?.checked, true)
    try session.insertReturn()
    XCTAssertEqual(session.text, "Parent\nRemaining\n\nChild\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["parent", "remaining", "child", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 1, 0, 0])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "parent", nil, nil])
  }

  func testEmptyRootExitPromotesChildrenForEveryKind() throws {
    for kind in ListKind.allCases {
      let session = try listReplica([
        ("", kind, "empty", 0), ("Child", .checklist, "child", 1),
        ("Grandchild", .unordered, "grandchild", 2),
      ])
      try select("empty", in: session)
      try session.insertReturn()
      XCTAssertEqual(session.text, "\nChild\nGrandchild\n")
      XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["child", "grandchild"])
      XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 1])
      XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "child"])
      waitUntil { session.isSavedOnThisPhone }
    }
  }

  func testJoinRetainsLeftIdentityStateMarksAndBothChildGroupsInOrder() throws {
    let session = try listReplica([
      ("Left", .checklist, "left", 0), ("LC", .ordered, "left-child", 1),
      ("LG", .unordered, "left-grandchild", 2), ("Right", .ordered, "right", 0),
      ("RC", .checklist, "right-child", 1), ("RG", .unordered, "right-grandchild", 2),
      ("Next", .unordered, "next", 0),
    ])
    try session.toggleChecklistItem("left")
    let right = try item("right", in: session)
    session.selection = right.offset..<right.separator
    try session.toggleItalic()
    try select("right", in: session)
    let before = session.snapshot
    try session.deleteBackward()
    XCTAssertEqual(session.text, "LeftRight\nLC\nLG\nRC\nRG\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id),
      ["left", "left-child", "left-grandchild", "right-child", "right-grandchild", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent),
      [nil, "left", "left-child", "left", "right-child", nil])
    XCTAssertEqual(session.snapshot.listItems?.first?.checked, true)
    XCTAssertEqual(session.snapshot.listItems?.first?.kind, .checklist)
    XCTAssertTrue(session.snapshot.formatting(at: 4).italic)
    XCTAssertFalse(session.snapshot.formatting(at: 0).italic)
    XCTAssertEqual(session.selection, 4..<4)
    try session.undo()
    XCTAssertEqual(session.snapshot.text, before.text)
    XCTAssertEqual(session.snapshot.listItems, before.listItems)
    XCTAssertEqual(session.snapshot.marks, before.marks)
  }

  func testOutdentMovesOnlyTheSelectedAttributedSubtreePastRemainingSiblingBranches() throws {
    let session = try listReplica([
      ("Parent", .ordered, "parent", 0), ("Move", .checklist, "move", 1),
      ("Detail", .unordered, "detail", 2), ("Stay", .checklist, "stay", 1),
      ("Stay detail", .ordered, "stay-detail", 2), ("Next", .unordered, "next", 0),
    ])
    try session.toggleChecklistItem("move")
    let moving = try item("move", in: session)
    session.selection = moving.offset..<moving.separator
    try session.toggleBold()
    try select("move", in: session)
    let before = session.snapshot
    var changes: [TextEdit] = []
    let subscription = session.surfaceChanges.sink { changes.append(contentsOf: $0) }
    defer { subscription.cancel() }
    try session.outdentListItem()
    XCTAssertEqual(session.text, "Parent\nStay\nStay detail\nMove\nDetail\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id),
      ["parent", "stay", "stay-detail", "move", "detail", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent),
      [nil, "parent", "stay", nil, "move", nil])
    let moved = try item("move", in: session)
    XCTAssertEqual(moved.checked, true)
    XCTAssertTrue(session.snapshot.formatting(at: moved.offset).bold)
    XCTAssertFalse(session.snapshot.formatting(at: (try item("stay", in: session)).offset).bold)
    XCTAssertEqual(session.selection, moved.offset..<moved.offset)
    let movedLength = "Move\nDetail\n".utf16.count
    XCTAssertEqual(changes.reduce(0) { $0 + $1.utf16Length }, movedLength)
    XCTAssertEqual(changes.reduce(0) { $0 + $1.replacement.utf16.count }, movedLength)
    try session.undo()
    XCTAssertEqual(session.snapshot.text, before.text)
    XCTAssertEqual(session.snapshot.listItems, before.listItems)
    XCTAssertEqual(session.snapshot.marks, before.marks)
  }

  func testFirstNestedBackspaceOutdentsAndFirstRootBackspaceRemovesOnlyFormatting() throws {
    let session = try listReplica([
      ("Root", .unordered, "root", 0), ("First", .ordered, "first", 1),
      ("Grandchild", .checklist, "grandchild", 2), ("Last", .ordered, "last", 1),
    ])
    try select("first", in: session)
    try session.deleteBackward()
    XCTAssertEqual(session.text, "Root\nLast\nFirst\nGrandchild\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "root", nil, "first"])
    try select("root", in: session)
    XCTAssertTrue(try session.handleListInput(in: 0..<0, replacement: ""))
    XCTAssertEqual(session.text, "Root\nLast\nFirst\nGrandchild\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["last", "first", "grandchild"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, nil, "first"])
  }

  func testRemovingParentAndSelectedSubtreesNeverDeletesUnselectedChildren() throws {
    let specs: [(String, ListKind, String, Int)] = [
      ("Root", .ordered, "root", 0), ("Child", .checklist, "child", 1),
      ("Grandchild", .unordered, "grandchild", 2), ("Next", .ordered, "next", 0),
    ]
    let session = try listReplica(specs)
    try session.toggleChecklistItem("child")
    try session.removeListItem("root")
    XCTAssertEqual(session.text, "Child\nGrandchild\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["child", "grandchild", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 1, 0])
    XCTAssertEqual(session.snapshot.listItems?.first?.checked, true)
    try session.undo()
    try session.removeListItem("root", includingChildren: true)
    XCTAssertEqual(session.text, "Next\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["next"])
    try session.undo()
    let end = try item("grandchild", in: session).end
    session.selection = 0..<end
    try session.deleteBackward()
    XCTAssertEqual(session.text, "Next\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["next"])
    try session.undo()
    try session.replaceText(in: 0..<(try item("root", in: session).end), with: "")
    XCTAssertEqual(session.text, "Child\nGrandchild\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "child", nil])
  }

  func testNestedParentOnlyRemovalPromotesOneLevelWithoutMovingOtherBranches() throws {
    let session = try listReplica([
      ("Root", .ordered, "root", 0), ("Parent", .unordered, "parent", 1),
      ("Child", .checklist, "child", 2), ("Sibling", .checklist, "sibling", 1),
      ("Next", .ordered, "next", 0),
    ])
    try session.toggleChecklistItem("child")
    try session.removeListItem("parent")
    XCTAssertEqual(session.text, "Root\nChild\nSibling\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["root", "child", "sibling", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "root", "root", nil])
    XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 1, 1, 0])
    XCTAssertEqual(try item("child", in: session).checked, true)
    try session.undo()
    try session.removeListItem("parent", includingChildren: true)
    XCTAssertEqual(session.text, "Root\nSibling\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "root", nil])
  }

  func testRemovingListFormattingFromSeveralSelectedAncestorsPromotesEachSurvivor() throws {
    let session = try listReplica([
      ("Root", .ordered, "root", 0), ("Child", .unordered, "child", 1),
      ("Grandchild", .checklist, "grandchild", 2), ("Next", .checklist, "next", 0),
    ])
    session.selection = 0..<(try item("grandchild", in: session).offset)
    try session.setListKind(nil)
    XCTAssertEqual(session.text, "Root\nChild\nGrandchild\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["grandchild", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 0])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, nil])
  }

  func testNestedParagraphConversionExitsTheEnclosingListWithoutReparentingUnaffectedSiblings() throws {
    let session = try listReplica([
      ("Parent", .ordered, "parent", 0), ("Convert", .checklist, "convert", 1),
      ("Detail", .checklist, "detail", 2), ("Stay", .unordered, "stay", 1),
      ("Stay detail", .ordered, "stay-detail", 2), ("Next", .checklist, "next", 0),
    ])
    try session.toggleChecklistItem("detail")
    let converting = try item("convert", in: session)
    session.selection = converting.offset..<converting.separator
    try session.toggleBold()
    try select("convert", in: session)
    let before = session.snapshot
    try session.setListKind(nil)
    XCTAssertEqual(session.text, "Parent\nStay\nStay detail\nConvert\nDetail\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["parent", "stay", "stay-detail", "detail", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "parent", "stay", nil, nil])
    XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 1, 2, 0, 0])
    XCTAssertEqual(try item("detail", in: session).checked, true)
    XCTAssertTrue(session.snapshot.formatting(at: "Parent\nStay\nStay detail\n".utf16.count).bold)
    XCTAssertNil(session.snapshot.listItem(at: session.selection.lowerBound))
    try session.undo()
    XCTAssertEqual(session.snapshot, before)
    try session.redo()
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "parent", "stay", nil, nil])
  }

  func testConvertingSelectedNestedSiblingsKeepsTheirTextOrderBeyondUnaffectedBranches() throws {
    let session = try listReplica([
      ("Parent", .ordered, "parent", 0), ("One", .checklist, "one", 1),
      ("Two", .unordered, "two", 1), ("Stay", .ordered, "stay", 1),
      ("Stay detail", .checklist, "stay-detail", 2), ("Next", .checklist, "next", 0),
    ])
    session.selection = (try item("one", in: session).offset)..<(try item("stay", in: session).offset)
    try session.setListKind(nil)
    XCTAssertEqual(session.text, "Parent\nStay\nStay detail\nOne\nTwo\nNext\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["parent", "stay", "stay-detail", "next"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "parent", "stay", nil])
  }

  func testDeletingAnLFJoinsItemsAndPastedLinesSplitWithFreshIdentities() throws {
    let session = try listReplica([
      ("Root", .ordered, "root", 0), ("Child", .checklist, "child", 1),
      ("Grandchild", .unordered, "grandchild", 2),
    ])
    var rendered = session.text
    let subscription = session.surfaceChanges.sink { rendered = applying($0, to: rendered) ?? "invalid edits" }
    defer { subscription.cancel() }
    try session.replaceText(in: 4..<5, with: "")
    rendered = session.text
    XCTAssertEqual(session.text, "RootChild\nGrandchild\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["root", "grandchild"], "the left item keeps its identity")
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "root"])
    // A plain surface replacement would put "Child" above Grandchild; the new sibling follows Root's subtree.
    rendered = "Rootnew\nChild\nGrandchild\n"
    try session.replaceText(in: 4..<4, with: "new\n")
    XCTAssertEqual(session.text, "Rootnew\nGrandchild\nChild\n")
    XCTAssertEqual(rendered, session.text, "the surface receives the correction")
    let items = try XCTUnwrap(session.snapshot.listItems)
    XCTAssertEqual(items.prefix(2).map(\.id), ["root", "grandchild"])
    XCTAssertFalse(["root", "child", "grandchild"].contains(items[2].id), "pasted lines never take an existing identity")
    XCTAssertEqual(items.map(\.parent), [nil, "root", nil])
    XCTAssertEqual(items[2].kind, .ordered)
  }

  func testConversionTouchesEverySelectedParagraphWithoutAddingText() throws {
    let session = try replica()
    try session.setPlugins(listsPlugins())
    try session.replaceText(with: "One\nTwo\nThree")
    session.selection = 0..<session.text.utf16.count
    try session.setListKind(.ordered)
    XCTAssertEqual(session.text, "One\nTwo\nThree")
    let ids = try XCTUnwrap(session.snapshot.listItems).map(\.id)
    XCTAssertEqual(Set(ids).count, 3)
    XCTAssertEqual(session.snapshot.listItems?.map(\.offset), [0, 4, 8])
    XCTAssertEqual(session.snapshot.listItems?.map(\.length), [3, 3, 5])
    session.selection = 0..<4
    try session.setListKind(.checklist)
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ids)
    XCTAssertEqual(session.snapshot.listItems?.map(\.kind), [.checklist, .ordered, .ordered])
    XCTAssertEqual(session.snapshot.listItems?.first?.checked, false)
    XCTAssertNotNil(session.snapshot.listItem(at: 3), "a separator belongs to its preceding item")
    XCTAssertEqual(session.snapshot.listItem(at: 4)?.id, ids[1])
    XCTAssertEqual(session.snapshot.listItem(at: session.text.utf16.count)?.id, ids[2], "the last item ends the text")
    XCTAssertEqual(session.featureManifest, ["lists.checklist@1", "lists.ordered@1"])
  }

  func testStoredBlocksLabelOnlyLFsAndConsumerJSONOmitsAbsentFields() throws {
    let session = try listReplica([
      ("Task", .checklist, "task", 0), ("Step", .ordered, "step", 1),
      ("Bullet", .unordered, "bullet", 0),
    ])
    try session.toggleChecklistItem("task")
    session.selection = 2..<2
    try session.insertReturn()
    try session.replaceText(in: 0..<0, with: "Prefix ")
    waitUntil { session.isSavedOnThisPhone }
    let document = YDoc()
    for operation in try session.pendingOperations() { try document.apply(.v1(operation.update)) }
    let body = try document.text(named: "body")
    let order = try document.array(named: "order")
    let (chunks, keys) = try document.read {
      (try $0.chunks(from: body), try $0.valuesJSON(from: order).compactMap { $0 as? String })
    }
    var labels: [String] = []
    for chunk in chunks {
      guard case .string(let key) = chunk.attributes["block"] else { continue }
      XCTAssertEqual(chunk.insert, .string("\n"), "only an LF starts a block")
      labels.append(key)
    }
    XCTAssertEqual(labels.count, 4)
    XCTAssertEqual(Set(labels).count, labels.count, "each block key labels one LF")
    XCTAssertEqual(keys.sorted(), labels.sorted(), "every labeled block has one sibling position")
    XCTAssertEqual(try SemanticSnapshot(document: document), session.snapshot)
    let data = try JSONEncoder().encode(session.snapshot)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let items = try XCTUnwrap(json["listItems"] as? [[String: Any]])
    let task = try XCTUnwrap(items.first { $0["id"] as? String == "task" })
    XCTAssertEqual(Set(task.keys), ["id", "kind", "checked", "offset", "length", "depth"])
    XCTAssertEqual(task["checked"] as? Bool, true)
    let step = try XCTUnwrap(items.first { $0["id"] as? String == "step" })
    XCTAssertEqual(Set(step.keys), ["id", "kind", "parent", "offset", "length", "depth"])
    XCTAssertEqual(step["parent"] as? String, "task")
    let bullet = try XCTUnwrap(items.first { $0["id"] as? String == "bullet" })
    XCTAssertEqual(Set(bullet.keys), ["id", "kind", "offset", "length", "depth"])
  }

  func testOrdinaryReturnAndGraphemeBackspaceAndInputInterception() throws {
    let session = try replica()
    try session.replaceText(with: "A👨‍👩‍👧‍👦e\u{301}")
    session.selection = session.text.utf16.count..<session.text.utf16.count
    try session.deleteBackward()
    XCTAssertEqual(session.text, "A👨‍👩‍👧‍👦")
    try session.deleteBackward()
    XCTAssertEqual(session.text, "A")
    try session.insertReturn()
    XCTAssertEqual(session.text, "A\n")
    XCTAssertFalse(try session.handleListInput(in: 2..<2, replacement: "x"))
    try session.setPlugins(listsPlugins())
    session.selection = 0..<0
    try session.setListKind(.unordered, itemID: "first")
    XCTAssertTrue(try session.handleListInput(in: 1..<1, replacement: "\n"))
    XCTAssertEqual(session.text, "A\n\n")
    let second = try XCTUnwrap(session.snapshot.listItems?.last)
    XCTAssertTrue(try session.handleListInput(in: (second.offset - 1)..<second.offset, replacement: ""))
    XCTAssertEqual(session.text, "A\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["first"])
  }

  func testInvalidScalarSelectionsAndCompositionCannotPartiallyMutateLists() throws {
    let session = try listReplica([("👍🏽", .checklist, "root", 0), ("Child", .ordered, "child", 1)])
    waitUntil { session.isSavedOnThisPhone }
    let before = session.snapshot
    let operations = try session.pendingOperations()
    let commands: [() throws -> Void] = [
      { try session.setListKind(.unordered) }, { try session.indentListItem() },
      { try session.outdentListItem() }, { try session.insertReturn() },
      { try session.deleteBackward() }, { try session.removeListItem("root") },
      { try session.toggleChecklistItem("root") },
    ]
    session.selection = 1..<1
    for command in commands { XCTAssertThrowsError(try command()) }
    XCTAssertThrowsError(try session.replaceText(in: 1..<2, with: "x"))
    XCTAssertThrowsError(try session.handleListInput(in: 1..<1, replacement: "\n"))
    XCTAssertEqual(session.snapshot, before)
    session.selection = 0..<0
    session.hasMarkedText = true
    for command in commands { XCTAssertThrowsError(try command()) }
    XCTAssertFalse(try session.handleListInput(in: 0..<0, replacement: "\n"))
    XCTAssertEqual(session.snapshot, before)
    XCTAssertEqual(try session.pendingOperations(), operations)
    session.hasMarkedText = false
  }

  /// Conflicting or malformed structure projects deterministically and is never repaired on open.
  func testMalformedBlocksProjectTheSameOnEveryReplicaWithoutWrites() throws {
    let (remote, text, textState) = try malformedBlocks()
    let expected = SemanticSnapshot(text: "Head\nB\nC\nA\nA2\nE\nF\nG\nD", listItems: [
      SemanticListItem(id: "b", kind: .checklist, parent: nil, checked: false, offset: 5, length: 1, depth: 0),
      SemanticListItem(id: "c", kind: .unordered, parent: "b", checked: nil, offset: 7, length: 1, depth: 1),
      SemanticListItem(id: "a", kind: .ordered, parent: nil, checked: nil, offset: 9, length: 4, depth: 0),
      SemanticListItem(id: "dup", kind: .unordered, parent: nil, checked: nil, offset: 14, length: 1, depth: 0),
      SemanticListItem(id: "d", kind: .checklist, parent: nil, checked: false, offset: 20, length: 1, depth: 0),
    ])
    let url = temporaryStoreURL()
    let whole = try replica(at: url)
    try whole.receive(try remote.encodeStateAsUpdateV1().data, at: 1)
    let split = try replica()
    try split.receive(text.data, at: 1)
    try split.receive(try remote.encodeStateAsUpdateV1(from: textState).data, at: 2)
    XCTAssertEqual(whole.snapshot, expected)
    XCTAssertEqual(split.snapshot, expected)
    let reopened = try replica(at: url)
    XCTAssertEqual(reopened.snapshot, expected)
    for session in [whole, split, reopened] {
      XCTAssertTrue(try session.pendingOperations().isEmpty, "projection must never repair the shared document")
    }
  }

  func testStructuralCommandsPersistIncrementallyAndRestoreWithoutReplayingToggles() throws {
    let url = temporaryStoreURL()
    let session = try listReplica([
      ("Parent", .checklist, "parent", 0), ("Child", .checklist, "child", 1),
      ("Detail", .unordered, "detail", 2),
    ], at: url)
    try session.toggleChecklistItem("parent")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, false, nil])
    try session.toggleChecklistItem("child")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, true, nil])
    try session.toggleChecklistItem("child")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, false, nil])
    try select("parent", in: session)
    session.selection = 3..<3
    try session.insertReturn()
    waitUntil { session.isSavedOnThisPhone }
    let snapshot = session.snapshot
    let reopened = try replica(at: url)
    XCTAssertEqual(reopened.snapshot, snapshot)
    XCTAssertFalse(reopened.canUndo)
    XCTAssertTrue(reopened.hasPendingSynchronization)
    try session.undo()
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["parent", "child", "detail"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, false, nil])
    try session.redo()
    XCTAssertEqual(session.snapshot, snapshot)
  }
}

/// A replica whose paragraphs are list items given as (text, kind, ID, depth), in document order.
@MainActor
func listReplica(_ specifications: [(String, ListKind, String, Int)],
  at url: URL = temporaryStoreURL(), clientID: UInt64? = nil) throws -> DocumentSession {
  let session = try replica(at: url, clientID: clientID)
  try session.setPlugins(FeaturePlugins(registrations: [listsRegistration(), formattingRegistration()]))
  try session.replaceText(with: specifications.map { $0.0 + "\n" }.joined())
  var offset = 0
  for (text, kind, id, depth) in specifications {
    session.selection = offset..<offset
    try session.setListKind(kind, itemID: id)
    for _ in 0..<depth { try session.indentListItem() }
    offset += text.utf16.count + 1
  }
  return session
}

@MainActor
func item(_ id: String, in session: DocumentSession) throws -> SemanticListItem {
  try XCTUnwrap(session.snapshot.listItems?.first(where: { $0.id == id }))
}

@MainActor
func select(_ id: String, in session: DocumentSession) throws {
  let offset = try item(id, in: session).offset
  session.selection = offset..<offset
}

/// Text first, then conflicting and malformed structure: a duplicate label, a label on text, a cycle,
/// a parent that never existed, a block missing from `order` and an `order` key missing from the
/// text, a reused identity, an unknown kind, and non-boolean checked values. Also the
/// `malformed-blocks` fixture. Returns the document, its text-only update, and that update's state.
func malformedBlocks() throws -> (document: YDoc, text: YUpdate, textState: YStateVector) {
  let remote = YDoc()
  let body = try remote.text(named: "body")
  let blocks = try remote.map(named: "blocks")
  let order = try remote.array(named: "order")
  try remote.write { transaction in
    try transaction.insert("Head\nA\nA2\nB\nC\nD\nE\nF\nG", into: body, at: 0)
    for (offset, key) in [(4, "a"), (6, "a"), (9, "b"), (11, "c"), (13, "d"), (15, "e"), (17, "f"), (19, "g")] {
      try transaction.format(body, at: UInt32(offset), length: 1, attributes: ["block": .string(key)])
    }
    try transaction.format(body, at: 0, length: 4, attributes: ["block": .string("x")])
  }
  let text = try remote.encodeStateAsUpdateV1()
  let textState = try remote.stateVector()
  try remote.write { transaction in
    let fields: [(String, YValue)] = [
      ("a/kind", .string("ordered")),
      ("b/kind", .string("checklist")), ("b/parent", .string("c")), ("b/checked", .int(1)),
      ("c/kind", .string("unordered")), ("c/parent", .string("b")),
      ("d/kind", .string("checklist")), ("d/parent", .string("missing")), ("d/checked", .string("true")),
      ("e/kind", .string("unordered")), ("e/id", .string("dup")),
      ("f/kind", .string("ordered")), ("f/id", .string("dup")),
      ("g/kind", .string("bogus")),
    ]
    for (key, value) in fields { try transaction.set(value, forKey: key, in: blocks) }
    for (index, key) in ["c", "b", "a", "e", "f", "g", "ghost"].enumerated() {
      try transaction.insert(.string(key), into: order, at: UInt32(index))
    }
  }
  return (remote, text, textState)
}
