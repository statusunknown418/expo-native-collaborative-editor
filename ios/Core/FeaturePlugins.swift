import Foundation

struct EditorConfigurationError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// The native build is authoritative. Configuration changes never mutate a document.
struct FeaturePlugins: Equatable {
  struct Formatting: Equatable {
    var bold = true
    var italic = true
    var headingLevels = [1, 2, 3, 4, 5, 6]
  }

  struct Lists: Equatable {
    var ordered = true
    var unordered = true
    var checklist = true
    var caution__enableChecklistChildrenAutoCompletion = false
  }

  static let capabilities: [String: Any] = [
    "formatting": ["version": 1, "bold": true, "italic": true, "headingLevels": [1, 2, 3, 4, 5, 6]],
    "lists": ["version": 1, "ordered": true, "unordered": true, "checklist": true]
  ]

  private(set) var formatting: Formatting?
  private(set) var lists: Lists?

  init() {}

  init(registrations: [[String: Any]]) throws {
    var ids = Set<String>()
    var capabilities = Set<String>()
    for registration in registrations {
      guard Set(registration.keys) == ["id", "capability", "version", "options"],
        let id = registration["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let capability = registration["capability"] as? String,
        let descriptor = Self.capabilities[capability] as? [String: Any],
        let version = registration["version"] as? NSNumber,
        CFGetTypeID(version) != CFBooleanGetTypeID(), version == descriptor["version"] as? NSNumber,
        let options = registration["options"] as? [String: Any]
      else { throw EditorConfigurationError(message: "Invalid plugin registration or unavailable native capability.") }
      guard ids.insert(id).inserted else {
        throw EditorConfigurationError(message: "Duplicate plugin ID: \(id).")
      }
      guard capabilities.insert(capability).inserted else {
        throw EditorConfigurationError(message: "Capability registered more than once: \(capability).")
      }
      if capability == "lists" {
        guard Set(options.keys).isSubset(of: [
          "ordered", "unordered", "checklist", "caution__enableChecklistChildrenAutoCompletion"
        ]) else { throw EditorConfigurationError(message: "Unknown lists option.") }
        var normalized = Lists()
        for (key, value) in options {
          guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw EditorConfigurationError(message: "\(key) must be a boolean.")
          }
          switch key {
          case "ordered": normalized.ordered = number.boolValue
          case "unordered": normalized.unordered = number.boolValue
          case "checklist": normalized.checklist = number.boolValue
          default: normalized.caution__enableChecklistChildrenAutoCompletion = number.boolValue
          }
        }
        lists = normalized
        continue
      }
      guard Set(options.keys).isSubset(of: ["bold", "italic", "headingLevels"]) else {
        throw EditorConfigurationError(message: "Unknown formatting option.")
      }
      var normalized = Formatting()
      for key in ["bold", "italic"] {
        if let value = options[key] {
          guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw EditorConfigurationError(message: "\(key) must be a boolean.")
          }
          if key == "bold" { normalized.bold = number.boolValue } else { normalized.italic = number.boolValue }
        }
      }
      if let value = options["headingLevels"] {
        guard let levels = value as? [NSNumber], levels.allSatisfy({
          CFGetTypeID($0) != CFBooleanGetTypeID() && (1...6).contains($0.intValue)
            && $0.doubleValue == Double($0.intValue)
        }) else { throw EditorConfigurationError(message: "headingLevels must contain integers from 1 through 6.") }
        normalized.headingLevels = Array(Set(levels.map(\.intValue))).sorted()
      }
      formatting = normalized
    }
  }
}
