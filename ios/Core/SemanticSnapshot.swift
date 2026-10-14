import SwiftYrs

/// Engine-independent projection of a document's content. The engine's JavaScript implementation
/// produces the same value from the same updates (`fixtures/semanticSnapshot.ts`). Format:
/// docs/development.md#semantic-snapshot.
struct SemanticSnapshot: Codable {
  /// The document text: Unicode scalars exactly as stored, never normalized.
  let text: String
}

extension SemanticSnapshot: Equatable {
  /// Compares scalars: `String ==` treats canonically equivalent text, such as `é` and `e` + U+0301,
  /// as equal.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.text.unicodeScalars.elementsEqual(rhs.text.unicodeScalars)
  }
}

extension SemanticSnapshot {
  /// Projects the committed state of `body`, the document's content in `doc`.
  init(body: YText, in doc: YDoc) throws {
    text = try doc.read { try $0.string(from: body) }
  }
}
