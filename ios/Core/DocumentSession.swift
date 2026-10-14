import Combine
import Foundation
import SwiftYrs
import os

private let logger = Logger(subsystem: "expo.modules.nativecollaborativeeditor", category: "DocumentSession")

/// The live, editable state of one document. Engine access and published state are confined to the
/// main actor; commits run on the store's storage executor.
// `ObservableObject`, not `@Observable`: the macro expands to `Observation.…`, which SwiftYrs's
// `Observation` class shadows in any file that imports SwiftYrs.
@MainActor
final class DocumentSession: ObservableObject {
  let metadata: DocumentMetadata
  /// Plain-text projection of the engine state.
  @Published private(set) var text: String
  /// Every local update has been committed with its outbox operation ("Saved on this phone").
  @Published private(set) var isSavedOnThisPhone = true
  /// Committed local operations await their receipts ("Pending synchronization").
  @Published private(set) var hasPendingSynchronization: Bool
  /// Each local operation once it commits, for delivery.
  let committedOperations = PassthroughSubject<OutboxOperation, Never>()
  /// The editing surface's selection, in UTF-16 offsets into `text`. Transient: remote changes move
  /// it with the text it selects, and it is never stored.
  var selection = 0..<0
  /// Each remote change once `text` and `selection` reflect it: the edits it made, in order, each
  /// offset into the text the edits before it produced.
  let remoteChanges = PassthroughSubject<[TextEdit], Never>()
  /// The last position of this replica's delivery feed persisted and applied.
  private(set) var deliveredThrough: Int

  private let store: DocumentStore
  private let doc: YDoc
  private let body: YText
  private let transactionUpdate = Capture<Data>()
  private let transactionDelta = Capture<[YTextDeltaOperation]>()
  private var observations: [SwiftYrs.Observation] = []
  /// Local updates produced, and the latest one known to be committed.
  private var revision = 0
  private var savedRevision = 0
  /// A commit failed, so later commits no longer make every local update durable.
  // ponytail: a failed commit only withholds "Saved on this phone"; retaining the input, rejecting
  // further edits, and retrying exactly once arrive with persistence-failure handling (#13).
  private var hasFailedCommit = false
  /// Delivered updates that arrived before an earlier position, keyed by position.
  // ponytail: unbounded; a real sync adapter pages its feed, which bounds this.
  private var earlyDeliveries: [Int: Data] = [:]

  fileprivate init(metadata: DocumentMetadata, store: DocumentStore, clientID: UInt64?) throws {
    self.metadata = metadata
    self.store = store
    doc = clientID.map { YDoc(clientID: $0) } ?? YDoc()
    let body = try doc.text(named: "body")
    self.body = body
    let updates = try store.updates(for: metadata.key)
    try doc.write { transaction in
      for update in updates { try transaction.apply(.v1(update)) }
    }
    text = try SemanticSnapshot(body: body, in: doc).text
    hasPendingSynchronization = !(try store.outbox(for: metadata.key).isEmpty)
    deliveredThrough = try store.deliveredThrough(metadata.key)
    // Registered after replay so they only see this session's transactions.
    observations = [
      try doc.observeUpdates { [transactionUpdate] event in
        if case .update(let update) = event { transactionUpdate.value = update.data }
      },
      try body.observe { [transactionDelta] event in
        if case .shared(let change) = event { transactionDelta.value = change.delta }
      },
    ]
  }

  /// Applies a local edit, given as the surface's whole new text, as one engine transaction and
  /// commits its incremental update.
  func replaceText(with newText: String) throws {
    guard let edit = TextEdit(from: text, to: newText) else { return }
    try commit(edit)
  }

  /// Replaces a UTF-16 `range` of the text as one local engine transaction and commits its
  /// incremental update. The range must fall on Unicode scalar boundaries.
  func replaceText(in range: Range<Int>, with replacement: String) throws {
    try commit(TextEdit(utf16Offset: range.lowerBound, utf16Length: range.count, replacement: replacement))
  }

  private func commit(_ edit: TextEdit) throws {
    let offset = UInt32(edit.utf16Offset)
    try doc.write { transaction in
      if edit.utf16Length > 0 {
        try transaction.remove(from: body, at: offset, length: UInt32(edit.utf16Length))
      }
      if !edit.replacement.isEmpty {
        try transaction.insert(edit.replacement, into: body, at: offset)
      }
    }
    text = try SemanticSnapshot(body: body, in: doc).text
    guard let update = transactionUpdate.take() else { return }

    revision += 1
    let committing = revision
    isSavedOnThisPhone = false
    store.append(update, to: metadata.key) { [weak self] result in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          switch result {
          case .failure(let error):
            logger.error("Local commit failed: \(String(describing: error), privacy: .public)")
            self.hasFailedCommit = true
          case .success(let operation):
            self.savedRevision = committing
            self.isSavedOnThisPhone = !self.hasFailedCommit && self.savedRevision == self.revision
            self.hasPendingSynchronization = true
            self.committedOperations.send(operation)
          }
        }
      }
    }
  }

  /// Committed local operations without a receipt, oldest first.
  func pendingOperations() throws -> [OutboxOperation] {
    try store.outbox(for: metadata.key)
  }

  /// Applies a receipt: the operations it names are no longer pending synchronization.
  func acknowledge(_ operationIDs: [UUID]) throws {
    hasPendingSynchronization = try store.acknowledge(operationIDs, for: metadata.key) > 0
  }

  /// Persists a remote update with its position in this replica's delivery feed, then applies it.
  /// Persisted positions stay contiguous: positions already persisted are ignored, and a later one
  /// waits in memory until every position before it has arrived.
  // ponytail: persists on the main actor, blocking it for one commit per remote update; move to the
  // storage executor if typing traces show it.
  func receive(_ update: Data, at position: Int) throws {
    guard position > deliveredThrough else { return }
    earlyDeliveries[position] = update
    while let next = earlyDeliveries[deliveredThrough + 1] {
      try store.receive(next, at: deliveredThrough + 1, for: metadata.key)
      earlyDeliveries[deliveredThrough + 1] = nil
      deliveredThrough += 1
      try applyRemote(next)
    }
  }

  private func applyRemote(_ update: Data) throws {
    _ = transactionDelta.take()
    try doc.apply(.v1(update))
    _ = transactionUpdate.take()  // A remote update, not a local one to commit.
    let edits = Self.edits(from: transactionDelta.take() ?? [])
    guard !edits.isEmpty else { return }

    text = try SemanticSnapshot(body: body, in: doc).text
    // A caret sticks to the character before it. A range keeps its own characters: its start sticks
    // to the character after it, its end to the character before it.
    var lower = selection.lowerBound
    var upper = selection.upperBound
    for edit in edits {
      lower = edit.transform(lower, sticksToPreceding: selection.isEmpty)
      upper = edit.transform(upper, sticksToPreceding: true)
    }
    selection = lower..<max(lower, upper)
    remoteChanges.send(edits)
  }

  /// The edits a text delta makes, in order, each offset into the text the edits before it produced.
  private static func edits(from delta: [YTextDeltaOperation]) -> [TextEdit] {
    var offset = 0
    var edits: [TextEdit] = []
    for operation in delta {
      switch operation {
      case .retain(let length, _):
        offset += Int(length)
      case .delete(let length):
        edits.append(TextEdit(utf16Offset: offset, utf16Length: Int(length), replacement: ""))
      case .insert(let value, _):
        // An embed occupies one offset; plain-text documents hold none.
        let inserted = if case .string(let string) = value { string } else { "\u{FFFC}" }
        edits.append(TextEdit(utf16Offset: offset, utf16Length: 0, replacement: inserted))
        offset += inserted.utf16.count
      }
    }
    return edits
  }
}

/// Receives what a transaction's observer reports when the transaction commits, which happens
/// synchronously before `YDoc.write` or `YDoc.apply` returns.
private final class Capture<Value>: @unchecked Sendable {
  var value: Value?

  func take() -> Value? {
    defer { value = nil }
    return value
  }
}

/// Hands out at most one live session per account namespace, document, and lifecycle generation.
@MainActor
final class DocumentSessionRegistry {
  private let store: DocumentStore
  private var sessions: [DocumentKey: WeakSession] = [:]

  init(store: DocumentStore) {
    self.store = store
  }

  /// Opens the document's latest lifecycle generation in the account namespace, creating the document
  /// if it does not exist. Returns the live session if one is already open.
  ///
  /// Each session needs an engine client ID no other session of the document has used; by default it
  /// is random. Tests fix it, because concurrent insertions at one position order by client ID.
  func session(accountNamespace: String, documentID: String, clientID: UInt64? = nil) throws -> DocumentSession {
    let metadata = try store.openOrCreateDocument(accountNamespace: accountNamespace, documentID: documentID)
    if let live = sessions[metadata.key]?.session { return live }
    let session = try DocumentSession(metadata: metadata, store: store, clientID: clientID)
    sessions[metadata.key] = WeakSession(session: session)
    return session
  }
}

private struct WeakSession {
  weak var session: DocumentSession?
}
