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

  private let store: DocumentStore
  private let doc = YDoc()
  private let body: YText
  private let transactionUpdate = UpdateCapture()
  private var updateObservation: SwiftYrs.Observation?
  /// Local updates produced, and the latest one known to be committed.
  private var revision = 0
  private var savedRevision = 0
  /// A commit failed, so later commits no longer make every local update durable.
  // ponytail: a failed commit only withholds "Saved on this phone"; retaining the input, rejecting
  // further edits, and retrying exactly once arrive with persistence-failure handling (#13).
  private var hasFailedCommit = false

  fileprivate init(metadata: DocumentMetadata, store: DocumentStore) throws {
    self.metadata = metadata
    self.store = store
    let body = try doc.text(named: "body")
    self.body = body
    let updates = try store.updates(for: metadata.key)
    try doc.write { transaction in
      for update in updates { try transaction.apply(.v1(update)) }
    }
    text = try SemanticSnapshot(body: body, in: doc).text
    // Registered after replay so it only sees this session's transactions.
    updateObservation = try doc.observeUpdates { [transactionUpdate] event in
      if case .update(let update) = event { transactionUpdate.data = update.data }
    }
  }

  /// Applies a local edit as one engine transaction and commits its incremental update.
  func replaceText(with newText: String) throws {
    guard let edit = TextEdit(from: text, to: newText) else { return }
    let offset = UInt32(edit.utf16Offset)
    try doc.write { transaction in
      if edit.utf16Length > 0 {
        try transaction.remove(from: body, at: offset, length: UInt32(edit.utf16Length))
      }
      if !edit.replacement.isEmpty {
        try transaction.insert(edit.replacement, into: body, at: offset)
      }
    }
    text = newText
    guard let update = transactionUpdate.take() else { return }

    revision += 1
    let committing = revision
    isSavedOnThisPhone = false
    store.append(update, to: metadata.key) { [weak self] error in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          if let error {
            logger.error("Local commit failed: \(String(describing: error), privacy: .public)")
            self.hasFailedCommit = true
            return
          }
          self.savedRevision = committing
          self.isSavedOnThisPhone = !self.hasFailedCommit && self.savedRevision == self.revision
        }
      }
    }
  }
}

/// Receives the update a write transaction emits when it commits, which happens synchronously before
/// `YDoc.write` returns.
private final class UpdateCapture: @unchecked Sendable {
  var data: Data?

  func take() -> Data? {
    defer { data = nil }
    return data
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
  func session(accountNamespace: String, documentID: String) throws -> DocumentSession {
    let metadata = try store.openOrCreateDocument(accountNamespace: accountNamespace, documentID: documentID)
    if let live = sessions[metadata.key]?.session { return live }
    let session = try DocumentSession(metadata: metadata, store: store)
    sessions[metadata.key] = WeakSession(session: session)
    return session
  }
}

private struct WeakSession {
  weak var session: DocumentSession?
}
