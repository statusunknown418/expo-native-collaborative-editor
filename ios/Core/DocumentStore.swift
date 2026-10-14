import Foundation
import SQLite3

/// Identifies one document session: a document within an account namespace, in one lifecycle generation.
struct DocumentKey: Hashable, Sendable {
  let accountNamespace: String
  let documentID: String
  let lifecycleGeneration: Int
}

/// Per-document fields stored apart from content.
struct DocumentMetadata: Equatable, Sendable {
  let key: DocumentKey
  /// Schema and update encoding of the stored content.
  let schemaID: String
  /// Semantic features the content uses.
  let featureManifest: [String]
}

/// A committed local update waiting for synchronization. The operation ID never changes once stored.
struct OutboxOperation: Equatable, Sendable {
  let operationID: UUID
  let update: Data
}

struct DocumentStoreError: Error, CustomStringConvertible {
  let code: Int32
  let description: String
}

/// SQLite store (the system `libsqlite3`) for document metadata, engine updates, and the outbox. Every
/// statement runs on `queue`, the serial storage executor.
final class DocumentStore: @unchecked Sendable {
  /// Yrs v1 updates to a single `YText` named `body`. Not frozen until the document representation is.
  static let plainTextSchemaID = "yrs-update-v1/plain-text-0"

  private let db: OpaquePointer
  private let queue: DispatchQueue

  init(url: URL, queue: DispatchQueue = DispatchQueue(label: "expo.modules.nativecollaborativeeditor.store"))
    throws
  {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(
      url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard code == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
      sqlite3_close(handle)
      throw DocumentStoreError(code: code, description: message)
    }
    db = handle
    self.queue = queue
    try queue.sync { try execute(Self.schema) }
  }

  deinit {
    sqlite3_close(db)
  }

  /// Returns the latest lifecycle generation of the document, creating generation 1 without content
  /// if none exists. Only this creating call seeds the document; reopening writes nothing.
  func openOrCreateDocument(accountNamespace: String, documentID: String) throws -> DocumentMetadata {
    try queue.sync {
      var existing: DocumentMetadata?
      try run(
        """
        SELECT lifecycle_generation, schema_id, feature_manifest FROM documents
        WHERE account_namespace = ? AND document_id = ?
        ORDER BY lifecycle_generation DESC LIMIT 1
        """,
        [.text(accountNamespace), .text(documentID)]
      ) { row in
        existing = DocumentMetadata(
          key: DocumentKey(
            accountNamespace: accountNamespace, documentID: documentID,
            lifecycleGeneration: Int(sqlite3_column_int64(row, 0))),
          schemaID: String(cString: sqlite3_column_text(row, 1)),
          featureManifest: try JSONDecoder().decode(
            [String].self, from: Data(String(cString: sqlite3_column_text(row, 2)).utf8)))
      }
      if let existing { return existing }

      let created = DocumentMetadata(
        key: DocumentKey(accountNamespace: accountNamespace, documentID: documentID, lifecycleGeneration: 1),
        schemaID: Self.plainTextSchemaID,
        featureManifest: [])
      try run(
        """
        INSERT INTO documents
        (account_namespace, document_id, lifecycle_generation, schema_id, feature_manifest)
        VALUES (?, ?, ?, ?, ?)
        """,
        Self.keyBindings(created.key) + [
          .text(created.schemaID),
          .text(String(decoding: try JSONEncoder().encode(created.featureManifest), as: UTF8.self)),
        ])
      return created
    }
  }

  /// The document's stored updates, oldest first.
  func updates(for key: DocumentKey) throws -> [Data] {
    try queue.sync {
      var updates: [Data] = []
      try run(
        """
        SELECT payload FROM updates
        WHERE account_namespace = ? AND document_id = ? AND lifecycle_generation = ?
        ORDER BY sequence
        """,
        Self.keyBindings(key)
      ) { row in updates.append(Self.blob(row, 0)) }
      return updates
    }
  }

  /// The document's outbox operations, oldest first.
  func outbox(for key: DocumentKey) throws -> [OutboxOperation] {
    try queue.sync {
      var operations: [OutboxOperation] = []
      try run(
        """
        SELECT outbox.operation_id, updates.payload FROM outbox
        JOIN updates ON updates.sequence = outbox.update_sequence
        WHERE account_namespace = ? AND document_id = ? AND lifecycle_generation = ?
        ORDER BY updates.sequence
        """,
        Self.keyBindings(key)
      ) { row in
        operations.append(
          OutboxOperation(
            operationID: UUID(uuidString: String(cString: sqlite3_column_text(row, 0)))!,
            update: Self.blob(row, 1)))
      }
      return operations
    }
  }

  /// Commits `update` and its outbox operation in one transaction on the storage executor, then calls
  /// `completion` there with `nil` once the commit is durable, or with the error that rolled it back.
  func append(_ update: Data, to key: DocumentKey, completion: @escaping @Sendable (Error?) -> Void) {
    queue.async {
      do {
        try self.execute("BEGIN IMMEDIATE")
        do {
          try self.run(
            """
            INSERT INTO updates (account_namespace, document_id, lifecycle_generation, payload)
            VALUES (?, ?, ?, ?)
            """,
            Self.keyBindings(key) + [.blob(update)])
          try self.run(
            "INSERT INTO outbox (operation_id, update_sequence) VALUES (?, ?)",
            [.text(UUID().uuidString), .int(Int(sqlite3_last_insert_rowid(self.db)))])
          try self.execute("COMMIT")
        } catch {
          try? self.execute("ROLLBACK")
          throw error
        }
        completion(nil)
      } catch {
        completion(error)
      }
    }
  }

  // MARK: - SQLite

  // `synchronous = FULL` with `fullfsync` makes each commit reach stable storage before it returns.
  private static let schema = """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = FULL;
    PRAGMA fullfsync = ON;
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS documents (
      account_namespace TEXT NOT NULL,
      document_id TEXT NOT NULL,
      lifecycle_generation INTEGER NOT NULL,
      schema_id TEXT NOT NULL,
      feature_manifest TEXT NOT NULL,
      PRIMARY KEY (account_namespace, document_id, lifecycle_generation)
    ) STRICT;
    CREATE TABLE IF NOT EXISTS updates (
      sequence INTEGER PRIMARY KEY,
      account_namespace TEXT NOT NULL,
      document_id TEXT NOT NULL,
      lifecycle_generation INTEGER NOT NULL,
      payload BLOB NOT NULL,
      FOREIGN KEY (account_namespace, document_id, lifecycle_generation) REFERENCES documents
    ) STRICT;
    CREATE INDEX IF NOT EXISTS updates_by_document
      ON updates (account_namespace, document_id, lifecycle_generation, sequence);
    CREATE TABLE IF NOT EXISTS outbox (
      operation_id TEXT PRIMARY KEY,
      update_sequence INTEGER NOT NULL UNIQUE REFERENCES updates (sequence)
    ) STRICT;
    CREATE TRIGGER IF NOT EXISTS outbox_operations_are_immutable BEFORE UPDATE ON outbox
    BEGIN SELECT RAISE(ABORT, 'outbox operations are immutable'); END;
    """

  private enum Value {
    case text(String)
    case int(Int)
    case blob(Data)
  }

  private static func keyBindings(_ key: DocumentKey) -> [Value] {
    [.text(key.accountNamespace), .text(key.documentID), .int(key.lifecycleGeneration)]
  }

  private static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
  }

  private func execute(_ sql: String) throws {
    try check(sqlite3_exec(db, sql, nil, nil, nil))
  }

  private func run(_ sql: String, _ values: [Value], row: (OpaquePointer) throws -> Void = { _ in }) throws {
    var statement: OpaquePointer?
    try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in values.enumerated() {
      let position = Int32(index + 1)
      switch value {
      case .text(let text): try check(sqlite3_bind_text(statement, position, text, -1, transient))
      case .int(let int): try check(sqlite3_bind_int64(statement, position, Int64(int)))
      case .blob(let data):
        try check(
          data.withUnsafeBytes {
            sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient)
          })
      }
    }
    while true {
      let code = sqlite3_step(statement)
      guard code == SQLITE_ROW else { return try check(code) }
      try row(statement!)
    }
  }

  private func check(_ code: Int32) throws {
    guard code != SQLITE_OK, code != SQLITE_DONE else { return }
    throw DocumentStoreError(code: code, description: String(cString: sqlite3_errmsg(db)))
  }
}
