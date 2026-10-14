import Foundation

/// One contiguous replacement in engine coordinates: Yrs text offsets count UTF-16 code units
/// (SwiftYrs creates every document with `OffsetKind::Utf16`), Swift `String` indices do not.
struct TextEdit: Equatable {
  /// UTF-16 offset of the replaced range in the old text.
  let utf16Offset: Int
  /// UTF-16 length of the replaced range in the old text.
  let utf16Length: Int
  let replacement: String

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
}
