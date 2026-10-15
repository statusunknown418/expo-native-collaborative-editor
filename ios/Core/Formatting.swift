import Foundation
import SwiftYrs

/// Semantic values only; fonts and other presentation stay on the editing surface.
struct TextFormatting: Equatable {
  var bold = false
  var italic = false
  var heading = 0

  init(bold: Bool = false, italic: Bool = false, heading: Int = 0) {
    self.bold = bold
    self.italic = italic
    self.heading = heading
  }

  init(attributes: YAttributes) {
    bold = attributes["bold"] == .bool(true)
    italic = attributes["italic"] == .bool(true)
    switch attributes["heading"] {
    case .int(let level): heading = Int(level)
    case .double(let level): heading = Int(level)
    default: heading = 0
    }
  }

  var attributes: YAttributes {
    var result: YAttributes = [:]
    if bold { result["bold"] = .bool(true) }
    if italic { result["italic"] = .bool(true) }
    if heading > 0 { result["heading"] = .int(Int64(heading)) }
    return result
  }

  var features: [String] {
    var result: [String] = []
    if bold { result.append("formatting.bold@1") }
    if italic { result.append("formatting.italic@1") }
    if heading > 0 { result.append("formatting.heading@1") }
    return result
  }
}

/// `nil` means mixed; heading 0 means ordinary paragraphs.
struct SelectedFormatting: Equatable {
  var bold: Bool? = false
  var italic: Bool? = false
  var heading: Int? = 0

  init(_ formatting: TextFormatting = TextFormatting()) {
    bold = formatting.bold
    italic = formatting.italic
    heading = formatting.heading
  }

  var payload: [String: Any] {
    ["bold": bold as Any? ?? NSNull(), "italic": italic as Any? ?? NSNull(), "heading": heading as Any? ?? NSNull()]
  }
}

struct SemanticMark: Codable, Equatable {
  var offset: Int
  var length: Int
  let bold: Bool?
  let italic: Bool?
  let heading: Int?

  init(offset: Int, length: Int, formatting: TextFormatting) {
    self.offset = offset
    self.length = length
    bold = formatting.bold ? true : nil
    italic = formatting.italic ? true : nil
    heading = formatting.heading > 0 ? formatting.heading : nil
  }

  var formatting: TextFormatting {
    TextFormatting(bold: bold == true, italic: italic == true, heading: heading ?? 0)
  }
}
