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

  func testDeletingSeparatorPromotesSurvivorsAndInsertedTextDoesNotAcquireIdentity() throws {
    let session = try listReplica([
      ("Root", .ordered, "root", 0), ("Child", .checklist, "child", 1),
      ("Grandchild", .unordered, "grandchild", 2),
    ])
    try session.replaceText(in: 4..<5, with: "")
    XCTAssertEqual(session.text, "RootChild\nGrandchild\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["child", "grandchild"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "child"])
    try session.replaceText(in: 4..<4, with: "new\n")
    XCTAssertEqual(session.text, "Rootnew\nChild\nGrandchild\n")
    XCTAssertNil(session.snapshot.listItem(at: 0))
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["child", "grandchild"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "child"])
    try session.replaceText(in: 8..<8, with: "Pasted\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["child", "grandchild"])
    XCTAssertNil(session.snapshot.listItem(at: 8))
  }

  func testConversionTouchesEverySelectedParagraphAndMaterializesOnlyRealFinalLF() throws {
    let session = try replica()
    try session.setPlugins(listsPlugins())
    try session.replaceText(with: "One\nTwo\nThree")
    session.selection = 0..<session.text.utf16.count
    try session.setListKind(.ordered)
    XCTAssertEqual(session.text, "One\nTwo\nThree\n")
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
    XCTAssertNil(session.snapshot.listItem(at: session.text.utf16.count))
    XCTAssertEqual(session.featureManifest, ["lists.checklist@1", "lists.ordered@1"])
  }

  func testPersistedRepresentationAndConsumerJSONUseOnlyRealSeparatorsAndOptionalFields() throws {
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
    let body = try document.text(named: "body")
    for operation in try session.pendingOperations() { try document.apply(.v1(operation.update)) }
    let chunks = try document.read { try $0.chunks(from: body) }
    var storedIDs: Set<String> = []
    for chunk in chunks {
      if case .string(let id) = chunk.attributes["listID"] {
        guard case .string(let text) = chunk.insert else {
          XCTFail("list semantics require an LF text separator")
          continue
        }
        XCTAssertEqual(text, "\n")
        XCTAssertTrue(storedIDs.insert(id).inserted, "an item ID must occur on exactly one separator")
      }
    }
    XCTAssertEqual(storedIDs, Set(session.snapshot.listItems!.map(\.id)))
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

  func testProjectionClampsMalformedRemoteDepthsAndIgnoresDuplicateAndOrdinarySeparators() throws {
    let remote = YDoc()
    let body = try remote.text(named: "body")
    try remote.write { transaction in
      try transaction.insert("One\nTwo\nDuplicate\nPlain\nThree\nFour\n", into: body, at: 0)
      let specifications: [(Int, String, YValue)] = [
        (3, "one", .int(100)), (7, "two", .double(1e30)), (17, "one", .int(0)),
        (29, "three", .int(7)), (34, "four", .double(1.5)),
      ]
      for (offset, id, depth) in specifications {
        try transaction.format(body, at: UInt32(offset), length: 1, attributes: [
          "listID": .string(id), "listKind": .string("checklist"), "listDepth": depth,
          "listChecked": .string("not-a-boolean"),
        ])
      }
      // Attributes on visible text alone are not a list item.
      try transaction.format(body, at: 18, length: 5, attributes: [
        "listID": .string("not-a-separator"), "listKind": .string("ordered"), "listDepth": .int(0),
      ])
    }
    let update = try remote.encodeStateAsUpdateV1()
    let session = try replica()
    try session.receive(update.data, at: 1)
    XCTAssertEqual(session.text, "One\nTwo\nDuplicate\nPlain\nThree\nFour\n")
    XCTAssertEqual(session.snapshot.listItems?.map(\.id), ["one", "two", "three"])
    XCTAssertEqual(session.snapshot.listItems?.map(\.depth), [0, 1, 0])
    XCTAssertEqual(session.snapshot.listItems?.map(\.parent), [nil, "one", nil])
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [false, false, false])
    XCTAssertTrue(try session.pendingOperations().isEmpty, "projection must never repair the shared document")
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

@MainActor
private func listReplica(_ specifications: [(String, ListKind, String, Int)],
  at url: URL = temporaryStoreURL()) throws -> DocumentSession {
  let session = try replica(at: url)
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
private func item(_ id: String, in session: DocumentSession) throws -> SemanticListItem {
  try XCTUnwrap(session.snapshot.listItems?.first(where: { $0.id == id }))
}

@MainActor
private func select(_ id: String, in session: DocumentSession) throws {
  let offset = try item(id, in: session).offset
  session.selection = offset..<offset
}
