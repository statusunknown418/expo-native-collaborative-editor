import XCTest

@testable import ExpoNativeCollaborativeEditor

@MainActor
final class ListPluginTests: XCTestCase {
  func testNativeCapabilitiesAndStrictAtomicConfigurationPreserveHistory() throws {
    let capability = try XCTUnwrap(FeaturePlugins.capabilities["lists"] as? [String: Any])
    XCTAssertEqual(capability["version"] as? Int, 1)
    for kind in ["ordered", "unordered", "checklist"] {
      XCTAssertEqual(capability[kind] as? Bool, true)
    }
    let defaults = try XCTUnwrap(try listsPlugins().lists)
    XCTAssertTrue(defaults.ordered)
    XCTAssertTrue(defaults.unordered)
    XCTAssertTrue(defaults.checklist)
    XCTAssertFalse(defaults.caution__enableChecklistChildrenAutoCompletion)

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

  func testChecklistCascadeRequiresExplicitOption() throws {
    let session = try replica()
    try session.setPlugins(listsPlugins())
    try session.replaceText(with: "Parent\nChild\n")
    session.selection = 0..<0
    try session.setListKind(.checklist, itemID: "parent")
    session.selection = 7..<7
    try session.setListKind(.checklist, itemID: "child")
    try session.indentListItem()
    try session.toggleChecklistItem("child")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [false, true])
    try session.setPlugins(listsPlugins(options: ["caution__enableChecklistChildrenAutoCompletion": true]))
    try session.toggleChecklistItem("parent")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, true])
    try session.toggleChecklistItem("parent")
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [false, false])
    try session.undo()
    XCTAssertEqual(session.snapshot.listItems?.map(\.checked), [true, true])
  }
}

func listsRegistration(id: String = "lists", capability: String = "lists", version: Int = 1,
  options: [String: Any] = [:]) -> [String: Any] {
  ["id": id, "capability": capability, "version": version, "options": options]
}

func listsPlugins(options: [String: Any] = [:]) throws -> FeaturePlugins {
  try FeaturePlugins(registrations: [listsRegistration(options: options)])
}
