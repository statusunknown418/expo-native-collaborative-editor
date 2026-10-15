import Foundation
import SwiftYrs

/// The explicit block model (docs/adr/0008-explicit-block-document-model.md). `body` holds every
/// block's text: the head block's text first, then for each other block an LF labeled
/// `block: <key>` followed by that block's text. `blocks` holds block properties under flat
/// `<key>/<field>` keys; `order` lists block keys in sibling order. Moving a block changes only its
/// properties, never its text, so concurrent edits inside it move with it.
enum BlockModel {
  /// The block before the first labeled LF. Every document has it without a write.
  static let head = "head"
  /// The `body` LF attribute that starts a block.
  static let label = "block"
}

/// One block's stored properties.
struct BlockFields {
  var kind: ListKind?
  var id: String?
  var parent: String?
  var checked = false
  /// Hidden while its text is empty; its children are promoted. Only the head block, which has no
  /// LF to delete, is removed this way.
  var removed = false
}

/// The stored `blocks` map entry names, `<key>/<field>`.
enum BlockField: String {
  case kind, id, parent, checked, removed
}

/// A position inside a block's text, which survives structural moves.
struct BlockPosition: Equatable {
  let key: String
  let offset: Int
}

/// The deterministic projection of the stored blocks to display paragraphs and a semantic snapshot.
/// It never writes: malformed or conflicting structure (cycles, missing parents, duplicate IDs or
/// labels) projects the same way on every replica.
struct BlockProjection {
  /// A present block's text in `body`, in body order.
  struct Segment {
    let key: String
    /// Body offset of the block's labeled LF; `nil` for the head block.
    let lf: Int?
    /// Body offset of the block's first text unit.
    let start: Int
    let lfAttributes: YAttributes
    var length = 0
    var text = ""
    var chunks: [(String, YAttributes)] = []
    var end: Int { start + length }
  }

  /// A visible block in display order. Display paragraphs are joined by one LF.
  struct Paragraph {
    let key: String
    let offset: Int
    let length: Int
    let segment: Int
    let item: SemanticListItem?
    var end: Int { offset + length }
  }

  let segments: [Segment]
  let segmentIndex: [String: Int]
  let fields: [String: BlockFields]
  let paragraphs: [Paragraph]
  let paragraphIndex: [String: Int]
  /// Tree parent of every node (present blocks and the removed ones they still name), after cycles
  /// are cut.
  let parent: [String: String]
  /// Each node's children in sibling order; roots under "".
  let children: [String: [String]]
  let snapshot: SemanticSnapshot
}

extension BlockProjection {
  init(document doc: YDoc) throws {
    let body = try doc.text(named: "body")
    let blocks = try doc.map(named: "blocks")
    let order = try doc.array(named: "order")
    let features = try doc.map(named: "features")
    self = try doc.read { try BlockProjection($0, body: body, blocks: blocks, order: order, features: features) }
  }

  init(_ transaction: YReadTransaction, body: YText, blocks: YMap, order: YArray, features: YMap) throws {
    self.init(chunks: try transaction.chunks(from: body), entries: try transaction.entriesJSON(from: blocks),
      order: try transaction.valuesJSON(from: order),
      features: try transaction.entriesJSON(from: features).keys.sorted(by: precedes))
  }

  init(chunks: [YTextChunk], entries: [String: Any], order: [Any], features: [String]) {
    // Segments: a first-seen labeled LF starts a block; any other LF is a line break inside one.
    var segments = [Segment(key: BlockModel.head, lf: nil, start: 0, lfAttributes: [:])]
    var labels: Set<String> = [BlockModel.head]
    var offset = 0
    for chunk in chunks {
      guard case .string(let value) = chunk.insert else {
        // ponytail: embeds occupy one body offset but are not projected until record references (#15).
        offset += 1
        continue
      }
      let string = value as NSString
      var pieceStart = 0
      if case .string(let key) = chunk.attributes[BlockModel.label], !key.isEmpty, !labels.contains(key) {
        let lf = string.range(of: "\n").location
        if lf != NSNotFound {
          segments[segments.count - 1].append(string.substring(to: lf), chunk.attributes)
          labels.insert(key)
          segments.append(Segment(key: key, lf: offset + lf, start: offset + lf + 1, lfAttributes: chunk.attributes))
          pieceStart = lf + 1
        }
      }
      segments[segments.count - 1].append(string.substring(from: pieceStart), chunk.attributes)
      offset += string.length
    }
    let segmentIndex = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($1.key, $0) })

    var fields: [String: BlockFields] = [:]
    for (entry, value) in entries {
      guard let slash = entry.lastIndex(of: "/") else { continue }
      let key = String(entry[..<slash])
      guard !key.isEmpty else { continue }
      switch BlockField(rawValue: String(entry[entry.index(after: slash)...])) {
      case .kind: fields[key, default: BlockFields()].kind = (value as? String).flatMap(ListKind.init)
      case .id: if let id = value as? String, !id.isEmpty { fields[key, default: BlockFields()].id = id }
      case .parent: if let parent = value as? String, !parent.isEmpty, parent != key { fields[key, default: BlockFields()].parent = parent }
      case .checked: fields[key, default: BlockFields()].checked = isTrue(value)
      case .removed: fields[key, default: BlockFields()].removed = isTrue(value)
      case nil: break
      }
    }

    // Sibling rank: the first occurrence in `order`. A present block missing from it follows its body
    // predecessor; a removed block missing from it sorts last.
    var ranked: [String] = []
    var rankedKeys: Set<String> = []
    for case let key as String in order where key != BlockModel.head && rankedKeys.insert(key).inserted {
      ranked.append(key)
    }
    for (index, segment) in segments.enumerated().dropFirst() where rankedKeys.insert(segment.key).inserted {
      let predecessor = segments[index - 1].key
      ranked.insert(segment.key, at: predecessor == BlockModel.head ? 0 : ranked.firstIndex(of: predecessor)! + 1)
    }
    var rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
    rank[BlockModel.head] = -1

    // Tree: list blocks keep their declared parent, present or removed; ordinary paragraphs and the
    // head block are roots.
    var parent: [String: String] = [:]
    var nodes = segments.map(\.key)
    var known = Set(nodes)
    var pending = nodes
    while let key = pending.popLast() {
      guard key != BlockModel.head, segmentIndex[key] == nil || fields[key]?.kind != nil,
        let declared = fields[key]?.parent else { continue }
      parent[key] = declared
      if known.insert(declared).inserted {
        nodes.append(declared)
        pending.append(declared)
      }
    }
    // Each cycle becomes a tree rooted at its smallest key.
    var visited: [String: Bool] = [:]  // false while on the current path
    for start in nodes where visited[start] == nil {
      var path: [String] = []
      var current: String? = start
      while let node = current, visited[node] == nil {
        visited[node] = false
        path.append(node)
        current = parent[node]
      }
      if let node = current, visited[node] == false, let first = path.firstIndex(of: node) {
        parent[path[first...].min(by: precedes)!] = nil
      }
      for node in path { visited[node] = true }
    }
    var children: [String: [String]] = [:]
    for node in nodes { children[parent[node] ?? "", default: []].append(node) }
    for key in children.keys {
      children[key]!.sort { lhs, rhs in
        let left = rank[lhs] ?? .max
        let right = rank[rhs] ?? .max
        return left != right ? left < right : precedes(lhs, rhs)
      }
    }

    // Preorder: removed or ordinary blocks pass their list ancestry to their children unchanged.
    var paragraphs: [Paragraph] = []
    var marks: [SemanticMark] = []
    var items: [SemanticListItem] = []
    var ids: Set<String> = []
    var text = ""
    var displayOffset = 0
    func mark(_ attributes: YAttributes, length: Int) {
      let formatting = TextFormatting(attributes: attributes)
      if formatting != TextFormatting(), length > 0 {
        if let last = marks.last, last.offset + last.length == displayOffset, last.formatting == formatting {
          marks[marks.count - 1].length += length
        } else {
          marks.append(SemanticMark(offset: displayOffset, length: length, formatting: formatting))
        }
      }
      displayOffset += length
    }
    var stack: [(String, [String])] = (children[""] ?? []).reversed().map { ($0, []) }
    while let (key, ancestors) = stack.popLast() {
      var childAncestors = ancestors
      if let index = segmentIndex[key], !(fields[key]?.removed == true && segments[index].length == 0) {
        let segment = segments[index]
        if !paragraphs.isEmpty {
          text.append("\n")
          mark(segment.lfAttributes, length: 1)
        }
        var item: SemanticListItem?
        if let kind = fields[key]?.kind, ids.insert(fields[key]?.id ?? key).inserted {
          item = SemanticListItem(id: fields[key]?.id ?? key, kind: kind, parent: ancestors.last,
            checked: kind == .checklist ? fields[key]?.checked == true : nil,
            offset: displayOffset, length: segment.length, depth: ancestors.count)
          items.append(item!)
          childAncestors.append(item!.id)
        }
        paragraphs.append(Paragraph(key: key, offset: displayOffset, length: segment.length, segment: index, item: item))
        text.append(segment.text)
        for (piece, attributes) in segment.chunks { mark(attributes, length: (piece as NSString).length) }
      }
      for child in (children[key] ?? []).reversed() { stack.append((child, childAncestors)) }
    }
    // A removed, empty head block still holds the caret when no other block is visible.
    if paragraphs.isEmpty { paragraphs.append(Paragraph(key: BlockModel.head, offset: 0, length: 0, segment: 0, item: nil)) }

    self.segments = segments
    self.segmentIndex = segmentIndex
    self.fields = fields
    self.paragraphs = paragraphs
    paragraphIndex = Dictionary(uniqueKeysWithValues: paragraphs.enumerated().map { ($1.key, $0) })
    self.parent = parent
    self.children = children
    snapshot = SemanticSnapshot(text: text, marks: marks.isEmpty ? nil : marks,
      features: features.isEmpty ? nil : features, listItems: items.isEmpty ? nil : items)
  }

  /// The paragraph whose text or end holds display `offset`.
  func paragraph(containing offset: Int) -> Paragraph? {
    var low = 0
    var high = paragraphs.count - 1
    while low <= high {
      let middle = (low + high) / 2
      if paragraphs[middle].end < offset { low = middle + 1 } else if paragraphs[middle].offset > offset { high = middle - 1 } else { return paragraphs[middle] }
    }
    return nil
  }

  func paragraph(item id: String) -> Paragraph? {
    paragraphs.first { $0.item?.id == id }
  }

  func position(of offset: Int) -> BlockPosition? {
    paragraph(containing: offset).map { BlockPosition(key: $0.key, offset: offset - $0.offset) }
  }

  func offset(of position: BlockPosition) -> Int? {
    paragraphIndex[position.key].map { paragraphs[$0].offset + min(position.offset, paragraphs[$0].length) }
  }

  /// Body offset of a paragraph's text at `offset` units into it.
  func bodyOffset(_ paragraph: Paragraph, _ offset: Int) -> Int {
    segments[paragraph.segment].start + offset
  }

  func isAncestor(_ ancestor: String, of key: String) -> Bool {
    var current = parent[key]
    while let node = current {
      if node == ancestor { return true }
      current = parent[node]
    }
    return false
  }

  /// Body ranges holding display `range`: each paragraph's text, plus for an included joiner the
  /// labeled LF of the paragraph it starts.
  func bodyRanges(for range: Range<Int>) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    for (index, paragraph) in paragraphs.enumerated() where paragraph.offset <= range.upperBound && paragraph.end >= range.lowerBound {
      let lower = max(range.lowerBound, paragraph.offset)
      let upper = min(range.upperBound, paragraph.end)
      if lower < upper { ranges.append(bodyOffset(paragraph, lower - paragraph.offset)..<bodyOffset(paragraph, upper - paragraph.offset)) }
      if range.contains(paragraph.end), index + 1 < paragraphs.count, let lf = segments[paragraphs[index + 1].segment].lf {
        ranges.append(lf..<(lf + 1))
      }
    }
    return ranges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, range in
      if let last = merged.last, last.upperBound == range.lowerBound {
        merged[merged.count - 1] = last.lowerBound..<range.upperBound
      } else {
        merged.append(range)
      }
    }
  }
}

// MARK: - Surface edits

extension BlockProjection {
  /// The display edits that turn this projection's text into `new`'s, in application order, each
  /// offset into the text the edits before it produced. They are exact (from the body `delta`) when
  /// every visible block keeps its place; otherwise paragraphs are aligned by block, keeping the most
  /// text in place, and only the others are replaced.
  func surfaceEdits(to new: BlockProjection, delta: [YTextDeltaOperation]) -> (edits: [TextEdit], exact: Bool) {
    if let edits = exactEdits(to: new, delta: delta) { return (edits, true) }
    let edits = paragraphEdits(to: new)
    if applying(edits, to: snapshot.text)?.utf16.elementsEqual(new.snapshot.text.utf16) == true { return (edits, false) }
    return (TextEdit(from: snapshot.text, to: new.snapshot.text).map { [$0] } ?? [], false)
  }

  private func exactEdits(to new: BlockProjection, delta: [YTextDeltaOperation]) -> [TextEdit]? {
    guard paragraphs.map(\.key) == new.paragraphs.map(\.key) else { return nil }
    // Per block: edits offset into its evolving text, and their net length change.
    var blockEdits: [String: [TextEdit]] = [:]
    var shift: [String: Int] = [:]
    var cursor = 0
    func segment(holding range: Range<Int>) -> Segment? {
      guard let index = segments.lastIndex(where: { $0.start <= range.lowerBound }),
        range.upperBound <= segments[index].end, paragraphIndex[segments[index].key] != nil else { return nil }
      return segments[index]
    }
    for operation in delta {
      switch operation {
      case .retain(let length, let attributes):
        guard attributes[BlockModel.label] == nil else { return nil }
        cursor += Int(length)
      case .delete(let length):
        let range = cursor..<(cursor + Int(length))
        guard let segment = segment(holding: range) else { return nil }
        blockEdits[segment.key, default: []].append(TextEdit(utf16Offset: cursor - segment.start
          + shift[segment.key, default: 0], utf16Length: range.count, replacement: ""))
        shift[segment.key, default: 0] -= range.count
        cursor = range.upperBound
      case .insert(let value, let attributes):
        guard case .string(let inserted) = value, attributes[BlockModel.label].map({ $0 == .null }) ?? true,
          let segment = segment(holding: cursor..<cursor) else { return nil }
        blockEdits[segment.key, default: []].append(TextEdit(utf16Offset: cursor - segment.start
          + shift[segment.key, default: 0], utf16Length: 0, replacement: inserted))
        shift[segment.key, default: 0] += inserted.utf16.count
      }
    }
    var edits: [TextEdit] = []
    var before = 0
    for paragraph in paragraphs {
      for edit in blockEdits[paragraph.key] ?? [] {
        edits.append(TextEdit(utf16Offset: paragraph.offset + before + edit.utf16Offset,
          utf16Length: edit.utf16Length, replacement: edit.replacement))
      }
      before += shift[paragraph.key] ?? 0
    }
    return applying(edits, to: snapshot.text)?.utf16.elementsEqual(new.snapshot.text.utf16) == true ? edits : nil
  }

  private func paragraphEdits(to new: BlockProjection) -> [TextEdit] {
    let old = paragraphs.map { ($0.key, segments[$0.segment].text) }
    let next = new.paragraphs.map { ($0.key, new.segments[$0.segment].text) }
    func same(_ lhs: (String, String), _ rhs: (String, String)) -> Bool {
      lhs.0 == rhs.0 && lhs.1.utf16.elementsEqual(rhs.1.utf16)
    }
    var prefix = 0
    while prefix < old.count, prefix < next.count, same(old[prefix], next[prefix]) { prefix += 1 }
    var suffix = 0
    while suffix < old.count - prefix, suffix < next.count - prefix,
      same(old[old.count - 1 - suffix], next[next.count - 1 - suffix]) { suffix += 1 }
    let removed = Array(old[prefix..<(old.count - suffix)])
    let added = Array(next[prefix..<(next.count - suffix)])

    // Paragraphs of one block in both, keeping the most text in place.
    var matches: [(Int, Int)] = []
    // ponytail: quadratic alignment; past this size the changed middle is replaced instead.
    if removed.count * added.count <= 250_000 {
      let width = added.count + 1
      var kept = [Int](repeating: 0, count: (removed.count + 1) * width)
      for i in removed.indices.reversed() {
        for j in added.indices.reversed() {
          kept[i * width + j] = removed[i].0 == added[j].0
            ? removed[i].1.utf16.count + 1 + kept[(i + 1) * width + j + 1]
            : max(kept[(i + 1) * width + j], kept[i * width + j + 1])
        }
      }
      var i = 0
      var j = 0
      while i < removed.count, j < added.count {
        if removed[i].0 == added[j].0 {
          matches.append((i, j))
          i += 1
          j += 1
        } else if kept[(i + 1) * width + j] >= kept[i * width + j + 1] {
          i += 1
        } else {
          j += 1
        }
      }
    }

    // The text is the emitted new paragraphs, then the remaining old ones, joined by LFs.
    var edits: [TextEdit] = []
    var emitted = prefix
    var emittedLength = prefix > 0 ? paragraphs[prefix - 1].end : 0
    var remaining = old.count - prefix
    var start: Int { emittedLength + (emitted > 0 && remaining > 0 ? 1 : 0) }
    var i = 0
    var j = 0
    for (matchI, matchJ) in matches + [(removed.count, added.count)] {
      while i < matchI {
        let length = removed[i].1.utf16.count
        if remaining > 1 {
          edits.append(TextEdit(utf16Offset: start, utf16Length: length + 1, replacement: ""))
        } else if emitted > 0 {
          edits.append(TextEdit(utf16Offset: start - 1, utf16Length: length + 1, replacement: ""))
        } else if length > 0 {
          edits.append(TextEdit(utf16Offset: start, utf16Length: length, replacement: ""))
        }
        remaining -= 1
        i += 1
      }
      while j < matchJ {
        let text = added[j].1
        if emitted > 0 {
          edits.append(TextEdit(utf16Offset: emittedLength, utf16Length: 0, replacement: "\n" + text))
          emittedLength += 1 + text.utf16.count
        } else {
          let replacement = remaining > 0 ? text + "\n" : text
          if !replacement.isEmpty { edits.append(TextEdit(utf16Offset: 0, utf16Length: 0, replacement: replacement)) }
          emittedLength = text.utf16.count
        }
        emitted += 1
        j += 1
      }
      guard matchI < removed.count else { break }
      let offset = start
      if let edit = TextEdit(from: removed[matchI].1, to: added[matchJ].1) {
        edits.append(TextEdit(utf16Offset: offset + edit.utf16Offset, utf16Length: edit.utf16Length,
          replacement: edit.replacement))
      }
      emittedLength = offset + added[matchJ].1.utf16.count
      emitted += 1
      remaining -= 1
      i += 1
      j += 1
    }
    return edits
  }
}

/// `text` after `edits`, or `nil` if an edit falls outside the text it applies to.
func applying(_ edits: [TextEdit], to text: String) -> String? {
  let result = NSMutableString(string: text)
  for edit in edits {
    guard edit.utf16Offset >= 0, edit.utf16Offset + edit.utf16Length <= result.length else { return nil }
    result.replaceCharacters(in: NSRange(location: edit.utf16Offset, length: edit.utf16Length), with: edit.replacement)
  }
  return result as String
}

private extension BlockProjection.Segment {
  mutating func append(_ piece: String, _ attributes: YAttributes) {
    guard !piece.isEmpty else { return }
    chunks.append((piece, attributes))
    text.append(piece)
    length += (piece as NSString).length
  }
}

/// JSON booleans only: `NSNumber(1)` is not `true`, matching the JavaScript projection.
private func isTrue(_ value: Any) -> Bool {
  guard let number = value as? NSNumber else { return false }
  return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
}

/// UTF-16 code-unit order, matching JavaScript string comparison.
func precedes(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
}
