import SQLite3
import SwiftYrs
import XCTest

@testable import ExpoNativeCollaborativeEditor

@MainActor
final class FormattingTests: XCTestCase {
  func testLegacyManifestUpgradePreservesUpdatesAndRejectsUnknownRequirements() throws {
    let url = temporaryStoreURL()
    do {
      let session = try replica(at: url)
      try session.replaceText(with: "Retain pending work")
      waitUntil { session.isSavedOnThisPhone }
    }
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE documents ADD COLUMN feature_manifest TEXT NOT NULL DEFAULT '[]'",
      nil, nil, nil), SQLITE_OK)
    let reopened = try replica(at: url)
    XCTAssertEqual(reopened.text, "Retain pending work")
    XCTAssertEqual(try reopened.pendingOperations().count, 1)
    // Reopen after the other connection's DDL; do not use SQLite's cached pre-migration schema.
    XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE documents ADD COLUMN feature_manifest TEXT NOT NULL DEFAULT '[\"unknown@1\"]'",
      nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try DocumentStore(url: url))
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, "SELECT feature_manifest FROM documents", -1, &statement, nil)
    XCTAssertEqual(prepared, SQLITE_OK)
    guard prepared == SQLITE_OK else { return }
    defer { sqlite3_finalize(statement) }
    let step = sqlite3_step(statement)
    XCTAssertEqual(step, SQLITE_ROW)
    guard step == SQLITE_ROW else { return }
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "[\"unknown@1\"]")
  }

  func testConfigurationValidationAndAtomicReconfiguration() throws {
    let session = try replica()
    try session.setPlugins(formattingPlugins())
    try session.replaceText(with: "Keep this")
    session.selection = 0..<4
    try session.toggleBold()
    waitUntil { session.isSavedOnThisPhone }
    let before = session.snapshot
    let operations = try session.pendingOperations()
    let valid = formattingRegistration()
    let invalid: [[[String: Any]]] = [
      [valid, valid],
      [valid, formattingRegistration(id: "other")],
      [formattingRegistration(capability: "not-in-native-build")],
      [formattingRegistration(version: 2)],
      [formattingRegistration(options: ["bold": 1])],
      [formattingRegistration(options: ["italic": NSNull()])],
      [formattingRegistration(options: ["headingLevels": [1, 7]])],
      [formattingRegistration(options: ["headingLevels": [true]])],
      [formattingRegistration(options: ["headingLevels": [1.5]])],
      [formattingRegistration(options: ["unknown": true])],
    ]
    for registrations in invalid {
      XCTAssertThrowsError(try session.setPlugins(FeaturePlugins(registrations: registrations))) {
        XCTAssertTrue($0 is EditorConfigurationError)
      }
      XCTAssertEqual(session.snapshot, before)
      XCTAssertEqual(try session.pendingOperations(), operations)
    }
    try session.setPlugins(formattingPlugins(options: ["bold": false, "headingLevels": [3, 1, 3]]))
    XCTAssertThrowsError(try session.toggleBold())
    XCTAssertThrowsError(try session.setHeading(2))
    try session.setHeading(3)
    XCTAssertEqual(session.selectedFormatting.heading, 3)
    try session.setPlugins(FeaturePlugins())
    let disabledSnapshot = session.snapshot
    waitUntil { session.isSavedOnThisPhone }
    let disabledOperations = try session.pendingOperations()
    XCTAssertThrowsError(try session.toggleItalic())
    XCTAssertEqual(session.snapshot, disabledSnapshot)
    XCTAssertEqual(try session.pendingOperations(), disabledOperations)
    // Disabling authoring preserves every undo/redo entry, not just canUndo.
    try session.undo()
    XCTAssertEqual(session.text, before.text)
    XCTAssertEqual(session.snapshot.marks, before.marks)
    XCTAssertEqual(session.featureManifest, ["formatting.bold@1", "formatting.heading@1"])
    try session.undo()
    XCTAssertNil(session.snapshot.marks)
    try session.redo()
    XCTAssertEqual(session.text, before.text)
    XCTAssertEqual(session.snapshot.marks, before.marks)
  }

  func testFormattingCommandsPublishMixedSelectionAndPreserveManifestAfterUndoAndRestart() throws {
    let url = temporaryStoreURL()
    let session = try replica(at: url)
    try session.setPlugins(formattingPlugins())
    try session.replaceText(with: "Bold plain\nHeading\nBody")
    session.selection = 0..<4
    try session.toggleBold()
    XCTAssertEqual(session.selectedFormatting.bold, true)
    session.selection = 0..<10
    XCTAssertNil(session.selectedFormatting.bold)
    XCTAssertEqual(session.selectedFormatting.italic, false)
    session.selection = 12..<14
    try session.setHeading(2)
    XCTAssertEqual(session.snapshot.formatting(at: 11).heading, 2)
    XCTAssertEqual(session.snapshot.formatting(at: 17).heading, 2)
    XCTAssertEqual(session.snapshot.formatting(at: 19).heading, 0)
    XCTAssertEqual(session.text, "Bold plain\nHeading\nBody")
    try session.undo()
    XCTAssertEqual(session.snapshot.formatting(at: 11).heading, 0)
    XCTAssertEqual(session.featureManifest, ["formatting.bold@1", "formatting.heading@1"])
    waitUntil { session.isSavedOnThisPhone }
    let reopened = try replica(at: url)
    XCTAssertEqual(reopened.snapshot, session.snapshot)
    XCTAssertEqual(reopened.featureManifest, session.featureManifest)
    XCTAssertFalse(reopened.canUndo)
  }

  func testMarkUpdateContainsOnlyTheSelectedRetainNotTextReplacement() throws {
    let session = try replica()
    try session.setPlugins(formattingPlugins())
    try session.replaceText(with: String(repeating: "x", count: 20_000))
    session.selection = 10_000..<10_003
    try session.toggleBold()
    waitUntil { session.isSavedOnThisPhone }
    let updates = try session.pendingOperations().map(\.update)
    XCTAssertEqual(try replicaDelta(applying: updates), [.retain(10_000), .retain(3, attributes: ["bold": .bool(true)])])
    XCTAssertLessThan(updates[1].count, 200)
    XCTAssertEqual(session.text, String(repeating: "x", count: 20_000))
    XCTAssertEqual(session.snapshot.marks, [SemanticMark(offset: 10_000, length: 3, formatting: TextFormatting(bold: true))])
  }

  func testTypingAttributesDoNotWriteUntilInsertionAndCanBeTurnedOff() throws {
    let session = try replica()
    try session.setPlugins(formattingPlugins())
    try session.toggleBold()
    try session.toggleItalic()
    try session.setHeading(1)
    XCTAssertTrue(try session.pendingOperations().isEmpty)
    XCTAssertFalse(session.canUndo)
    try session.replaceText(in: 0..<0, with: "Hi 👍")
    session.selection = 5..<5
    XCTAssertEqual(session.snapshot.marks, [SemanticMark(offset: 0, length: 5,
      formatting: TextFormatting(bold: true, italic: true, heading: 1))])
    try session.toggleBold()
    try session.toggleItalic()
    try session.setHeading(0)
    try session.replaceText(in: 5..<5, with: " plain")
    XCTAssertEqual(session.snapshot.formatting(at: 5), TextFormatting())
    session.selection = 1..<2
    try session.toggleBold()
    session.selection = 0..<session.text.utf16.count
    XCTAssertNil(session.selectedFormatting.bold)
    session.selection = 4..<5 // Inside the emoji's surrogate pair.
    let before = session.snapshot
    XCTAssertThrowsError(try session.toggleItalic())
    XCTAssertEqual(session.snapshot, before)
  }

  func testConcurrentMarkAndDeletionRetainFeatureRequirementsOnEveryReplica() throws {
    let replicas = try (0..<3).map { try replica(clientID: UInt64($0 + 1)) }
    let harness = DeliveryHarness(seed: 8, faults: .unreliable)
    for session in replicas {
      try session.setPlugins(formattingPlugins())
      try harness.connect(session)
    }
    try replicas[0].replaceText(with: "Gone")
    waitUntil { replicas[0].isSavedOnThisPhone }
    try harness.runUntilIdle()
    try replicas[0].replaceText(with: "")
    replicas[1].selection = 0..<4
    try replicas[1].toggleBold()
    waitUntil { replicas.allSatisfy(\.isSavedOnThisPhone) }
    try harness.runUntilIdle()
    let expected = SemanticSnapshot(text: "", features: ["formatting.bold@1"])
    for (index, session) in replicas.enumerated() {
      XCTAssertEqual(session.snapshot, expected, "replica \(index)")
    }
  }

  func testConcurrentFormattingAndTextConvergeWithDifferentPluginOptions() throws {
    for seed: UInt64 in 1...20 {
      var random = SeededGenerator(seed: seed)
      let harness = DeliveryHarness(seed: seed, faults: .unreliable)
      let urls = (0..<3).map { _ in temporaryStoreURL() }
      let replicas = try urls.enumerated().map { try replica(at: $1, clientID: UInt64($0 + 1)) }
      for session in replicas {
        try session.setPlugins(formattingPlugins())
        try harness.connect(session)
      }
      try replicas[0].replaceText(with: "Alpha bravo\nCharlie delta\nEcho")
      waitUntil { replicas[0].isSavedOnThisPhone }
      try harness.runUntilIdle()
      try replicas[2].setPlugins(FeaturePlugins())
      for _ in 0..<60 {
        let index = Int.random(in: 0..<3, using: &random)
        let session = replicas[index]
        let length = session.text.utf16.count
        let start = Int.random(in: 0...length, using: &random)
        let end = Int.random(in: start...min(length, start + 5), using: &random)
        session.selection = start..<end
        switch Int.random(in: 0..<5, using: &random) {
        case 0 where index != 2: try session.toggleBold()
        case 1 where index != 2: try session.toggleItalic()
        case 2 where index != 2: try session.setHeading(Int.random(in: 0...3, using: &random))
        case 3:
          try session.replaceText(in: start..<end, with: ["x", "", "Y\n"].randomElement(using: &random)!)
        default: try harness.tick()
        }
        waitUntil { session.isSavedOnThisPhone }
      }
      try harness.runUntilIdle()
      let expected = replicas[0].snapshot
      for (index, session) in replicas.enumerated() {
        XCTAssertEqual(session.snapshot, expected, "seed \(seed), replica \(index)")
        XCTAssertFalse(session.hasPendingSynchronization, "seed \(seed), replica \(index)")
      }
      harness.redeliverEverything()
      try harness.runUntilIdle()
      for (index, session) in replicas.enumerated() {
        XCTAssertEqual(session.snapshot, expected, "seed \(seed), replica \(index) after replay")
        XCTAssertEqual(try replica(at: urls[index]).snapshot, expected, "seed \(seed), replica \(index) reopened")
      }
    }
  }
}

func formattingRegistration(id: String = "formatting", capability: String = "formatting", version: Int = 1,
  options: [String: Any] = [:]) -> [String: Any] {
  ["id": id, "capability": capability, "version": version, "options": options]
}

func formattingPlugins(options: [String: Any] = [:]) throws -> FeaturePlugins {
  try FeaturePlugins(registrations: [formattingRegistration(options: options)])
}
