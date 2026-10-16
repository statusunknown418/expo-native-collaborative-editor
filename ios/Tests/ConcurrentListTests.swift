import XCTest

@testable import ExpoNativeCollaborativeEditor

/// G4: two replicas share a nested list, each edits it without seeing the other's change, and an
/// unreliable harness delivers both. Every scenario must converge to one valid hierarchy that keeps
/// every item's text and children.
@MainActor
final class ConcurrentListTests: XCTestCase {
  private let nested: [(String, ListKind, String, Int)] = [
    ("Parent", .checklist, "parent", 0), ("Child", .unordered, "child", 1),
    ("Grandchild", .ordered, "grandchild", 2), ("Sibling", .checklist, "sibling", 1),
    ("Next", .ordered, "next", 0),
  ]

  func testIndentAndAnEditToTheIndentedItemBothApply() throws {
    let result = try converge(nested,
      local: { try select("sibling", in: $0); try $0.indentListItem() },
      remote: { try $0.replaceText(in: caret(after: "Sibling", in: $0.text), with: " edited") })
    XCTAssertEqual(outline(result), [
      "[x] Parent", "  - Child", "    1. Grandchild", "    [ ] Sibling edited", "1. Next",
    ])
    XCTAssertEqual(try parent(of: "sibling", in: result), "child")
  }

  func testConcurrentIndentAndOutdentOfOneItemPickOnePlacement() throws {
    let result = try converge(nested,
      local: { try select("sibling", in: $0); try $0.indentListItem() },
      remote: { try select("sibling", in: $0); try $0.outdentListItem() })
    XCTAssertEqual(result.text.components(separatedBy: "Sibling").count, 2, "the item's text appears once")
    XCTAssertEqual(try parent(of: "grandchild", in: result), "child")
    XCTAssertTrue(["child", nil].contains(try parent(of: "sibling", in: result)))
  }

  func testRemovingOnlyAParentPromotesAChildInsertedBeneathItConcurrently() throws {
    let result = try converge(nested,
      local: { try $0.removeListItem("child") },
      remote: {
        $0.selection = caret(after: "Grandchild", in: $0.text)
        try $0.insertReturn()
        try $0.replaceText(in: $0.selection, with: "New")
      })
    XCTAssertEqual(outline(result), [
      "[x] Parent", "  1. Grandchild", "  1. New", "  [ ] Sibling", "1. Next",
    ])
    XCTAssertEqual(try parent(of: "grandchild", in: result), "parent")
  }

  func testSplittingAnItemWhileItsSuccessorJoinsItKeepsEveryTextAndChild() throws {
    let result = try converge(nested,
      local: { $0.selection = caret(after: "Ch", in: $0.text); try $0.insertReturn() },
      remote: { try select("sibling", in: $0); try $0.deleteBackward() })
    let texts = (result.listItems ?? []).map { (result.text as NSString).substring(with: NSRange(
      location: $0.offset, length: $0.length)) }
    let moved = texts.filter { !["Parent", "Grandchild", "Next"].contains($0) }.joined(separator: "|")
    for part in ["Ch", "ild", "Sibling"] {
      XCTAssertEqual(moved.components(separatedBy: part).count, 2, "\(part) appears once: \(texts)")
    }
    XCTAssertTrue(try item("child", in: result).offset == (result.listItems?[1].offset ?? -1)
      && texts[1].hasPrefix("Ch"), "the left part keeps its identity and place: \(texts)")
    XCTAssertEqual(try parent(of: "grandchild", in: result), "child", "the left part keeps its children")
    XCTAssertTrue(texts.contains("Grandchild") && texts.contains("Parent") && texts.contains("Next"))
  }

  func testMovingASubtreeKeepsAChildAddedWithinItConcurrently() throws {
    let result = try converge(nested,
      local: { try select("child", in: $0); try $0.outdentListItem() },
      remote: {
        $0.selection = caret(after: "Grandchild", in: $0.text)
        try $0.insertReturn()
        try $0.replaceText(in: $0.selection, with: "Deep")
      })
    XCTAssertEqual(outline(result), [
      "[x] Parent", "  [ ] Sibling", "- Child", "  1. Grandchild", "  1. Deep", "1. Next",
    ])
  }

  func testConcurrentIndentsBuildMixedNestingFourLevelsDeep() throws {
    let result = try converge(nested,
      local: { try select("sibling", in: $0); try $0.indentListItem() },
      remote: {
        try select("next", in: $0)
        try $0.indentListItem()
        try $0.indentListItem()
      })
    XCTAssertEqual(outline(result), [
      "[x] Parent", "  - Child", "    1. Grandchild", "    [ ] Sibling", "      1. Next",
    ])
    XCTAssertEqual(try parent(of: "next", in: result), "sibling")
  }

  func testReturnOnAnEmptyNestedItemKeepsTextTypedIntoItConcurrently() throws {
    let result = try converge([
      ("Parent", .checklist, "parent", 0), ("", .unordered, "empty", 1),
      ("Sibling", .checklist, "sibling", 1), ("Next", .ordered, "next", 0),
    ],
      local: { try select("empty", in: $0); try $0.insertReturn() },
      remote: { try select("empty", in: $0); try $0.replaceText(in: $0.selection, with: "Typed") })
    XCTAssertEqual(outline(result), ["[x] Parent", "  [ ] Sibling", "- Typed", "1. Next"])
    XCTAssertEqual(try item("empty", in: result).length, 5)
  }

  func testChecklistCascadeConvergesWithoutCapturingConcurrentChildrenOrUndoingRemoteEdits() throws {
    let urls = (0..<3).map { _ in temporaryStoreURL() }
    let remote = try listReplica([
      ("Parent", .checklist, "parent", 0), ("Branch", .unordered, "branch", 1),
      ("Step", .ordered, "step", 2), ("Deep", .checklist, "deep", 3),
      ("Done", .checklist, "done", 1), ("Move", .unordered, "move", 1),
      ("Leaf", .checklist, "leaf", 2), ("Outside", .checklist, "outside", 0),
    ], at: urls[0], clientID: 1)
    try remote.setPlugins(listsPlugins())
    try remote.toggleChecklistItem("done")
    let local = try replica(at: urls[1], clientID: 2)
    let observer = try replica(at: urls[2], clientID: 3)
    for session in [local, observer] {
      try session.setPlugins(listsPlugins(options: ["caution__enableChecklistChildrenAutoCompletion": true]))
    }
    let replicas = [remote, local, observer]
    let harness = DeliveryHarness(seed: 11, faults: .unreliable)
    waitUntil { replicas.allSatisfy(\.isSavedOnThisPhone) }
    for session in replicas { try harness.connect(session) }
    try harness.runUntilIdle()
    for session in replicas { XCTAssertEqual(session.snapshot, remote.snapshot) }
    XCTAssertFalse(local.canUndo, "the shared hierarchy is remote history on the cascade author")

    // No delivery ticks occur between these edits: the enabled observer knows New before receiving
    // the cascade, but the cascade author does not. The disabled replica concurrently moves a
    // subtree whose leaf is being checked and edits text beneath the mixed-kind branch.
    try local.toggleChecklistItem("parent")
    observer.selection = caret(after: "Deep", in: observer.text)
    try observer.insertReturn()
    try observer.replaceText(in: observer.selection, with: "New")
    XCTAssertTrue(outline(observer.snapshot).contains("      [ ] New"))
    XCTAssertFalse(local.text.contains("New"))
    XCTAssertEqual(try item("parent", in: local).checked, true)
    XCTAssertEqual(try item("parent", in: observer).checked, false)
    try select("move", in: remote)
    try remote.outdentListItem()
    try remote.replaceText(in: caret(after: "Deep", in: remote.text), with: " edited")

    let checked = [
      "[x] Parent", "  - Branch", "    1. Step", "      [x] Deep edited", "      [ ] New",
      "  [x] Done", "- Move", "  [x] Leaf", "[ ] Outside",
    ]
    let undone = [
      "[ ] Parent", "  - Branch", "    1. Step", "      [ ] Deep edited", "      [ ] New",
      "  [x] Done", "- Move", "  [ ] Leaf", "[ ] Outside",
    ]
    func assertConverged(_ expected: [String]) throws {
      waitUntil { replicas.allSatisfy(\.isSavedOnThisPhone) }
      try harness.runUntilIdle()
      for session in replicas {
        XCTAssertEqual(outline(session.snapshot), expected)
        XCTAssertEqual(session.snapshot, local.snapshot)
        XCTAssertFalse(session.hasPendingSynchronization, "all durable receipts have arrived")
        assertValidHierarchy(session.snapshot)
      }
    }
    try assertConverged(checked)

    // A single selective undo restores the known checklist states, including the prechecked Done,
    // without removing the remote child, text edit, or subtree placement.
    try local.undo()
    XCTAssertFalse(local.canUndo)
    XCTAssertTrue(local.canRedo)
    try assertConverged(undone)
    try local.redo()
    XCTAssertTrue(local.canUndo)
    XCTAssertFalse(local.canRedo)
    try assertConverged(checked)

    harness.redeliverEverything()
    try assertConverged(checked)
    for url in urls {
      let reopened = try replica(at: url)
      XCTAssertEqual(outline(reopened.snapshot), checked)
      XCTAssertEqual(reopened.snapshot, local.snapshot)
      XCTAssertTrue(reopened.isSavedOnThisPhone)
      XCTAssertFalse(reopened.hasPendingSynchronization)
    }
  }

  /// G3: three replicas start from `nested` and make random concurrent text, mark, list-structure, and
  /// checklist edits through an unreliable harness, with recorded seeds.
  func testSeededConcurrentStructureTextMarksAndChecklistsConverge() throws {
    for seed: UInt64 in 1...20 { try convergeRandomly(seed: seed) }
  }

  private func convergeRandomly(seed: UInt64) throws {
    var random = SeededGenerator(seed: seed)
    let harness = DeliveryHarness(seed: seed, faults: .unreliable)
    let urls = (0..<3).map { _ in temporaryStoreURL() }
    let replicas = try [listReplica(nested, at: urls[0], clientID: 1)]
      + urls.dropFirst().enumerated().map { try replica(at: $1, clientID: UInt64($0 + 2)) }
    for session in replicas {
      try session.setPlugins(replicas[0].plugins)
      waitUntil { session.isSavedOnThisPhone }
      try harness.connect(session)
    }
    try harness.runUntilIdle()
    let insertions = ["a", "Zz", "e\u{301}", "👍🏽", "日本", "\n", "\n\n"]
    func offset(_ text: String, _ cluster: Int) -> Int { String(text.prefix(cluster)).utf16.count }

    for _ in 0..<150 {
      guard Int.random(in: 0..<3, using: &random) > 0 else {
        try harness.tick()
        continue
      }
      let session = replicas.randomElement(using: &random)!
      let count = session.text.count
      let start = Int.random(in: 0...count, using: &random)
      let end = Int.random(in: 0..<3, using: &random) > 0
        ? start : Int.random(in: start...min(start + 4, count), using: &random)
      let range = offset(session.text, start)..<offset(session.text, end)
      let items = session.snapshot.listItems ?? []
      session.selection = range.lowerBound..<range.lowerBound
      switch Int.random(in: 0..<12, using: &random) {
      case 0, 1: try session.replaceText(in: range, with: insertions.randomElement(using: &random)!)
      case 2:
        session.selection = range
        if Bool.random(using: &random) { try session.toggleBold() } else { try session.toggleItalic() }
      case 3: try session.setHeading(Int.random(in: 0...2, using: &random))
      case 4:
        session.selection = range
        try session.setListKind([ListKind.ordered, .unordered, .checklist, nil].randomElement(using: &random)!)
      case 5, 6: try session.indentListItem()
      case 7: try session.outdentListItem()
      case 8, 9: try session.insertReturn()
      case 10: try session.deleteBackward()
      default:
        if Bool.random(using: &random), let item = items.randomElement(using: &random) {
          try session.removeListItem(item.id, includingChildren: Bool.random(using: &random))
        } else if let item = items.filter({ $0.kind == .checklist }).randomElement(using: &random) {
          try session.toggleChecklistItem(item.id)
        }
      }
      waitUntil { session.isSavedOnThisPhone }
    }
    try harness.runUntilIdle()

    let converged = replicas[0].snapshot
    assertValidHierarchy(converged)
    print("Seed \(seed) converged: \(outline(converged))")
    for (index, session) in replicas.enumerated() {
      XCTAssertEqual(session.snapshot, converged, "seed \(seed), replica \(index)")
      XCTAssertFalse(session.hasPendingSynchronization, "seed \(seed), replica \(index)")
    }
    harness.redeliverEverything()
    try harness.runUntilIdle()
    for (index, url) in urls.enumerated() {
      XCTAssertEqual(replicas[index].snapshot, converged, "seed \(seed), replica \(index) after replay")
      let reopened = try replica(at: url)
      XCTAssertEqual(reopened.snapshot, converged, "seed \(seed), replica \(index) reopened")
      XCTAssertFalse(reopened.hasPendingSynchronization, "seed \(seed), replica \(index) reopened")
    }
  }

  /// Builds `specifications` on one replica, checks its parent, delivers it to a second replica, makes
  /// the two edits concurrently, and delivers them. Asserts that both replicas, a redelivery, and both
  /// reopened stores agree on one valid hierarchy; returns it.
  private func converge(_ specifications: [(String, ListKind, String, Int)],
    local: (DocumentSession) throws -> Void, remote: (DocumentSession) throws -> Void,
    file: StaticString = #filePath, line: UInt = #line) throws -> SemanticSnapshot {
    let harness = DeliveryHarness(seed: 1, faults: .unreliable)
    let urls = [temporaryStoreURL(), temporaryStoreURL()]
    let first = try listReplica(specifications, at: urls[0], clientID: 1)
    try first.toggleChecklistItem("parent")
    let second = try replica(at: urls[1], clientID: 2)
    try second.setPlugins(first.plugins)
    waitUntil { first.isSavedOnThisPhone }
    try harness.connect(first)
    try harness.connect(second)
    try harness.runUntilIdle()
    XCTAssertEqual(second.snapshot, first.snapshot, "the replicas start from the same list", file: file, line: line)

    try local(first)
    try remote(second)
    waitUntil { first.isSavedOnThisPhone && second.isSavedOnThisPhone }
    try harness.runUntilIdle()
    let converged = first.snapshot
    print("Converged: \(outline(converged)) in \(converged.text.debugDescription)")
    XCTAssertEqual(second.snapshot, converged, "replicas converge", file: file, line: line)
    XCTAssertEqual(first.text, converged.text, file: file, line: line)
    assertValidHierarchy(converged, file: file, line: line)
    harness.redeliverEverything()
    try harness.runUntilIdle()
    for (index, url) in urls.enumerated() {
      XCTAssertEqual([first, second][index].snapshot, converged, "replica \(index) after replay", file: file, line: line)
      let reopened = try replica(at: url)
      XCTAssertEqual(reopened.snapshot, converged, "replica \(index) reopened", file: file, line: line)
      XCTAssertFalse(reopened.hasPendingSynchronization, "replica \(index) reopened", file: file, line: line)
    }
    return converged
  }
}

/// One line per list item in document order: indentation per depth, a kind marker (checked state for
/// checklist items), and the item's text.
func outline(_ snapshot: SemanticSnapshot) -> [String] {
  (snapshot.listItems ?? []).map { item in
    let marker = switch item.kind {
    case .checklist: item.checked == true ? "[x]" : "[ ]"
    case .unordered: "-"
    case .ordered: "1."
    }
    let text = (snapshot.text as NSString).substring(with: NSRange(location: item.offset, length: item.length))
    return String(repeating: "  ", count: item.depth) + marker + " " + text
  }
}

func item(_ id: String, in snapshot: SemanticSnapshot) throws -> SemanticListItem {
  try XCTUnwrap(snapshot.listItems?.first { $0.id == id }, "no list item \(id)")
}

func parent(of id: String, in snapshot: SemanticSnapshot) throws -> String? {
  try item(id, in: snapshot).parent
}

/// Unique identities; preorder items whose parent is the nearest earlier item one level up; checked
/// state only on checklist items; each item ends at an LF or the end of the text.
func assertValidHierarchy(_ snapshot: SemanticSnapshot, file: StaticString = #filePath, line: UInt = #line) {
  let items = snapshot.listItems ?? []
  XCTAssertEqual(Set(items.map(\.id)).count, items.count, "list-item identities are unique", file: file, line: line)
  let text = Array(snapshot.text.utf16)
  var ancestors: [String] = []
  var end = 0
  for item in items {
    XCTAssertEqual(item.checked != nil, item.kind == .checklist, "\(item.id) checked state", file: file, line: line)
    XCTAssertLessThanOrEqual(item.depth, ancestors.count, "\(item.id) skips a level", file: file, line: line)
    ancestors.removeLast(max(0, ancestors.count - item.depth))
    XCTAssertEqual(item.parent, ancestors.last, "\(item.id) parent", file: file, line: line)
    ancestors.append(item.id)
    XCTAssertGreaterThanOrEqual(item.offset, end, "\(item.id) overlaps the previous item", file: file, line: line)
    XCTAssertTrue(item.offset == 0 || text[item.offset - 1] == 10, "\(item.id) starts a paragraph", file: file, line: line)
    XCTAssertTrue(item.separator == text.count || text[item.separator] == 10, "\(item.id) ends a paragraph", file: file, line: line)
    end = item.end
  }
}
