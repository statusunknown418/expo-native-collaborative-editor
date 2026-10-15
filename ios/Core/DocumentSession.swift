import Combine
import Foundation
import SwiftYrs
import os

private let logger = Logger(subsystem: "expo.modules.nativecollaborativeeditor", category: "DocumentSession")

enum DocumentSessionError: LocalizedError {
  case closed
  case unsavedInput
  case invalidRange
  case featureDisabled

  var errorDescription: String? {
    switch self {
    case .closed: "The document session is closed."
    case .unsavedInput: "The document session still has unsaved input."
    case .invalidRange: "The editing range must lie on Unicode scalar boundaries inside the document."
    case .featureDisabled: "The requested authoring capability is not enabled."
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
  private(set) var snapshot: SemanticSnapshot
  var featureManifest: [String] { snapshot.features ?? [] }
  private(set) var plugins: FeaturePlugins
  @Published private(set) var selectedFormatting = SelectedFormatting()
  private(set) var typingFormatting = TextFormatting()
  /// Typing attributes can change without producing a document transaction.
  let typingFormattingChanges = PassthroughSubject<Void, Never>()
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
  var selection = 0..<0 {
    didSet {
      guard selection != oldValue else { return }
      updateSelectedFormatting(resetTyping: true)
    }
  }
  /// Each remote or history change once `text` and `selection` reflect it: the edits it made, in
  /// order, each offset into the text the edits before it produced.
  let surfaceChanges = PassthroughSubject<[TextEdit], Never>()
  /// The last position of this replica's delivery feed persisted and applied.
  private(set) var deliveredThrough: Int

  private let store: DocumentStore
  private let doc: YDoc
  let body: YText
  private let manifest: YMap
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

  fileprivate init(metadata: DocumentMetadata, store: DocumentStore, clientID: UInt64?, plugins: FeaturePlugins) throws {
    self.metadata = metadata
    self.store = store
    self.plugins = plugins
    doc = clientID.map { YDoc(clientID: $0) } ?? YDoc()
    let body = try doc.text(named: "body")
    self.body = body
    manifest = try doc.map(named: "features")
    let updates = try store.updates(for: metadata.key)
    try doc.write { transaction in
      for update in updates { try transaction.apply(.v1(update)) }
    }
    snapshot = try SemanticSnapshot(body: body, in: doc)
    text = snapshot.text
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
    updateSelectedFormatting(resetTyping: true)
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
    let range = edit.utf16Offset..<(edit.utf16Offset + edit.utf16Length)
    try validate(range)
    let formatting = range == selection ? typingFormatting : inheritedFormatting(at: range.lowerBound)
    try transact { transaction in
      try replaceListAware(in: range, with: edit.replacement, formatting: formatting, transaction: transaction)
    }
  }

  /// Every plugin mutation uses this same core transaction, undo, and persistence path.
  func transact(_ mutation: (YWriteTransaction) throws -> Void) throws {
    try requireOpen()
    _ = transactionDelta.take()
    try doc.write(origin: "local") { try mutation($0) }
    undoHistory.stopCapturing()
    snapshot = try SemanticSnapshot(body: body, in: doc)
    text = snapshot.text
    persistLocalUpdate()
    updateHistoryAvailability()
  }

  func setPlugins(_ plugins: FeaturePlugins) throws {
    try requireOpen()
    self.plugins = plugins
  }

  func toggleBold() throws {
    guard plugins.formatting?.bold == true else { throw DocumentSessionError.featureDisabled }
    try setInlineFormat("bold", enabled: selectedFormatting.bold != true)
  }

  func toggleItalic() throws {
    guard plugins.formatting?.italic == true else { throw DocumentSessionError.featureDisabled }
    try setInlineFormat("italic", enabled: selectedFormatting.italic != true)
  }

  private func setInlineFormat(_ key: String, enabled: Bool) throws {
    try requireOpen()
    guard !hasMarkedText else { throw DocumentSessionError.unsavedInput }
    try validate(selection)
    if selection.isEmpty {
      if key == "bold" { typingFormatting.bold = enabled } else { typingFormatting.italic = enabled }
      updateSelectedFormatting()
      return
    }
    try transact { transaction in
      try transaction.format(body, at: UInt32(selection.lowerBound), length: UInt32(selection.count),
        attributes: [key: enabled ? .bool(true) : .null])
      if enabled { try recordFeatures(["formatting.\(key)@1"], in: transaction) }
    }
    updateSelectedFormatting(resetTyping: true)
    surfaceChanges.send([])
  }

  /// Headings apply to whole paragraphs touched by the selection; an empty paragraph uses typing
  /// attributes until text exists. No hidden characters or whole-document replacements.
  func setHeading(_ level: Int) throws {
    try requireOpen()
    guard let options = plugins.formatting,
      level == 0 || options.headingLevels.contains(level)
    else { throw DocumentSessionError.featureDisabled }
    guard !hasMarkedText else { throw DocumentSessionError.unsavedInput }
    try validate(selection)
    let string = text as NSString
    let range = string.paragraphRange(for: NSRange(selection))
    if range.length > 0 {
      try transact { transaction in
        try transaction.format(body, at: UInt32(range.location), length: UInt32(range.length),
          attributes: ["heading": level == 0 ? .null : .int(Int64(level))])
        if level > 0 { try recordFeatures(["formatting.heading@1"], in: transaction) }
      }
      if !selection.isEmpty { typingFormatting = snapshot.formatting(at: selection.lowerBound) }
    }
    typingFormatting.heading = level
    updateSelectedFormatting()
    if range.length > 0 { surfaceChanges.send([]) }
  }

  func recordFeatures(_ features: [String], in transaction: YWriteTransaction) throws {
    for feature in features where !featureManifest.contains(feature) {
      try transaction.set(.int(1), forKey: feature, in: manifest)
    }
  }

  func validate(_ range: Range<Int>) throws {
    guard range.lowerBound >= 0, range.upperBound <= text.utf16.count,
      String.Index(utf16Offset: range.lowerBound, in: text).samePosition(in: text.unicodeScalars) != nil,
      String.Index(utf16Offset: range.upperBound, in: text).samePosition(in: text.unicodeScalars) != nil
    else { throw DocumentSessionError.invalidRange }
  }

  private func inheritedFormatting(at offset: Int) -> TextFormatting {
    let offset = min(max(0, offset), text.utf16.count)
    // At a new paragraph use its first character, not the preceding paragraph's separator.
    let previous = max(0, offset - 1)
    let atParagraphStart = offset == 0 || (text as NSString).character(at: previous) == 10
    return snapshot.formatting(at: atParagraphStart ? offset : previous)
  }

  private func updateSelectedFormatting(resetTyping: Bool = false) {
    if resetTyping && !hasMarkedText {
      typingFormatting = selection.isEmpty
        ? inheritedFormatting(at: selection.lowerBound) : snapshot.formatting(at: selection.lowerBound)
    }
    selectedFormatting = selection.isEmpty
      ? SelectedFormatting(typingFormatting) : snapshot.selectedFormatting(in: selection)
    typingFormattingChanges.send()
  }

  /// Structural commands share the native commit path, then publish the actual engine delta once.
  func performListEdit(_ mutation: (YWriteTransaction) throws -> Int?) throws {
    try requireOpen()
    guard !hasMarkedText else { throw DocumentSessionError.unsavedInput }
    try validate(selection)
    let previousSelection = selection
    var caret: Int?
    try transact { caret = try mutation($0) }
    let edits = Self.edits(from: transactionDelta.take() ?? [])
    if let caret {
      let offset = min(max(0, caret), text.utf16.count)
      selection = offset..<offset
    } else {
      var lower = previousSelection.lowerBound
      var upper = previousSelection.upperBound
      for edit in edits {
        lower = edit.transform(lower, sticksToPreceding: previousSelection.isEmpty)
        upper = edit.transform(upper, sticksToPreceding: true)
      }
      selection = lower..<max(lower, upper)
    }
    updateSelectedFormatting(resetTyping: true)
    surfaceChanges.send(edits)
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
    guard redo ? canRedo : canUndo else { return }
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
  /// Feed positions must already follow causal acceptance order (ADR 0007); this only repairs
  /// transport reordering, not a feed whose updates precede their dependencies.
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
    // A remote update, not a local one to commit. Replays need no projection or surface work.
    guard transactionUpdate.take() != nil else { return }
    updateHistoryAvailability()
    try publishSurfaceChanges()
  }

  private func publishSurfaceChanges(moveCaretToEditEnd: Bool = false) throws {
    let delta = transactionDelta.take() ?? []
    // Concurrent deletion can make a mark update change only the semantic feature manifest.
    snapshot = try SemanticSnapshot(body: body, in: doc)
    guard !delta.isEmpty else { return }
    let edits = Self.edits(from: delta)
    text = snapshot.text
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
    updateSelectedFormatting(resetTyping: true)
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
  func session(accountNamespace: String, documentID: String, clientID: UInt64? = nil, plugins: FeaturePlugins? = nil) throws -> DocumentSession {
    let metadata = try store.openOrCreateDocument(accountNamespace: accountNamespace, documentID: documentID)
    if let live = sessions[metadata.key] {
      if let plugins { try live.setPlugins(plugins) }
      return live
    }
    let session = try DocumentSession(metadata: metadata, store: store, clientID: clientID, plugins: plugins ?? FeaturePlugins())
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
