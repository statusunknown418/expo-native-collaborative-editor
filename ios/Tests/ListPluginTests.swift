import Combine
import XCTest

@testable import ExpoNativeCollaborativeEditor

@MainActor
final class ListPluginTests: XCTestCase {
  func testInvalidConfigurationLeavesContentPendingOperationsAndHistoryUnchanged() throws {
    let session = try replica()
    try session.setPlugins(listsPlugins())
    try session.replaceText(with: "Keep\n")
    session.selection = 0..<0
    try session.setListKind(.checklist, itemID: "keep")
    try session.toggleChecklistItem("keep")
    try session.undo()
    waitUntil { session.isSavedOnThisPhone }
    let before = session.snapshot
    let operations = try session.pendingOperations()
    let invalid: [[[String: Any]]] = [
      [listsRegistration(), listsRegistration()],
      [listsRegistration(), listsRegistration(id: "another")],
      [listsRegistration(), formattingRegistration(id: "lists")],
      [listsRegistration(capability: "missing")],
      [listsRegistration(version: 2)],
      [listsRegistration(options: ["unknown": true])],
      [listsRegistration(options: ["ordered": 1])],
      [listsRegistration(options: ["unordered": "true"])],
      [listsRegistration(options: ["checklist": NSNull()])],
      [listsRegistration(options: ["caution__enableChecklistChildrenAutoCompletion": 0])],
      [["id": "lists", "capability": "lists", "version": true, "options": [:]]],
    ]
    for registrations in invalid {
      XCTAssertThrowsError(try session.setPlugins(FeaturePlugins(registrations: registrations))) {
        XCTAssertTrue($0 is EditorConfigurationError)
      }
      XCTAssertEqual(session.snapshot, before)
      XCTAssertEqual(try session.pendingOperations(), operations)
      XCTAssertTrue(session.canUndo)
      XCTAssertTrue(session.canRedo)
    }
    try session.redo()
    XCTAssertEqual(session.snapshot.listItems?.first?.checked, true)
    try session.undo()
    XCTAssertEqual(session.snapshot, before)
    try session.undo()
    XCTAssertNil(session.snapshot.listItems)
    try session.redo()
    XCTAssertEqual(session.snapshot, before)
  }

  func testDisabledAuthoringKeepsContentAndExistingChecklistTogglesIndependent() throws {
    let session = try replica()
    try session.setPlugins(listsPlugins())
    try session.replaceText(with: "Parent\nChild\n")
    session.selection = 0..<0
    try session.setListKind(.checklist, itemID: "parent")
    session.selection = 7..<7
    try session.setListKind(.checklist, itemID: "child")
    try session.indentListItem()
    let before = session.snapshot
    try session.setPlugins(listsPlugins(options: ["ordered": false, "unordered": false, "checklist": false]))
    XCTAssertEqual(session.snapshot, before)
    for kind in ListKind.allCases {
      XCTAssertThrowsError(try session.setListKind(kind))
    }
    XCTAssertEqual(session.snapshot, before)
    try session.setPlugins(FeaturePlugins())
    XCTAssertEqual(session.snapshot, before)
    XCTAssertThrowsError(try session.setListKind(.checklist))
    try session.toggleChecklistItem("parent")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, false])
    try session.toggleChecklistItem("child")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, true])
    try session.toggleChecklistItem("parent")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [false, true])
    try session.undo()
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, true])
  }

  func testMixedDescendantCascadeIsOneDurableUndoableActionWithAuthoringDisabled() throws {
    let url = temporaryStoreURL()
    let seeded = try listReplica([
      ("Ancestor", .checklist, "ancestor", 0), ("Parent", .checklist, "parent", 1),
      ("Ordered", .ordered, "ordered", 2), ("Under ordered", .checklist, "ordered-task", 3),
      ("Unordered", .unordered, "unordered", 2), ("Deep", .checklist, "deep", 3),
      ("Sibling", .checklist, "sibling", 1), ("Other", .checklist, "other", 0),
    ], at: url)
    waitUntil { seeded.isSavedOnThisPhone }
    let storage = DispatchQueue(label: "test.cascade.storage")
    let session = try DocumentSessionRegistry(store: DocumentStore(url: url, queue: storage))
      .session(accountNamespace: "account-a", documentID: "doc-1", plugins: listsPlugins())
    try session.toggleChecklistItem("ordered-task")
    try session.toggleChecklistItem("sibling")
    waitUntil { session.isSavedOnThisPhone }
    let before = session.snapshot
    let pending = try session.pendingOperations()
    let enabled = try listsPlugins(options: [
      "checklist": false, "caution__enableChecklistChildrenAutoCompletion": true,
    ])
    try session.setPlugins(enabled)
    XCTAssertEqual(session.snapshot, before, "enabling the option is not an action")
    XCTAssertEqual(try session.pendingOperations(), pending)
    XCTAssertTrue(session.canUndo)
    XCTAssertThrowsError(try session.setListKind(.checklist))

    var saved: [Bool] = []
    let subscription = session.$isSavedOnThisPhone.sink { saved.append($0) }
    defer { subscription.cancel() }
    storage.suspend()
    var suspended = true
    defer { if suspended { storage.resume() } }
    try session.toggleChecklistItem("parent")
    XCTAssertEqual(outline(session.snapshot), [
      "[ ] Ancestor", "  [x] Parent", "    1. Ordered", "      [x] Under ordered",
      "    - Unordered", "      [x] Deep", "  [x] Sibling", "[ ] Other",
    ])
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(saved, [true, false], "no saved acknowledgement while the commit is suspended")
    storage.resume()
    suspended = false
    waitUntil { session.isSavedOnThisPhone }
    XCTAssertEqual(saved, [true, false, true])
    let checked = session.snapshot
    let committed = try session.pendingOperations()
    XCTAssertEqual(committed.count, pending.count + 1, "one atomic outbox operation")
    let reopened = try replica(at: url)
    try reopened.setPlugins(enabled)
    XCTAssertEqual(reopened.snapshot, checked, "opening with the option does not rerun it")
    XCTAssertEqual(try reopened.pendingOperations(), committed, "opening and enabling do not queue edits")

    try session.setPlugins(listsPlugins(options: ["checklist": false]))
    try session.undo()
    XCTAssertEqual(session.snapshot, before, "one undo restores every previous checked state")
    try session.redo()
    XCTAssertEqual(session.snapshot, checked, "configuration changes preserve redo")
    try session.setPlugins(enabled)
    try session.toggleChecklistItem("parent")
    XCTAssertEqual(outline(session.snapshot), [
      "[ ] Ancestor", "  [ ] Parent", "    1. Ordered", "      [ ] Under ordered",
      "    - Unordered", "      [ ] Deep", "  [x] Sibling", "[ ] Other",
    ])
    try session.undo()
    XCTAssertEqual(session.snapshot, checked)
    try session.undo()
    XCTAssertEqual(session.snapshot, before)
    try session.undo()
    XCTAssertEqual(try item("sibling", in: session).checked, false, "earlier history survives option changes")
    waitUntil { session.isSavedOnThisPhone }
  }
}

func listsRegistration(id: String = "lists", capability: String = "lists", version: Int = 1,
  options: [String: Any] = [:]) -> [String: Any] {
  ["id": id, "capability": capability, "version": version, "options": options]
}

func listsPlugins(options: [String: Any] = [:]) throws -> FeaturePlugins {
  try FeaturePlugins(registrations: [listsRegistration(options: options)])
}
