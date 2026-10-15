import Combine
import Foundation
import SwiftYrs
import os

private let logger = Logger(subsystem: "expo.modules.nativecollaborativeeditor", category: "DocumentSession")

enum DocumentSessionError: LocalizedError {
  case closed
  case unsavedInput

  var errorDescription: String? {
    switch self {
    case .closed: "The document session is closed."
    case .unsavedInput: "The document session still has unsaved input."
    }
  }
}

/// The live, editable state of one document. Engine access and published state are confined to the
/// main actor; commits run on the store's storage executor.
// `ObservableObject`, not `@Observable`: the macro expands to `Observation.…`, which SwiftYrs's
// `Observation` class shadows in any file that imports SwiftYrs.
@MainActor
final class DocumentSession: ObservableObject {
  let metadata: DocumentMetadata
  /// Plain-text projection of the engine state.
  @Published private(set) var text: String
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var isClosed = false
  /// Every local update is durable and the input system holds no marked text ("Saved on this phone").
  @Published private(set) var isSavedOnThisPhone = true
  /// Marked text belongs to the input system, not the document or outbox.
  var hasMarkedText = false {
    didSet {
      guard hasMarkedText != oldValue else { return }
      isSavedOnThisPhone = !hasMarkedText && !hasUncommittedOperations
    }
  }
  /// Unlike marked input, these operations must finish committing before the harness can deliver them.
  var hasUncommittedOperations: Bool { hasFailedCommit || savedRevision != revision }
  /// Committed local operations await their receipts ("Pending synchronization").
  @Published private(set) var hasPendingSynchronization: Bool
  /// Each local operation once it commits, for delivery.
  let committedOperations = PassthroughSubject<OutboxOperation, Never>()
  /// The editing surface's selection, in UTF-16 offsets into `text`. Transient: remote changes move
  /// it with the text it selects, and it is never stored.
  var selection = 0..<0
  /// Each remote or history change once `text` and `selection` reflect it: the edits it made, in
  /// order, each offset into the text the edits before it produced.
  let surfaceChanges = PassthroughSubject<[TextEdit], Never>()
  /// The last position of this replica's delivery feed persisted and applied.
  private(set) var deliveredThrough: Int

  private let store: DocumentStore
  private let doc: YDoc
  private let body: YText
  private let undoHistory: YUndoManager
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
    // Replayed content is committed state, never part of this session's undo history.
    undoHistory = YUndoManager(document: doc)
    try undoHistory.addScope(body)
    undoHistory.includeOrigin("local")
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
    try requireOpen()
    guard let edit = TextEdit(from: text, to: newText) else { return }
    try commit(edit)
  }

  /// Replaces a UTF-16 `range` of the text as one local engine transaction and commits its
  /// incremental update. The range must fall on Unicode scalar boundaries.
  func replaceText(in range: Range<Int>, with replacement: String) throws {
    try commit(TextEdit(utf16Offset: range.lowerBound, utf16Length: range.count, replacement: replacement))
  }

  private func commit(_ edit: TextEdit) throws {
    try requireOpen()
    let offset = UInt32(edit.utf16Offset)
    try doc.write(origin: "local") { transaction in
      if edit.utf16Length > 0 {
        try transaction.remove(from: body, at: offset, length: UInt32(edit.utf16Length))
      }
      if !edit.replacement.isEmpty {
        try transaction.insert(edit.replacement, into: body, at: offset)
      }
    }
    // One committed input replacement is one action; remote transactions never join it.
    undoHistory.stopCapturing()
    text = try SemanticSnapshot(body: body, in: doc).text
    persistLocalUpdate()
    updateHistoryAvailability()
  }

  func undo() throws {
    try changeHistory(redo: false)
  }

  func redo() throws {
    try changeHistory(redo: true)
  }

  private func changeHistory(redo: Bool) throws {
    try requireOpen()
    guard !hasMarkedText else { throw DocumentSessionError.unsavedInput }
    _ = transactionDelta.take()
    if redo {
      _ = try undoHistory.redo()
    } else {
      _ = try undoHistory.undo()
    }
    persistLocalUpdate()
    updateHistoryAvailability()
    try publishSurfaceChanges(moveCaretToEditEnd: redo)
  }

  private func updateHistoryAvailability() {
    canUndo = undoHistory.undoStackCount > 0
    canRedo = undoHistory.redoStackCount > 0
  }

  private func requireOpen() throws {
    guard !isClosed else { throw DocumentSessionError.closed }
  }

  fileprivate func close() throws {
    guard !isClosed else { return }
    guard !hasMarkedText, !hasUncommittedOperations else { throw DocumentSessionError.unsavedInput }
    undoHistory.clear()
    updateHistoryAvailability()
    isClosed = true
  }

  /// Every engine-originated local update, including undo/redo, uses the same durable outbox path.
  private func persistLocalUpdate() {
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
            self.isSavedOnThisPhone = !self.hasMarkedText && !self.hasUncommittedOperations
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
    try requireOpen()
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
    try doc.write(origin: "remote") { try $0.apply(.v1(update)) }
    _ = transactionUpdate.take()  // A remote update, not a local one to commit.
    updateHistoryAvailability()
    try publishSurfaceChanges()
  }

  private func publishSurfaceChanges(moveCaretToEditEnd: Bool = false) throws {
    let edits = Self.edits(from: transactionDelta.take() ?? [])
    guard !edits.isEmpty else { return }

    text = try SemanticSnapshot(body: body, in: doc).text
    if moveCaretToEditEnd, let last = edits.last {
      let caret = last.utf16Offset + last.replacement.utf16.count
      selection = caret..<caret
    } else {
      // A caret sticks to the character before it. A range keeps its own characters: its start sticks
      // to the character after it, its end to the character before it.
      var lower = selection.lowerBound
      var upper = selection.upperBound
      for edit in edits {
        lower = edit.transform(lower, sticksToPreceding: selection.isEmpty)
        upper = edit.transform(upper, sticksToPreceding: true)
      }
      selection = lower..<max(lower, upper)
    }
    surfaceChanges.send(edits)
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
  private var sessions: [DocumentKey: DocumentSession] = [:]

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
    if let live = sessions[metadata.key] { return live }
    let session = try DocumentSession(metadata: metadata, store: store, clientID: clientID)
    sessions[metadata.key] = session
    return session
  }

  /// Only the host closes a session. Refuse to drop input whose commit is still pending or failed.
  func close(_ session: DocumentSession) throws {
    try session.close()
    if sessions[session.metadata.key] === session {
      sessions.removeValue(forKey: session.metadata.key)
    }
  }
}
