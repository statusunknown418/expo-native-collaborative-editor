import Foundation
import SwiftYrs

enum ListKind: String, Codable, CaseIterable {
  case ordered, unordered, checklist
}

struct SemanticListItem: Codable, Equatable {
  let id: String
  var kind: ListKind
  var parent: String?
  var checked: Bool?
  let offset: Int
  let length: Int
  var depth: Int

  var separator: Int { offset + length }
  var end: Int { separator + 1 }
}

extension SemanticSnapshot {
  func listItem(at offset: Int) -> SemanticListItem? {
    listItems?.first { $0.offset <= offset && offset <= $0.separator }
  }

  func listSubtree(of item: SemanticListItem) -> [SemanticListItem] {
    guard let items = listItems, let index = items.firstIndex(where: { $0.id == item.id }) else { return [] }
    var end = index + 1
    var previousEnd = item.end
    while end < items.count, items[end].offset == previousEnd, items[end].depth > item.depth {
      previousEnd = items[end].end
      end += 1
    }
    return Array(items[index..<end])
  }
}

// MARK: - Block editing

extension DocumentSession {
  /// Replaces display `range` within one transaction, as a native text edit would. Paragraphs the range
  /// covers entirely are removed (their unselected children are promoted). If the range starts inside
  /// a paragraph and ends in a later one, that later paragraph's remaining text, and its children,
  /// join the first, which keeps its identity. Each LF in `replacement` splits the paragraph like
  /// Return. Returns the position after the inserted text.
  func replaceBlocks(in range: Range<Int>, with replacement: String, formatting: TextFormatting,
    transaction: YWriteTransaction) throws -> BlockPosition {
    guard let first = projection.paragraph(containing: range.lowerBound),
      let last = projection.paragraph(containing: range.upperBound),
      let firstIndex = projection.paragraphIndex[first.key],
      let lastIndex = projection.paragraphIndex[last.key]
    else { throw DocumentSessionError.invalidRange }
    var removed = lastIndex > firstIndex + 1 ? Array(projection.paragraphs[(firstIndex + 1)..<lastIndex]) : []
    if first.key == last.key {
      return try rewrite(first, keeping: range.lowerBound - first.offset, through: nil,
        dropping: range.upperBound - first.offset, removing: removed, inserting: replacement,
        formatting: formatting, transaction: transaction)
    }
    if range.lowerBound == first.offset {
      removed.insert(first, at: 0)
      return try rewrite(last, keeping: 0, through: nil, dropping: range.upperBound - last.offset,
        removing: removed, inserting: replacement, formatting: formatting, transaction: transaction)
    }
    return try rewrite(first, keeping: range.lowerBound - first.offset, through: last,
      dropping: range.upperBound - last.offset, removing: removed, inserting: replacement,
      formatting: formatting, transaction: transaction)
  }

  /// Keeps `survivor`'s first `keep` units, removes `removed`, and appends `joined`'s text after its
  /// first `drop` units (or, without `joined`, `survivor`'s own text after `drop`), then inserts
  /// `replacement` at the seam. `joined`'s children move under `survivor` after its own children,
  /// unless `survivor` is their ancestor already.
  private func rewrite(_ survivor: BlockProjection.Paragraph, keeping keep: Int,
    through joined: BlockProjection.Paragraph?, dropping drop: Int, removing removed: [BlockProjection.Paragraph],
    inserting replacement: String, formatting: TextFormatting, transaction: YWriteTransaction) throws -> BlockPosition {
    let projection = projection
    let insertion = projection.bodyOffset(survivor, keep)
    var deletions = try removeBlocks(removed, deleting: false, transaction: transaction)
    var copied: [(String, YAttributes)] = []
    if let joined {
      let removedKeys = Set(removed.map(\.key))
      if joined.segment > survivor.segment,
        projection.segments[(survivor.segment + 1)..<joined.segment].allSatisfy({ removedKeys.contains($0.key) }) {
        // The joined text already follows the survivor's in the body: delete through it at once.
        deletions.removeAll { $0.lowerBound >= insertion && $0.upperBound <= projection.bodyOffset(joined, 0) }
        deletions.append(insertion..<projection.bodyOffset(joined, drop))
      } else {
        deletions.append(insertion..<projection.segments[survivor.segment].end)
        deletions.append(projection.segments[joined.segment].lf!..<projection.segments[joined.segment].end)
        copied = projection.segments[joined.segment].chunks(from: drop)
      }
      if !projection.isAncestor(survivor.key, of: joined.key) {
        var anchor = projection.children[survivor.key]?.last ?? survivor.key
        for child in projection.children[joined.key] ?? [] {
          try setBlockField(.parent, of: child, to: .string(survivor.key), transaction: transaction)
          try place(child, after: anchor, transaction: transaction)
          anchor = child
        }
      }
    } else {
      deletions.append(insertion..<projection.bodyOffset(survivor, drop))
    }
    for range in deletions.sorted(by: { $0.lowerBound > $1.lowerBound }) where !range.isEmpty {
      try transaction.remove(from: body, at: UInt32(range.lowerBound), length: UInt32(range.count))
    }
    var cursor = insertion - deletions.filter { $0.upperBound <= insertion }.reduce(0) { $0 + $1.count }

    var position = BlockPosition(key: survivor.key, offset: keep)
    var anchor = survivor.key
    for (index, piece) in replacement.components(separatedBy: "\n").enumerated() {
      if index > 0 {
        let key = UUID().uuidString
        var attributes = insertionAttributes(formatting)
        attributes[BlockModel.label] = .string(key)
        try transaction.insert("\n", into: body, at: UInt32(cursor), attributes: attributes)
        cursor += 1
        if let item = survivor.item {
          try setBlockField(.kind, of: key, to: .string(item.kind.rawValue), transaction: transaction)
          try setBlockField(.parent, of: key, to: projection.parent[survivor.key].map(YValue.string),
            transaction: transaction)
        }
        try place(key, after: anchor, transaction: transaction)
        anchor = key
        position = BlockPosition(key: key, offset: 0)
      }
      if !piece.isEmpty {
        try transaction.insert(piece, into: body, at: UInt32(cursor), attributes: insertionAttributes(formatting))
        cursor += piece.utf16.count
        position = BlockPosition(key: position.key, offset: position.offset + piece.utf16.count)
      }
    }
    for (piece, attributes) in copied {
      var attributes = attributes
      attributes[BlockModel.label] = .null
      try transaction.insert(piece, into: body, at: UInt32(cursor), attributes: attributes)
      cursor += piece.utf16.count
    }
    if !replacement.isEmpty { try recordFeatures(formatting.features, in: transaction) }
    return position
  }

  /// Removes blocks: their LF and text, or for the head block, which has no LF, its text and a
  /// `removed` mark. Children of removed blocks are promoted. Returns the body ranges to delete
  /// rather than deleting them when `deleting` is false.
  @discardableResult
  func removeBlocks(_ paragraphs: [BlockProjection.Paragraph], deleting: Bool = true,
    transaction: YWriteTransaction) throws -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    for paragraph in paragraphs {
      let segment = projection.segments[paragraph.segment]
      if let lf = segment.lf {
        ranges.append(lf..<segment.end)
      } else {
        ranges.append(segment.start..<segment.end)
        try setBlockField(.removed, of: paragraph.key, to: .bool(true), transaction: transaction)
      }
    }
    guard deleting else { return ranges }
    for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) where !range.isEmpty {
      try transaction.remove(from: body, at: UInt32(range.lowerBound), length: UInt32(range.count))
    }
    return []
  }

  /// `nil` removes the field.
  func setBlockField(_ field: BlockField, of key: String, to value: YValue?, transaction: YWriteTransaction) throws {
    let entry = "\(key)/\(field.rawValue)"
    if let value {
      try transaction.set(value, forKey: entry, in: blocks)
    } else {
      try transaction.remove(entry, from: blocks)
    }
  }

  /// Moves `key` in sibling order to right after `anchor`.
  func place(_ key: String, after anchor: String, transaction: YWriteTransaction) throws {
    var keys = try transaction.valuesJSON(from: order).map { $0 as? String }
    for index in keys.indices.reversed() where keys[index] == key {
      try transaction.remove(from: order, at: UInt32(index), length: 1)
      keys.remove(at: index)
    }
    let index = anchor == BlockModel.head ? 0 : keys.firstIndex(of: anchor).map { $0 + 1 } ?? keys.count
    try transaction.insert(.string(key), into: order, at: UInt32(index))
  }

  /// Inserted text never inherits a block label; formatting is explicit.
  private func insertionAttributes(_ formatting: TextFormatting) -> YAttributes {
    var attributes: YAttributes = [BlockModel.label: .null]
    attributes.merge(formatting.attributes) { _, new in new }
    return attributes
  }
}

private extension BlockProjection.Segment {
  /// Text runs after the first `offset` units.
  func chunks(from offset: Int) -> [(String, YAttributes)] {
    var skipped = 0
    var runs: [(String, YAttributes)] = []
    for (piece, attributes) in chunks {
      let string = piece as NSString
      let start = max(0, min(string.length, offset - skipped))
      if start < string.length { runs.append((string.substring(from: start), attributes)) }
      skipped += string.length
    }
    return runs
  }
}

// MARK: - List commands

extension DocumentSession {
  private func requireListCommand() throws {
    guard !isClosed else { throw DocumentSessionError.closed }
    guard !hasMarkedText else { throw DocumentSessionError.unsavedInput }
    try validate(selection)
  }

  func setListKind(_ kind: ListKind?, itemID: String? = nil) throws {
    try requireListCommand()
    if let kind {
      let enabled: Bool
      switch kind {
      case .ordered: enabled = plugins.lists?.ordered == true
      case .unordered: enabled = plugins.lists?.unordered == true
      case .checklist: enabled = plugins.lists?.checklist == true
      }
      guard enabled else { throw DocumentSessionError.featureDisabled }
    }
    let paragraphs = projection.paragraphs.filter {
      selection.isEmpty
        ? $0.offset <= selection.lowerBound && selection.lowerBound <= $0.end
        : $0.offset < selection.upperBound && $0.end >= selection.lowerBound
    }
    if let itemID {
      guard !itemID.isEmpty, paragraphs.count == 1,
        !(snapshot.listItems ?? []).contains(where: { $0.id == itemID && $0.offset != paragraphs[0].offset })
      else { throw DocumentSessionError.invalidRange }
    }
    guard let kind else {
      try clearListItems(paragraphs.filter { $0.item != nil })
      return
    }
    try performListEdit { transaction in
      for paragraph in paragraphs {
        try setListKind(kind, of: paragraph, itemID: itemID, transaction: transaction)
      }
      try recordFeatures(["lists.\(kind.rawValue)@1"], in: transaction)
      return nil
    }
  }

  private func setListKind(_ kind: ListKind, of paragraph: BlockProjection.Paragraph,
    itemID: String? = nil, transaction: YWriteTransaction) throws {
    try setBlockField(.kind, of: paragraph.key, to: .string(kind.rawValue), transaction: transaction)
    if paragraph.item == nil {
      // An ordinary paragraph becomes a root item with a fresh identity.
      try setBlockField(.parent, of: paragraph.key, to: nil, transaction: transaction)
      try setBlockField(.id, of: paragraph.key, to: itemID.map(YValue.string), transaction: transaction)
    }
    if kind == .checklist, paragraph.item?.kind != .checklist {
      try setBlockField(.checked, of: paragraph.key, to: .bool(false), transaction: transaction)
    }
  }

  /// Ordinary paragraphs are roots. A nested item leaves its enclosing tree, after it, so its
  /// unselected siblings keep their parent; its children are promoted in place.
  private func clearListItems(_ paragraphs: [BlockProjection.Paragraph]) throws {
    guard !paragraphs.isEmpty else { return }
    try performListEdit { transaction in
      var placed: [String: String] = [:]
      for paragraph in paragraphs {
        if paragraph.item?.depth ?? 0 > 0 {
          var root = paragraph.key
          while let parent = projection.parent[root] { root = parent }
          try place(paragraph.key, after: placed[root] ?? root, transaction: transaction)
          placed[root] = paragraph.key
        }
        for field in [BlockField.kind, .parent, .id, .checked] {
          try setBlockField(field, of: paragraph.key, to: nil, transaction: transaction)
        }
      }
      return nil
    }
  }

  func indentListItem() throws {
    try requireListCommand()
    guard let paragraph = projection.paragraph(containing: selection.lowerBound), let item = paragraph.item,
      let previous = previousSibling(of: item),
      // The preceding sibling's subtree ends immediately before this item.
      snapshot.listSubtree(of: previous).last?.end == item.offset,
      let parent = projection.paragraph(item: previous.id)
    else { return }
    try performListEdit { transaction in
      try setBlockField(.parent, of: paragraph.key, to: .string(parent.key), transaction: transaction)
      try place(paragraph.key, after: projection.children[parent.key]?.last ?? parent.key, transaction: transaction)
      return nil
    }
  }

  /// Moves the item and its subtree after its parent's subtree, one level up.
  func outdentListItem() throws {
    try requireListCommand()
    guard let paragraph = projection.paragraph(containing: selection.lowerBound), let item = paragraph.item
    else { return }
    if item.depth == 0 {
      try setListKind(nil)
      return
    }
    guard let parentID = item.parent, let parent = projection.paragraph(item: parentID) else { return }
    try performListEdit { transaction in
      try setBlockField(.parent, of: paragraph.key, to: projection.parent[parent.key].map(YValue.string),
        transaction: transaction)
      try place(paragraph.key, after: parent.key, transaction: transaction)
      return nil
    }
  }

  func insertReturn() throws {
    try requireListCommand()
    if selection.isEmpty, let item = projection.paragraph(containing: selection.lowerBound)?.item, item.length == 0 {
      if item.depth > 0 { try outdentListItem() } else { try setListKind(nil) }
      return
    }
    let range = selection
    let formatting = typingFormatting
    try performListEdit { transaction in
      try replaceBlocks(in: range, with: "\n", formatting: formatting, transaction: transaction)
    }
  }

  func deleteBackward() throws {
    try requireListCommand()
    let formatting = typingFormatting
    if !selection.isEmpty {
      let range = selection
      try performListEdit { transaction in
        try replaceBlocks(in: range, with: "", formatting: formatting, transaction: transaction)
      }
      return
    }
    let caret = selection.lowerBound
    if let paragraph = projection.paragraph(containing: caret), let item = paragraph.item, paragraph.offset == caret {
      guard let left = previousSibling(of: item), let survivor = projection.paragraph(item: left.id) else {
        if item.depth > 0 { try outdentListItem() } else { try setListKind(nil) }
        return
      }
      try performListEdit { transaction in
        try rewrite(survivor, keeping: survivor.length, through: paragraph, dropping: 0, removing: [],
          inserting: "", formatting: formatting, transaction: transaction)
      }
      return
    }
    guard caret > 0 else { return }
    let range = (text as NSString).rangeOfComposedCharacterSequence(at: caret - 1)
    try performListEdit { transaction in
      try replaceBlocks(in: range.location..<(range.location + range.length), with: "", formatting: formatting,
        transaction: transaction)
    }
  }

  func removeListItem(_ id: String, includingChildren: Bool = false) throws {
    try requireListCommand()
    guard let paragraph = projection.paragraph(item: id), let item = paragraph.item else { return }
    let removed = includingChildren
      ? snapshot.listSubtree(of: item).compactMap { projection.paragraph(item: $0.id) } : [paragraph]
    try performListEdit { transaction in
      try removeBlocks(removed, transaction: transaction)
      return nil
    }
  }

  func toggleChecklistItem(_ id: String) throws {
    try requireListCommand()
    guard let item = snapshot.listItems?.first(where: { $0.id == id }), item.kind == .checklist else { return }
    let checked = item.checked != true
    // Disabled means no descendant traversal, not a traversal followed by discarded edits.
    let targets = plugins.lists?.caution__enableChecklistChildrenAutoCompletion == true
      ? snapshot.listSubtree(of: item).filter { $0.kind == .checklist } : [item]
    try performListEdit { transaction in
      for target in targets {
        guard let paragraph = projection.paragraph(item: target.id) else { continue }
        try setBlockField(.checked, of: paragraph.key, to: .bool(checked), transaction: transaction)
      }
      return nil
    }
  }

  func handleListInput(in range: Range<Int>, replacement: String) throws -> Bool {
    guard !hasMarkedText else { return false }
    try validate(range)
    if replacement == " ", plugins.lists?.unordered == true, range.isEmpty, range == selection,
      let paragraph = projection.paragraph(containing: range.lowerBound), paragraph.item == nil,
      range.lowerBound == paragraph.offset + 1, (text as NSString).character(at: paragraph.offset) == 45 {
      let formatting = typingFormatting
      // Commit the typed space first: undoing only the shortcut must restore literal "- ".
      try performListEdit { transaction in
        try replaceBlocks(in: range, with: " ", formatting: formatting, transaction: transaction)
      }
      try performListEdit { transaction in
        let caret = try replaceBlocks(in: paragraph.offset..<(paragraph.offset + 2), with: "",
          formatting: formatting, transaction: transaction)
        try setListKind(.unordered, of: paragraph, transaction: transaction)
        try recordFeatures(["lists.unordered@1"], in: transaction)
        return caret
      }
      return true
    }
    if replacement == "\n", snapshot.listItem(at: range.lowerBound) != nil {
      selection = range
      try insertReturn()
      return true
    }
    if replacement.isEmpty, selection.isEmpty, range.upperBound == selection.lowerBound,
      let item = snapshot.listItem(at: selection.lowerBound), item.offset == selection.lowerBound {
      try deleteBackward()
      return true
    }
    return false
  }

  private func previousSibling(of item: SemanticListItem) -> SemanticListItem? {
    guard let items = snapshot.listItems, let index = items.firstIndex(where: { $0.id == item.id }),
      index > 0 else { return nil }
    var cursor = index - 1
    var nextOffset = item.offset
    while true {
      let previous = items[cursor]
      guard previous.end == nextOffset, previous.depth >= item.depth else { return nil }
      if previous.depth == item.depth { return previous.parent == item.parent ? previous : nil }
      nextOffset = previous.offset
      guard cursor > 0 else { return nil }
      cursor -= 1
    }
  }
}
