import Combine
import SQLite3
import SwiftYrs
import XCTest

@testable import ExpoNativeCollaborativeEditor

@MainActor
final class DocumentSessionTests: XCTestCase {
  func testTypedTextIsRestoredAfterReopeningTheStore() throws {
    let url = temporaryStoreURL()
    do {
      let session = try DocumentSessionRegistry(store: DocumentStore(url: url))
        .session(accountNamespace: "account-a", documentID: "doc-1")
      try session.replaceText(with: "Hello")
      try session.replaceText(with: "Hello, phone")
      waitUntil { session.isSavedOnThisPhone }
    }

    let reopened = try DocumentSessionRegistry(store: DocumentStore(url: url))
      .session(accountNamespace: "account-a", documentID: "doc-1")
    XCTAssertEqual(reopened.text, "Hello, phone")
  }

  func testReopeningADocumentNeitherSeedsNorQueuesContent() throws {
    let url = temporaryStoreURL()
    let expected = DocumentMetadata(
      key: DocumentKey(accountNamespace: "account-a", documentID: "doc-1", lifecycleGeneration: 1),
      schemaID: "yrs-update-v1/plain-text-0")
    do {
      let store = try DocumentStore(url: url)
      let created = try DocumentSessionRegistry(store: store)
        .session(accountNamespace: "account-a", documentID: "doc-1")
      XCTAssertEqual(created.metadata, expected)
      XCTAssertEqual(try store.outbox(for: expected.key), [])
    }

    let store = try DocumentStore(url: url)
    let reopened = try DocumentSessionRegistry(store: store)
      .session(accountNamespace: "account-a", documentID: "doc-1")
    XCTAssertEqual(reopened.metadata, expected)
    XCTAssertEqual(reopened.text, "")
    XCTAssertEqual(try store.outbox(for: expected.key), [])
  }

  func testOneCharacterEditInTheLargeFixtureProducesAnUpdateCoveringOnlyThatEdit() throws {
    let store = try DocumentStore(url: temporaryStoreURL())
    let session = try DocumentSessionRegistry(store: store)
      .session(accountNamespace: "account-a", documentID: "doc-1")
    let fixture = twentyThousandCharacterFixture
    XCTAssertEqual(fixture.count, 20_000)
    let middle = fixture.index(fixture.startIndex, offsetBy: 10_000)
    var edited = fixture
    edited.insert("x", at: middle)

    try session.replaceText(with: fixture)
    try session.replaceText(with: edited)
    waitUntil { session.isSavedOnThisPhone }

    let updates = try store.outbox(for: session.metadata.key).map(\.update)
    XCTAssertEqual(updates.count, 2)
    XCTAssertEqual(
      try replicaDelta(applying: updates),
      [.retain(UInt32(fixture[..<middle].utf16.count)), .insert(.string("x"))])
    // Room for the item's IDs and one character, not for any of the other 20,000.
    XCTAssertLessThan(updates[1].count, 100)
  }

  func testEditsWithinGraphemeClustersReplaceWholeClusters() throws {
    let store = try DocumentStore(url: temporaryStoreURL())
    let registry = DocumentSessionRegistry(store: store)
    // Yrs reports a replacement as delete-then-insert.
    let cases: [(before: String, after: String, delta: [YTextDeltaOperation])] = [
      // 👍🏻 and 👍🏽 share their first three UTF-16 code units.
      ("a👍🏻b", "a👍🏽b", [.retain(1), .delete(4), .insert(.string("👍🏽"))]),
      // Extending a ZWJ sequence: 👨‍👩‍👧 to 👨‍👩‍👧‍👦.
      (
        "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b",
        "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}b",
        [.retain(1), .delete(8), .insert(.string("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"))]
      ),
      // A combining mark joins the preceding letter's cluster.
      ("cafe", "cafe\u{301}", [.retain(3), .delete(1), .insert(.string("e\u{301}"))]),
      // Canonically equivalent clusters with different scalars and UTF-16 lengths.
      ("cafe\u{301}!", "caf\u{E9}!", [.retain(3), .delete(2), .insert(.string("\u{E9}"))]),
    ]

    for (index, example) in cases.enumerated() {
      let session = try registry.session(accountNamespace: "account-a", documentID: "grapheme-\(index)")
      try session.replaceText(with: example.before)
      try session.replaceText(with: example.after)
      waitUntil { session.isSavedOnThisPhone }

      let updates = try store.outbox(for: session.metadata.key).map(\.update)
      XCTAssertEqual(try replicaDelta(applying: updates), example.delta, "case \(index)")
      XCTAssertEqual(Array(session.text.unicodeScalars), Array(example.after.unicodeScalars), "case \(index)")
    }
  }

  func testSavedOnThisPhoneIsPublishedOnlyAfterTheCommit() throws {
    let url = temporaryStoreURL()
    let storage = DispatchQueue(label: "test.storage")
    let session = try DocumentSessionRegistry(store: DocumentStore(url: url, queue: storage))
      .session(accountNamespace: "account-a", documentID: "doc-1")
    var published: [Bool] = []
    let subscription = session.$isSavedOnThisPhone.sink { published.append($0) }
    defer { subscription.cancel() }

    storage.suspend()
    try session.replaceText(with: "Durable")
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(published, [true, false])

    storage.resume()
    waitUntil { session.isSavedOnThisPhone }
    XCTAssertEqual(published, [true, false, true])
    let fromDisk = try DocumentSessionRegistry(store: DocumentStore(url: url))
      .session(accountNamespace: "account-a", documentID: "doc-1")
    XCTAssertEqual(fromDisk.text, "Durable")
  }

  func testAFailedCommitKeepsLaterCommitsFromAcknowledgingTheDocument() throws {
    let url = temporaryStoreURL()
    let storage = DispatchQueue(label: "test.storage")
    let session = try DocumentSessionRegistry(store: DocumentStore(url: url, queue: storage))
      .session(accountNamespace: "account-a", documentID: "doc-1")
    // Another connection holding the write lock makes the next commit fail with SQLITE_BUSY.
    var writer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
    defer { sqlite3_close(writer) }
    XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
    try session.replaceText(with: "Lost")
    storage.sync {}
    XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)

    try session.replaceText(with: "Lost, then committed")
    storage.sync {}
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertFalse(session.isSavedOnThisPhone)
  }

  func testAProcessSharesOneSessionPerDocument() throws {
    let registry = DocumentSessionRegistry(store: try DocumentStore(url: temporaryStoreURL()))
    let first = try registry.session(accountNamespace: "account-a", documentID: "doc-1")
    try first.replaceText(with: "Unsaved input")

    XCTAssertTrue(try registry.session(accountNamespace: "account-a", documentID: "doc-1") === first)
    let otherAccount = try registry.session(accountNamespace: "account-b", documentID: "doc-1")
    XCTAssertFalse(otherAccount === first)
    XCTAssertEqual(otherAccount.text, "")
  }

  func testRegistryKeepsDocumentOpenAfterLastJavaScriptHandleIsReleased() throws {
    let registry = DocumentSessionRegistry(store: try DocumentStore(url: temporaryStoreURL()))
    weak var retained: DocumentSession?
    do {
      let handle = DocumentSessionHandle(
        session: try registry.session(accountNamespace: "account-a", documentID: "doc-1"))
      retained = handle.session
      try handle.session.replaceText(with: "Navigation survives")
      waitUntil { handle.session.isSavedOnThisPhone }
    }

    XCTAssertNotNil(retained, "releasing the last handle must not close the document session")
    let reopened = try registry.session(accountNamespace: "account-a", documentID: "doc-1")
    XCTAssertTrue(reopened === retained)
    XCTAssertEqual(reopened.text, "Navigation survives")
    XCTAssertTrue(reopened.canUndo)
    try reopened.undo()
    XCTAssertEqual(reopened.text, "")
    try reopened.redo()
    XCTAssertEqual(reopened.text, "Navigation survives")
    waitUntil { reopened.isSavedOnThisPhone }
  }

  func testSelectiveUndoAndRedoPreserveRemoteEditsOnEveryReplica() throws {
    let local = try replica()
    let remote = try replica()
    let observer = try replica()
    let harness = DeliveryHarness(seed: 7, faults: .unreliable)
    for session in [local, remote, observer] { try harness.connect(session) }
    try remote.replaceText(with: "Left old right")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    XCTAssertFalse(local.canUndo, "remote content must not enter local history")
    try local.undo()
    XCTAssertEqual(local.text, "Left old right")
    XCTAssertTrue(try local.pendingOperations().isEmpty)

    try local.replaceText(in: 5..<8, with: "日本")
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    try remote.replaceText(in: 0..<0, with: "👋 ")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()

    try local.undo()
    XCTAssertEqual(local.text, "👋 Left old right")
    XCTAssertFalse(local.canUndo)
    XCTAssertTrue(local.canRedo)
    waitUntil { local.isSavedOnThisPhone }
    XCTAssertTrue(local.hasPendingSynchronization)
    try harness.runUntilIdle()
    for session in [local, remote, observer] {
      XCTAssertEqual(session.text, "👋 Left old right")
    }

    // Remote transactions must preserve redo, too.
    let end = remote.text.utf16.count
    try remote.replaceText(in: end..<end, with: "!")
    waitUntil { remote.isSavedOnThisPhone }
    try harness.runUntilIdle()
    try local.redo()
    waitUntil { local.isSavedOnThisPhone }
    try harness.runUntilIdle()
    for session in [local, remote, observer] {
      XCTAssertEqual(session.text, "👋 Left 日本 right!")
      XCTAssertFalse(session.hasPendingSynchronization)
    }
    XCTAssertTrue(local.canUndo)
    XCTAssertFalse(local.canRedo)
  }

  func testUndoAndRedoPersistOnlyTheirIncrementalChange() throws {
    let url = temporaryStoreURL()
    let store = try DocumentStore(url: url)
    let registry = DocumentSessionRegistry(store: store)
    let session = try registry.session(accountNamespace: "account-a", documentID: "doc-1")
    let original = twentyThousandCharacterFixture
    let offset = original[..<original.index(original.startIndex, offsetBy: 10_000)].utf16.count
    try session.replaceText(with: original)
    try session.replaceText(in: offset..<offset, with: "x")
    try session.undo()
    XCTAssertEqual(session.text, original)
    waitUntil { session.isSavedOnThisPhone }
    let undoUpdates = try store.updates(for: session.metadata.key)
    XCTAssertEqual(try replicaDelta(applying: undoUpdates), [.retain(UInt32(offset)), .delete(1)])
    XCTAssertLessThan(undoUpdates.last!.count, 100)

    try session.redo()
    waitUntil { session.isSavedOnThisPhone }
    let redoUpdates = try store.updates(for: session.metadata.key)
    XCTAssertEqual(try replicaDelta(applying: redoUpdates), [.retain(UInt32(offset)), .insert(.string("x"))])
    XCTAssertLessThan(redoUpdates.last!.count, 100)
    let committed = session.text
    let pending = try session.pendingOperations()
    XCTAssertEqual(pending.map(\.update), redoUpdates)
    try registry.close(session)
    let reopened = try registry.session(accountNamespace: "account-a", documentID: "doc-1")
    XCTAssertEqual(reopened.text, committed)
    XCTAssertEqual(try reopened.pendingOperations(), pending)
    XCTAssertFalse(reopened.canUndo)
    XCTAssertFalse(reopened.canRedo)
    try reopened.undo()
    XCTAssertEqual(reopened.text, committed)
    XCTAssertEqual(try reopened.pendingOperations(), pending)

    // A stale handle's repeated close must not close the newly opened session.
    try registry.close(session)
    XCTAssertTrue(try registry.session(accountNamespace: "account-a", documentID: "doc-1") === reopened)
    XCTAssertThrowsError(try session.replaceText(with: "closed"))
    XCTAssertThrowsError(try session.undo())
    XCTAssertThrowsError(try session.redo())

    let relaunched = try replica(at: url)
    XCTAssertEqual(relaunched.text, committed)
    XCTAssertEqual(try relaunched.pendingOperations(), pending)
    XCTAssertFalse(relaunched.canUndo)
    XCTAssertFalse(relaunched.canRedo)
  }

  func testCloseRefusesPendingCommitsAndMarkedInputWithoutDroppingHistory() throws {
    let storage = DispatchQueue(label: "test.close.storage")
    let registry = DocumentSessionRegistry(store: try DocumentStore(url: temporaryStoreURL(), queue: storage))
    let session = try registry.session(accountNamespace: "account-a", documentID: "doc-1")
    do {
      storage.suspend()
      defer { storage.resume() }
      try session.replaceText(with: "kept")
      XCTAssertThrowsError(try registry.close(session))
      XCTAssertFalse(session.isClosed)
      XCTAssertTrue(session.canUndo)
    }
    waitUntil { session.isSavedOnThisPhone }
    session.hasMarkedText = true
    XCTAssertThrowsError(try registry.close(session))
    XCTAssertThrowsError(try session.undo())
    XCTAssertEqual(session.text, "kept")
    XCTAssertFalse(session.isClosed)
    session.hasMarkedText = false
    try session.undo()
    XCTAssertEqual(session.text, "")
    try session.replaceText(with: "new action")
    XCTAssertFalse(session.canRedo, "a new local action must invalidate redo")
    waitUntil { session.isSavedOnThisPhone }
    try registry.close(session)
    XCTAssertTrue(session.isClosed)
    XCTAssertFalse(session.canUndo)
    XCTAssertFalse(session.canRedo)
  }
}

// MARK: - Helpers

/// 20,000 grapheme clusters of mixed scripts, emoji, and combining marks.
let twentyThousandCharacterFixture: String = {
  let paragraph =
    "Plain prose with a thumbs-up 👍🏽, a family 👨‍👩‍👧‍👦, cafe\u{301}, 日本語のテキスト, and שלום עולם.\n"
  return String(String(repeating: paragraph, count: 20_000 / paragraph.count + 1).prefix(20_000))
}()

/// Applies every update but the last to a fresh replica, then returns the text delta the last one
/// produces there: the changes it decodes to.
func replicaDelta(applying updates: [Data]) throws -> [YTextDeltaOperation] {
  let replica = YDoc()
  let body = try replica.text(named: "body")
  for update in updates.dropLast() { try replica.apply(.v1(update)) }
  var deltas: [[YTextDeltaOperation]] = []
  let observation = try body.observe { event in
    if case .shared(let change) = event { deltas.append(change.delta) }
  }
  defer { observation.cancel() }
  try replica.apply(.v1(updates.last!))
  XCTAssertEqual(deltas.count, 1)
  return deltas.first ?? []
}

func temporaryStoreURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathComponent("documents.sqlite")
}

/// Spins the main run loop, where sessions publish state, until `condition` holds.
@MainActor
func waitUntil(
  timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
  _ condition: () -> Bool
) {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition(), Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  XCTAssertTrue(condition(), "condition not met within \(timeout)s", file: file, line: line)
}
