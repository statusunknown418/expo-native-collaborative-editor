import SQLite3
import XCTest

@testable import ExpoNativeCollaborativeEditor

/// Replicas of one document exchanging updates through the delivery harness.
@MainActor
final class SynchronizationTests: XCTestCase {
  func testReceiptsAcknowledgeExactlyTheirOperations() throws {
    let url = temporaryStoreURL()
    let writer = try replica(at: url)
    let harness = DeliveryHarness(seed: 1, faults: .none)
    for session in [writer, try replica(), try replica()] { try harness.connect(session) }
    XCTAssertFalse(writer.hasPendingSynchronization)

    try writer.replaceText(with: "Hello")
    waitUntil { writer.isSavedOnThisPhone }
    XCTAssertTrue(writer.hasPendingSynchronization)
    // The server accepts the first operation; its receipt is in flight while a second one commits.
    try harness.tick()
    try writer.replaceText(with: "Hello, world")
    waitUntil { writer.isSavedOnThisPhone }
    let second = try XCTUnwrap(try DocumentStore(url: url).outbox(for: writer.metadata.key).last)

    try harness.tick()
    XCTAssertTrue(writer.hasPendingSynchronization)
    XCTAssertEqual(try DocumentStore(url: url).outbox(for: writer.metadata.key), [second])

    try harness.runUntilIdle()
    XCTAssertFalse(writer.hasPendingSynchronization)
    let reopened = try replica(at: url)
    XCTAssertFalse(reopened.hasPendingSynchronization)
    XCTAssertEqual(try DocumentStore(url: url).outbox(for: reopened.metadata.key), [])
  }

  func testALocalOnlyDocumentDeliversItsCommittedWorkOnceConnected() throws {
    let local = try replica()
    try local.replaceText(with: "Written while local-only")
    waitUntil { local.isSavedOnThisPhone }
    XCTAssertTrue(local.hasPendingSynchronization)

    let others = [try replica(), try replica()]
    let harness = DeliveryHarness(seed: 1, faults: .none)
    for session in [local] + others { try harness.connect(session) }
    try harness.runUntilIdle()
    XCTAssertEqual(others.map(\.text), ["Written while local-only", "Written while local-only"])
    XCTAssertFalse(local.hasPendingSynchronization)
  }

  func testIncomingUpdatesPersistInDeliveryOrderBeforeTheyApply() throws {
    let source = try replica()
    for text in ["Hello", "Hello, world", "Hello, world!"] {
      try source.replaceText(with: text)
      waitUntil { source.isSavedOnThisPhone }
    }
    let updates = try source.pendingOperations().map(\.update)
    let url = temporaryStoreURL()
    let receiver = try replica(at: url)

    // Position 2 arrives first and waits for position 1.
    try receiver.receive(updates[1], at: 2)
    XCTAssertEqual(receiver.text, "")
    // Position 1 cannot persist while another connection holds the write lock, so nothing applies.
    var writer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
    defer { sqlite3_close(writer) }
    XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try receiver.receive(updates[0], at: 1))
    XCTAssertEqual(receiver.text, "")
    XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)

    try receiver.receive(updates[0], at: 1)
    XCTAssertEqual(receiver.text, "Hello, world")
    XCTAssertFalse(receiver.hasPendingSynchronization)

    // After a restart, both positions are known: a stale position is ignored, the next one applies.
    let reopened = try replica(at: url)
    XCTAssertEqual(reopened.text, "Hello, world")
    try reopened.receive(updates[2], at: 2)
    XCTAssertEqual(reopened.text, "Hello, world")
    try reopened.receive(updates[2], at: 3)
    XCTAssertEqual(reopened.text, "Hello, world!")
    XCTAssertEqual(try DocumentStore(url: url).outbox(for: reopened.metadata.key), [])
  }

  func testRemoteEditsKeepTheSelectionAtItsLogicalPosition() throws {
    let original = "Hi 👍🏽 there, world"
    // A caret sticks to the character before it; a range keeps its own characters, so remote text
    // inserted at either edge stays outside it.
    typealias Case = (
      name: String, selection: Range<Int>, remote: Range<Int>, insert: String, text: String, expected: Range<Int>
    )
    let cases: [Case] = [
      (
        "insert before the caret", caret(before: "world", in: original), 0..<0, "👨‍👩‍👧‍👦 ",
        "👨‍👩‍👧‍👦 Hi 👍🏽 there, world", caret(before: "world", in: "👨‍👩‍👧‍👦 Hi 👍🏽 there, world")
      ),
      (
        "insert after the caret", caret(before: "there", in: original), caret(after: "world", in: original), "!",
        "Hi 👍🏽 there, world!", caret(before: "there", in: original)
      ),
      (
        "insert at the caret", caret(after: "there,", in: original), caret(after: "there,", in: original), " 🌍",
        "Hi 👍🏽 there, 🌍 world", caret(after: "there,", in: original)
      ),
      (
        "delete spanning the caret", caret(after: "th", in: original), range(of: "there, ", in: original), "",
        "Hi 👍🏽 world", caret(before: "world", in: "Hi 👍🏽 world")
      ),
      (
        "replace a cluster before the caret", caret(before: "world", in: original), range(of: "👍🏽", in: original),
        "👨‍👩‍👧‍👦", "Hi 👨‍👩‍👧‍👦 there, world", caret(before: "world", in: "Hi 👨‍👩‍👧‍👦 there, world")
      ),
      (
        "insert at the start of a range", range(of: "there", in: original), caret(before: "there", in: original), "🎉",
        "Hi 👍🏽 🎉there, world", range(of: "there", in: "Hi 👍🏽 🎉there, world")
      ),
      (
        "insert at the end of a range", range(of: "there", in: original), caret(after: "there", in: original), "🎉",
        "Hi 👍🏽 there🎉, world", range(of: "there", in: "Hi 👍🏽 there🎉, world")
      ),
      (
        "delete spanning the end of a range", range(of: "there, wo", in: original), range(of: "e, world", in: original),
        "", "Hi 👍🏽 ther", range(of: "ther", in: "Hi 👍🏽 ther")
      ),
    ]

    for example in cases {
      let local = try replica()
      let remote = try replica()
      let harness = DeliveryHarness(seed: 1, faults: .none)
      try harness.connect(local)
      try harness.connect(remote)
      try local.replaceText(with: original)
      waitUntil { local.isSavedOnThisPhone }
      try harness.runUntilIdle()
      local.selection = example.selection

      try remote.replaceText(in: example.remote, with: example.insert)
      waitUntil { remote.isSavedOnThisPhone }
      try harness.runUntilIdle()
      XCTAssertEqual(Array(local.text.unicodeScalars), Array(example.text.unicodeScalars), example.name)
      XCTAssertEqual(local.selection, example.expected, example.name)
    }
  }

  func testSeededConcurrentEditsConvergeOnEveryReplica() throws {
    for seed: UInt64 in 1...20 { _ = try converge(seed: seed) }
  }

  func testASeedReproducesItsRun() throws {
    let first = try converge(seed: 7)
    XCTAssertFalse(first.text.isEmpty)
    XCTAssertEqual(try converge(seed: 7), first)
  }

  /// Three replicas make random concurrent edits through an unreliable harness. Asserts that they
  /// converge, that replaying every delivery changes nothing, and that each store reopens to the
  /// converged document with nothing pending; returns that document. Failures name the seed.
  private func converge(seed: UInt64) throws -> SemanticSnapshot {
    var random = SeededGenerator(seed: seed)
    let harness = DeliveryHarness(seed: seed, faults: .unreliable)
    let urls = (0..<3).map { _ in temporaryStoreURL() }
    let replicas = try urls.enumerated().map { try replica(at: $1, clientID: UInt64($0 + 1)) }
    for session in replicas { try harness.connect(session) }
    let insertions = ["", "a", "Zz", "e\u{301}", "\u{E9}", "👍🏽", "👨‍👩‍👧‍👦", "日本", "𠮷", "שלום", "\n"]

    for _ in 0..<80 {
      if Bool.random(using: &random) {
        let session = replicas.randomElement(using: &random)!
        let characters = Array(session.text)
        let start = Int.random(in: 0...characters.count, using: &random)
        let end = Int.random(in: start...min(start + 3, characters.count), using: &random)
        let offset = String(characters[..<start]).utf16.count
        let length = String(characters[start..<end]).utf16.count
        try session.replaceText(in: offset..<(offset + length), with: insertions.randomElement(using: &random)!)
        waitUntil { session.isSavedOnThisPhone }
      } else {
        try harness.tick()
      }
    }
    try harness.runUntilIdle()

    let converged = SemanticSnapshot(text: replicas[0].text)
    for (index, session) in replicas.enumerated() {
      XCTAssertEqual(SemanticSnapshot(text: session.text), converged, "seed \(seed), replica \(index)")
      XCTAssertFalse(session.hasPendingSynchronization, "seed \(seed), replica \(index)")
    }
    harness.redeliverEverything()
    try harness.runUntilIdle()
    for (index, session) in replicas.enumerated() {
      XCTAssertEqual(SemanticSnapshot(text: session.text), converged, "seed \(seed), replica \(index) after replay")
    }
    for (index, url) in urls.enumerated() {
      let reopened = try replica(at: url)
      XCTAssertEqual(SemanticSnapshot(text: reopened.text), converged, "seed \(seed), replica \(index) reopened")
      XCTAssertFalse(reopened.hasPendingSynchronization, "seed \(seed), replica \(index) reopened")
    }
    return converged
  }
}

// MARK: - Helpers

/// A replica of one document with its own store, as on another device.
@MainActor
func replica(at url: URL = temporaryStoreURL(), clientID: UInt64? = nil) throws -> DocumentSession {
  try DocumentSessionRegistry(store: DocumentStore(url: url))
    .session(accountNamespace: "account-a", documentID: "doc-1", clientID: clientID)
}

/// The UTF-16 range of the first occurrence of `substring` in `text`.
func range(of substring: String, in text: String) -> Range<Int> {
  let found = text.range(of: substring)!
  let start = text.utf16.distance(from: text.startIndex, to: found.lowerBound)
  return start..<(start + substring.utf16.count)
}

func caret(before substring: String, in text: String) -> Range<Int> {
  let start = range(of: substring, in: text).lowerBound
  return start..<start
}

func caret(after substring: String, in text: String) -> Range<Int> {
  let end = range(of: substring, in: text).upperBound
  return end..<end
}
