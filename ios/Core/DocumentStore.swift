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

/// SQLite store (the system `libsqlite3`) for document metadata, engine updates, the outbox, and
/// delivery positions. Every statement runs on `queue`, the serial storage executor.
final class DocumentStore: @unchecked Sendable {
  /// Yrs v1 updates to linear rich text `body` and its semantic `features` map. The original schema
  /// identifier remains while the M1 document representation is provisional.
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
    try queue.sync {
      try execute(Self.schema)
      // The manifest now travels in the CRDT, not an unsynchronized SQLite seed field.
      var hasLegacyManifest = false
      try run("PRAGMA table_info(documents)", []) {
        if String(cString: sqlite3_column_text($0, 1)) == "feature_manifest" { hasLegacyManifest = true }
      }
      if hasLegacyManifest {
        try run("SELECT feature_manifest FROM documents", []) {
          let data = Data(String(cString: sqlite3_column_text($0, 0)).utf8)
          guard try JSONDecoder().decode([String].self, from: data).isEmpty else {
            throw DocumentStoreError(code: SQLITE_MISMATCH, description: "Cannot discard a nonempty legacy feature manifest.")
          }
        }
        try execute("ALTER TABLE documents DROP COLUMN feature_manifest")
      }
    }
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
        SELECT lifecycle_generation, schema_id FROM documents
        WHERE account_namespace = ? AND document_id = ?
        ORDER BY lifecycle_generation DESC LIMIT 1
        """,
        [.text(accountNamespace), .text(documentID)]
      ) { row in
        existing = DocumentMetadata(
          key: DocumentKey(
            accountNamespace: accountNamespace, documentID: documentID,
            lifecycleGeneration: Int(sqlite3_column_int64(row, 0))),
          schemaID: String(cString: sqlite3_column_text(row, 1)))
      }
      if let existing { return existing }

      let created = DocumentMetadata(
        key: DocumentKey(accountNamespace: accountNamespace, documentID: documentID, lifecycleGeneration: 1),
        schemaID: Self.plainTextSchemaID)
      try run(
        """
        INSERT INTO documents
        (account_namespace, document_id, lifecycle_generation, schema_id)
        VALUES (?, ?, ?, ?)
        """,
        Self.keyBindings(created.key) + [.text(created.schemaID)])
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
  /// `completion` there with the operation once the commit is durable, or with the error that rolled
  /// it back.
  func append(
    _ update: Data, to key: DocumentKey,
    completion: @escaping @Sendable (Result<OutboxOperation, Error>) -> Void
  ) {
    queue.async {
      completion(
        Result {
          let operation = OutboxOperation(operationID: UUID(), update: update)
          try self.transaction {
            let sequence = try self.insert(update, for: key)
            try self.run(
              "INSERT INTO outbox (operation_id, update_sequence) VALUES (?, ?)",
              [.text(operation.operationID.uuidString), .int(sequence)])
          }
          return operation
        })
    }
  }

  /// Removes the outbox operations a receipt names, in one transaction, and returns how many of the
  /// document's operations remain pending. IDs no longer pending are ignored, so receipts can repeat.
  func acknowledge(_ operationIDs: [UUID], for key: DocumentKey) throws -> Int {
    try queue.sync {
      var pending = 0
      try transaction {
        for operationID in operationIDs {
          try run(
            """
            DELETE FROM outbox WHERE operation_id = ? AND update_sequence IN (
              SELECT sequence FROM updates
              WHERE account_namespace = ? AND document_id = ? AND lifecycle_generation = ?)
            """,
            [.text(operationID.uuidString)] + Self.keyBindings(key))
        }
        try run(
          """
          SELECT COUNT(*) FROM outbox JOIN updates ON updates.sequence = outbox.update_sequence
          WHERE account_namespace = ? AND document_id = ? AND lifecycle_generation = ?
          """,
          Self.keyBindings(key)
        ) { row in pending = Int(sqlite3_column_int64(row, 0)) }
      }
      return pending
    }
  }

  /// The last position of the document's delivery feed that has been persisted, or 0.
  func deliveredThrough(_ key: DocumentKey) throws -> Int {
    try queue.sync {
      var position = 0
      try run(
        """
        SELECT COALESCE(MAX(position), 0) FROM deliveries
        WHERE account_namespace = ? AND document_id = ? AND lifecycle_generation = ?
        """,
        Self.keyBindings(key)
      ) { row in position = Int(sqlite3_column_int64(row, 0)) }
      return position
    }
  }

  /// Durably commits a remote update with its position in the document's delivery feed, in one
  /// transaction. Remote updates join the document's updates but never its outbox.
  func receive(_ update: Data, at position: Int, for key: DocumentKey) throws {
    try queue.sync {
      try transaction {
        let sequence = try insert(update, for: key)
        try run(
          """
          INSERT INTO deliveries
          (account_namespace, document_id, lifecycle_generation, position, update_sequence)
          VALUES (?, ?, ?, ?, ?)
          """,
          Self.keyBindings(key) + [.int(position), .int(sequence)])
      }
    }
  }

  /// Adds `update` to the document's updates and returns its sequence.
  private func insert(_ update: Data, for key: DocumentKey) throws -> Int {
    try run(
      """
      INSERT INTO updates (account_namespace, document_id, lifecycle_generation, payload)
      VALUES (?, ?, ?, ?)
      """,
      Self.keyBindings(key) + [.blob(update)])
    return Int(sqlite3_last_insert_rowid(db))
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
    CREATE TABLE IF NOT EXISTS deliveries (
      account_namespace TEXT NOT NULL,
      document_id TEXT NOT NULL,
      lifecycle_generation INTEGER NOT NULL,
      position INTEGER NOT NULL,
      update_sequence INTEGER NOT NULL UNIQUE REFERENCES updates (sequence),
      PRIMARY KEY (account_namespace, document_id, lifecycle_generation, position)
    ) STRICT;
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

  /// Runs `body` in one write transaction, rolling it back if `body` throws.
  private func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
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
