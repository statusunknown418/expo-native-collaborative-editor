import Foundation
import SwiftYrs

/// Engine-independent projection, shared with `fixtures/semanticSnapshot.ts`.
struct SemanticSnapshot: Codable {
  let text: String
  var marks: [SemanticMark]? = nil
  /// Monotonic semantic requirements, independent of enabled authoring plugins and undo history.
  var features: [String]? = nil
  var listItems: [SemanticListItem]? = nil
}

extension SemanticSnapshot: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.text.unicodeScalars.elementsEqual(rhs.text.unicodeScalars)
      && lhs.marks == rhs.marks && lhs.features == rhs.features && lhs.listItems == rhs.listItems
  }
}

extension SemanticSnapshot {
  init(document doc: YDoc) throws {
    self = try BlockProjection(document: doc).snapshot
  }

  func formatting(at offset: Int) -> TextFormatting {
    marks?.first { $0.offset <= offset && offset < $0.offset + $0.length }?.formatting ?? TextFormatting()
  }

  func selectedFormatting(in range: Range<Int>) -> SelectedFormatting {
    let offset = min(range.lowerBound, max(0, text.utf16.count - 1))
    var result = SelectedFormatting(formatting(at: offset))
    for mark in marks ?? [] where mark.offset < range.upperBound && mark.offset + mark.length > range.lowerBound {
      if result.bold != mark.formatting.bold { result.bold = nil }
      if result.italic != mark.formatting.italic { result.italic = nil }
      if result.heading != mark.formatting.heading { result.heading = nil }
    }
    let markedLength = (marks ?? []).reduce(0) {
      $0 + max(0, min($1.offset + $1.length, range.upperBound) - max($1.offset, range.lowerBound))
    }
    if markedLength < range.count {
      if result.bold == true { result.bold = nil }
      if result.italic == true { result.italic = nil }
      if result.heading != 0 { result.heading = nil }
    }
    return result
  }
}
