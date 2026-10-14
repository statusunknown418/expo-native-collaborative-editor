import Foundation

/// One contiguous replacement in engine coordinates: Yrs text offsets count UTF-16 code units
/// (SwiftYrs creates every document with `OffsetKind::Utf16`), Swift `String` indices do not.
struct TextEdit: Equatable {
  /// UTF-16 offset of the replaced range in the old text.
  let utf16Offset: Int
  /// UTF-16 length of the replaced range in the old text.
  let utf16Length: Int
  let replacement: String

  init(utf16Offset: Int, utf16Length: Int, replacement: String) {
    self.utf16Offset = utf16Offset
    self.utf16Length = utf16Length
    self.replacement = replacement
  }

  /// The smallest grapheme-cluster-aligned edit that turns `old` into `new`, or `nil` if they hold the
  /// same Unicode scalars. Characters compare by scalars, not `==`: canonically equivalent clusters
  /// (`é` and `e` + U+0301) have different UTF-16 lengths, so treating them as equal would
  /// desynchronize engine offsets.
  init?(from old: String, to new: String) {
    var oldStart = old.startIndex
    var newStart = new.startIndex
    while oldStart < old.endIndex, newStart < new.endIndex,
      old[oldStart].unicodeScalars.elementsEqual(new[newStart].unicodeScalars)
    {
      old.formIndex(after: &oldStart)
      new.formIndex(after: &newStart)
    }

    var oldEnd = old.endIndex
    var newEnd = new.endIndex
    while oldEnd > oldStart, newEnd > newStart {
      let oldLast = old.index(before: oldEnd)
      let newLast = new.index(before: newEnd)
      guard old[oldLast].unicodeScalars.elementsEqual(new[newLast].unicodeScalars) else { break }
      oldEnd = oldLast
      newEnd = newLast
    }

    if oldStart == oldEnd, newStart == newEnd { return nil }
    utf16Offset = old.utf16.distance(from: old.startIndex, to: oldStart)
    utf16Length = old.utf16.distance(from: oldStart, to: oldEnd)
    replacement = String(new[newStart..<newEnd])
  }

  /// Where a position at UTF-16 `offset` in the old text lands in the new one. A position at the
  /// start of the edit, or inside the replaced range, lands before the replacement if it
  /// `sticksToPreceding` the character before it, and after the replacement otherwise.
  func transform(_ offset: Int, sticksToPreceding: Bool) -> Int {
    if offset < utf16Offset || (offset == utf16Offset && sticksToPreceding) { return offset }
    if offset > utf16Offset, offset >= utf16Offset + utf16Length {
      return offset - utf16Length + replacement.utf16.count
    }
    return sticksToPreceding ? utf16Offset : utf16Offset + replacement.utf16.count
  }
}
