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

  var attributes: YAttributes {
    var attributes: YAttributes = [
      "listID": .string(id), "listKind": .string(kind.rawValue), "listDepth": .int(Int64(depth)),
      "listChecked": .null,
    ]
    if kind == .checklist { attributes["listChecked"] = .bool(checked == true) }
    return attributes
  }
}

/// Candidate 1 stores structure only on real paragraph terminators, never on item text.
let clearedListAttributes: YAttributes = [
  "listID": .null, "listKind": .null, "listDepth": .null, "listChecked": .null,
]

struct ListParagraph {
  let offset: Int
  let length: Int
  let terminated: Bool
  var separator: Int { offset + length }
}

func listParagraphs(in text: String) -> [ListParagraph] {
  var result: [ListParagraph] = []
  var start = 0
  for (offset, unit) in text.utf16.enumerated() where unit == 10 {
    result.append(ListParagraph(offset: start, length: offset - start, terminated: true))
    start = offset + 1
  }
  result.append(ListParagraph(offset: start, length: text.utf16.count - start, terminated: false))
  return result
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

/// Projects malformed remote data deterministically without rewriting the document on open.
func projectedListItems(chunks: [(String, YAttributes)]) -> [SemanticListItem] {
  var items: [SemanticListItem] = []
  var ancestors: [String] = []
  var seen: Set<String> = []
  var offset = 0
  var paragraphStart = 0
  for (value, attributes) in chunks {
    for unit in value.utf16 {
      if unit == 10 {
        let depth: Int?
        switch attributes["listDepth"] {
        case .int(let value) where value >= 0 && value <= Int64(Int.max): depth = Int(value)
        case .double(let value) where value.isFinite && value >= 0 && value.rounded(.towardZero) == value:
          depth = Int(min(value, Double(ancestors.count)))
        default: depth = nil
        }
        if case .string(let id) = attributes["listID"], !id.isEmpty,
          case .string(let rawKind) = attributes["listKind"], let kind = ListKind(rawValue: rawKind),
          let rawDepth = depth, seen.insert(id).inserted {
          let canonicalDepth = min(rawDepth, ancestors.count)
          ancestors.removeSubrange(canonicalDepth...)
          items.append(SemanticListItem(id: id, kind: kind, parent: ancestors.last,
            checked: kind == .checklist ? attributes["listChecked"] == .bool(true) : nil,
            offset: paragraphStart, length: offset - paragraphStart, depth: canonicalDepth))
          ancestors.append(id)
        } else {
          ancestors.removeAll(keepingCapacity: true)
        }
        paragraphStart = offset + 1
      }
      offset += 1
    }
  }
  return items
}

private struct ListTextRun {
  let text: String
  var attributes: YAttributes
}

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
    let paragraphs = listParagraphs(in: text).filter {
      selection.isEmpty
        ? $0.offset <= selection.lowerBound && selection.lowerBound <= $0.separator
        : $0.offset < selection.upperBound && $0.separator >= selection.lowerBound
    }
    if let itemID {
      guard !itemID.isEmpty, paragraphs.count == 1,
        !(snapshot.listItems ?? []).contains(where: { $0.id == itemID && $0.offset != paragraphs[0].offset })
      else { throw DocumentSessionError.invalidRange }
    }
    guard let kind else {
      try clearListItems(paragraphs.compactMap { snapshot.listItem(at: $0.offset)?.id })
      return
    }
    try performListEdit { transaction in
      for paragraph in paragraphs {
        if !paragraph.terminated {
          try transaction.insert("\n", into: body, at: UInt32(paragraph.separator),
            attributes: clearedListAttributes)
        }
        let existing = snapshot.listItem(at: paragraph.offset)
        let item = SemanticListItem(id: existing?.id ?? itemID ?? UUID().uuidString,
          kind: kind, parent: existing?.parent,
          checked: kind == .checklist ? existing?.checked ?? false : nil,
          offset: paragraph.offset, length: paragraph.length, depth: existing?.depth ?? 0)
        try transaction.format(body, at: UInt32(paragraph.separator), length: 1, attributes: item.attributes)
      }
      try recordFeatures(["lists.\(kind.rawValue)@1"], in: transaction)
      return nil
    }
  }

  /// An ordinary paragraph ends a list run. Exit the enclosing root's subtree first so an
  /// in-place conversion cannot silently adopt or detach the item's unselected siblings.
  private func clearListItems(_ ids: [String]) throws {
    guard !ids.isEmpty else { return }
    let selected = Set(ids)
    // The selected paragraphs are contiguous: selected descendants move with their selected root.
    let roots = (snapshot.listItems ?? []).filter {
      selected.contains($0.id) && ($0.parent.map { !selected.contains($0) } ?? true)
    }
    var caret = selection.lowerBound
    try performListEdit { transaction in
      // Move later sibling groups first, keeping their original order after the enclosing root.
      for original in roots.reversed() where original.depth > 0 {
        let state = try listState(in: transaction)
        let items = state.listItems ?? []
        guard let item = items.first(where: { $0.id == original.id }) else { continue }
        var root = item
        while let parentID = root.parent,
          let parent = items.first(where: { $0.id == parentID }) { root = parent }
        let subtree = state.listSubtree(of: item)
        let end = subtree.last?.end ?? item.end
        let destinationEnd = state.listSubtree(of: root).last?.end ?? end
        for descendant in subtree {
          try transaction.format(body, at: UInt32(descendant.separator), length: 1,
            attributes: ["listDepth": .int(Int64(descendant.depth - item.depth))])
        }
        if destinationEnd > end {
          let source = item.offset..<end
          let runs = try textRuns(in: source, transaction: transaction)
          try transaction.remove(from: body, at: UInt32(source.lowerBound), length: UInt32(source.count))
          let destination = destinationEnd - source.count
          try insert(runs, at: destination, transaction: transaction)
          if source.contains(caret) {
            caret = destination + caret - source.lowerBound
          } else {
            let afterRemoval = caret <= source.lowerBound ? caret : max(source.lowerBound, caret - source.count)
            caret = afterRemoval >= destination ? afterRemoval + source.count : afterRemoval
          }
        }
      }
      let state = try listState(in: transaction)
      try promoteDescendants(removing: selected, items: state.listItems ?? [], in: transaction)
      for item in state.listItems ?? [] where selected.contains(item.id) {
        try transaction.format(body, at: UInt32(item.separator), length: 1,
          attributes: clearedListAttributes)
      }
      return caret
    }
  }

  func indentListItem() throws {
    try requireListCommand()
    guard let item = snapshot.listItem(at: selection.lowerBound),
      let previous = previousSibling(of: item) else { return }
    // The preceding sibling's subtree ends immediately before this item.
    guard snapshot.listSubtree(of: previous).last?.end == item.offset else { return }
    let subtree = snapshot.listSubtree(of: item)
    try performListEdit { transaction in
      for descendant in subtree {
        try transaction.format(body, at: UInt32(descendant.separator), length: 1,
          attributes: ["listDepth": .int(Int64(descendant.depth + 1))])
      }
      return nil
    }
  }

  func outdentListItem() throws {
    try requireListCommand()
    guard let item = snapshot.listItem(at: selection.lowerBound) else { return }
    if item.depth == 0 {
      try setListKind(nil)
      return
    }
    let subtree = snapshot.listSubtree(of: item)
    guard let parent = snapshot.listItems?.first(where: { $0.id == item.parent }),
      let subtreeEnd = subtree.last?.end,
      let parentEnd = snapshot.listSubtree(of: parent).last?.end else { return }
    let relativeCaret = selection.lowerBound - item.offset
    try performListEdit { transaction in
      for descendant in subtree {
        try transaction.format(body, at: UInt32(descendant.separator), length: 1,
          attributes: ["listDepth": .int(Int64(descendant.depth - 1))])
      }
      if subtreeEnd == parentEnd { return item.offset + relativeCaret }
      let runs = try textRuns(in: item.offset..<subtreeEnd, transaction: transaction)
      try transaction.remove(from: body, at: UInt32(item.offset), length: UInt32(subtreeEnd - item.offset))
      let destination = parentEnd - (subtreeEnd - item.offset)
      try insert(runs, at: destination, transaction: transaction)
      return destination + relativeCaret
    }
  }

  func insertReturn() throws {
    try requireListCommand()
    if selection.isEmpty, let item = snapshot.listItem(at: selection.lowerBound), item.length == 0 {
      if item.depth > 0 { try outdentListItem() } else { try setListKind(nil) }
      return
    }
    let range = selection
    let formatting = typingFormatting
    try performListEdit { transaction in
      if !range.isEmpty {
        try replaceListAware(in: range, with: "", formatting: formatting, transaction: transaction)
      }
      let state = try listState(in: transaction)
      let caret = range.lowerBound
      guard let item = state.listItem(at: caret) else {
        try transaction.insert("\n", into: body, at: UInt32(caret),
          attributes: insertionAttributes(formatting))
        try recordFeatures(formatting.features, in: transaction)
        return caret + 1
      }
      let subtreeEnd = state.listSubtree(of: item).last?.end ?? item.end
      let suffix = try textRuns(in: caret..<item.separator, transaction: transaction)
      let suffixLength = item.separator - caret
      if suffixLength > 0 {
        try transaction.remove(from: body, at: UInt32(caret), length: UInt32(suffixLength))
      }
      let destination = subtreeEnd - suffixLength
      try insert(suffix, at: destination, transaction: transaction)
      let sibling = SemanticListItem(id: UUID().uuidString, kind: item.kind, parent: item.parent,
        checked: item.kind == .checklist ? false : nil, offset: destination,
        length: suffixLength, depth: item.depth)
      var attributes = insertionAttributes(formatting)
      attributes.merge(sibling.attributes) { _, new in new }
      try transaction.insert("\n", into: body, at: UInt32(destination + suffixLength), attributes: attributes)
      try recordFeatures(formatting.features, in: transaction)
      return destination
    }
  }

  func deleteBackward() throws {
    try requireListCommand()
    if !selection.isEmpty {
      let range = selection
      try performListEdit { transaction in
        try replaceListAware(in: range, with: "", formatting: typingFormatting, transaction: transaction)
        return range.lowerBound
      }
      return
    }
    let caret = selection.lowerBound
    if let item = snapshot.listItem(at: caret), item.offset == caret {
      guard let left = previousSibling(of: item) else {
        if item.depth > 0 { try outdentListItem() } else { try setListKind(nil) }
        return
      }
      let joinOffset = left.separator
      try performListEdit { transaction in
        let runs = try textRuns(in: item.offset..<item.separator, transaction: transaction)
        try transaction.remove(from: body, at: UInt32(item.offset), length: UInt32(item.length + 1))
        try insert(runs, at: joinOffset, transaction: transaction)
        return joinOffset
      }
      return
    }
    guard caret > 0 else { return }
    let string = text as NSString
    let range = string.rangeOfComposedCharacterSequence(at: caret - 1)
    let deletion = range.location..<(range.location + range.length)
    try performListEdit { transaction in
      try replaceListAware(in: deletion, with: "", formatting: typingFormatting, transaction: transaction)
      return deletion.lowerBound
    }
  }

  func removeListItem(_ id: String, includingChildren: Bool = false) throws {
    try requireListCommand()
    guard let item = snapshot.listItems?.first(where: { $0.id == id }) else { return }
    let end = includingChildren ? snapshot.listSubtree(of: item).last?.end ?? item.end : item.end
    try performListEdit { transaction in
      try replaceListAware(in: item.offset..<end, with: "", formatting: TextFormatting(), transaction: transaction)
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
        try transaction.format(body, at: UInt32(target.separator), length: 1,
          attributes: ["listChecked": .bool(checked)])
      }
      return nil
    }
  }

  func handleListInput(in range: Range<Int>, replacement: String) throws -> Bool {
    guard !hasMarkedText else { return false }
    try validate(range)
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

  private func insertionAttributes(_ formatting: TextFormatting) -> YAttributes {
    var attributes = clearedListAttributes
    attributes.merge(formatting.attributes) { _, new in new }
    return attributes
  }

  /// A normal native replacement deletes exactly the selected text. Removing an ancestor's LF
  /// promotes surviving descendants; inserted text never inherits an item identity.
  func replaceListAware(in range: Range<Int>, with replacement: String, formatting: TextFormatting,
    transaction: YWriteTransaction) throws {
    let removed = Set((snapshot.listItems ?? []).filter {
      range.contains($0.separator)
    }.map(\.id))
    if !removed.isEmpty { try promoteDescendants(removing: removed, in: transaction) }
    if !range.isEmpty {
      try transaction.remove(from: body, at: UInt32(range.lowerBound), length: UInt32(range.count))
    }
    if !replacement.isEmpty {
      try transaction.insert(replacement, into: body, at: UInt32(range.lowerBound),
        attributes: insertionAttributes(formatting))
      try recordFeatures(formatting.features, in: transaction)
    }
  }

  private func promoteDescendants(removing removed: Set<String>, items: [SemanticListItem]? = nil,
    in transaction: YWriteTransaction) throws {
    let items = items ?? snapshot.listItems ?? []
    let parents = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.parent) })
    for item in items where !removed.contains(item.id) {
      var parent = item.parent
      var decrement = 0
      while let id = parent {
        if removed.contains(id) { decrement += 1 }
        parent = parents[id] ?? nil
      }
      if decrement > 0 {
        try transaction.format(body, at: UInt32(item.separator), length: 1,
          attributes: ["listDepth": .int(Int64(max(0, item.depth - decrement)))])
      }
    }
  }

  private func listState(in transaction: YWriteTransaction) throws -> SemanticSnapshot {
    let chunks = try transaction.chunks(from: body).compactMap { chunk -> (String, YAttributes)? in
      guard case .string(let value) = chunk.insert else { return nil }
      return (value, chunk.attributes)
    }
    return SemanticSnapshot(text: chunks.map(\.0).joined(), listItems: projectedListItems(chunks: chunks))
  }

  private func textRuns(in range: Range<Int>, transaction: YWriteTransaction) throws -> [ListTextRun] {
    guard !range.isEmpty else { return [] }
    var offset = 0
    var runs: [ListTextRun] = []
    for chunk in try transaction.chunks(from: body) {
      guard case .string(let value) = chunk.insert else { continue }
      let end = offset + value.utf16.count
      let lower = max(offset, range.lowerBound)
      let upper = min(end, range.upperBound)
      if lower < upper {
        runs.append(ListTextRun(text: (value as NSString).substring(with:
          NSRange(location: lower - offset, length: upper - lower)), attributes: chunk.attributes))
      }
      offset = end
      if offset >= range.upperBound { break }
    }
    return runs
  }

  private func insert(_ runs: [ListTextRun], at offset: Int, transaction: YWriteTransaction) throws {
    var cursor = offset
    for run in runs {
      var attributes = clearedListAttributes
      attributes.merge(run.attributes) { _, new in new }
      try transaction.insert(run.text, into: body, at: UInt32(cursor), attributes: attributes)
      cursor += run.text.utf16.count
    }
  }
}
