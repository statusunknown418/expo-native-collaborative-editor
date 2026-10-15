import SwiftYrs
import XCTest

@testable import ExpoNativeCollaborativeEditor

/// Decodes every recorded fixture with Yrs and compares it with its scenario in `fixtures/corpus.json`.
/// With `RECORD_FIXTURES` set (`TEST_RUNNER_RECORD_FIXTURES=1` through `xcodebuild`), first records
/// the scenarios that `fixtures/updates/swift.json` lacks.
@MainActor
final class FixtureCorpusTests: XCTestCase {
  func testEveryFixtureDecodesToItsScenarioSnapshots() throws {
    let corpus = try JSONDecoder().decode(
      [String: [SemanticSnapshot]].self, from: Data(contentsOf: fixturesURL.appending(path: "corpus.json")))
    if ProcessInfo.processInfo.environment["RECORD_FIXTURES"] != nil {
      try recordMissingNativeFixtures(corpus)
    }

    for origin in ["swift", "js"] {
      let recorded = try recordedUpdates(origin)
      for (name, steps) in corpus.sorted(by: { $0.key < $1.key }) {
        let fixture = "\(origin)/\(name)"
        do {
          try verify(fixture, updates: recorded[name] ?? [], steps: steps)
        } catch {
          XCTFail("\(fixture): \(error)")
        }
      }
    }
  }

  private func verify(_ fixture: String, updates: [Data], steps: [SemanticSnapshot]) throws {
    guard updates.count == steps.count else {
      return XCTFail("\(fixture): \(updates.count) updates recorded for \(steps.count) steps")
    }
    let doc = YDoc()
    for (step, (update, expected)) in zip(updates, steps).enumerated() {
      // The second application replays the update, which must change nothing.
      for _ in 1...2 {
        try doc.apply(.v1(update))
        XCTAssertEqual(try SemanticSnapshot(document: doc), expected, "\(fixture) step \(step)")
      }
    }
    for update in updates { try doc.apply(.v1(update)) }
    XCTAssertEqual(try SemanticSnapshot(document: doc), steps.last, "\(fixture) after replaying every update")
  }

  /// Takes a document session through each missing scenario and records the updates it commits.
  /// Sessions never write malformed structure, so that scenario records a raw Yrs document.
  private func recordMissingNativeFixtures(_ corpus: [String: [SemanticSnapshot]]) throws {
    var recorded = try recordedUpdates("swift")
    if corpus["malformed-blocks"] != nil, recorded["malformed-blocks"] == nil {
      recorded["malformed-blocks"] = [try malformedBlocks().document.encodeStateAsUpdateV1().data]
    }
    for (name, steps) in corpus where recorded[name] == nil {
      let store = try DocumentStore(url: temporaryStoreURL())
      let session = try DocumentSessionRegistry(store: store).session(accountNamespace: "fixtures", documentID: name)
      try session.setPlugins(FeaturePlugins(registrations: [
        formattingRegistration(), listsRegistration()
      ]))
      for (index, step) in steps.enumerated() {
        switch (name, index) {
        case ("marks", 1): session.selection = 0..<4; try session.toggleBold()
        case ("marks", 2): session.selection = 5..<11; try session.toggleItalic()
        case ("marks", 3): session.selection = 12..<19; try session.setHeading(1)
        case ("marks", 4): session.selection = 0..<4; try session.toggleItalic()
        case ("marks", 5): try session.replaceText(in: 2..<2, with: "👍")
        case ("marks", 6): session.selection = 0..<6; try session.toggleBold()
        case ("marks", 7): session.selection = 0..<6; try session.toggleItalic()
        case ("marks", 8): session.selection = 14..<21; try session.setHeading(0)
        case ("nested-lists", 1): session.selection = 0..<0; try session.setListKind(.ordered, itemID: "plan")
        case ("nested-lists", 2): session.selection = 5..<5; try session.setListKind(.checklist, itemID: "task")
        case ("nested-lists", 3): session.selection = 10..<10; try session.setListKind(.unordered, itemID: "detail")
        case ("nested-lists", 4): session.selection = 17..<17; try session.setListKind(.checklist, itemID: "other")
        case ("nested-lists", 5): session.selection = 5..<5; try session.indentListItem()
        case ("nested-lists", 6), ("nested-lists", 7):
          session.selection = 10..<10; try session.indentListItem()
        case ("nested-lists", 8): try session.toggleChecklistItem("task")
        case ("nested-lists", 9): try session.toggleChecklistItem("other")
        case ("nested-lists", 10): try session.removeListItem("task")
        case ("nested-lists", 11): try session.removeListItem("plan", includingChildren: true)
        default: try session.replaceText(with: step.text)
        }
        XCTAssertEqual(session.snapshot, step, "\(name) native recording step \(index)")
      }
      waitUntil { session.isSavedOnThisPhone }
      recorded[name] = try store.outbox(for: session.metadata.key).map(\.update)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(recorded).write(to: updatesURL("swift"))
  }

  /// Scenario name → v1 updates, one per step (base64 in the file).
  private func recordedUpdates(_ origin: String) throws -> [String: [Data]] {
    let url = updatesURL(origin)
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    return try JSONDecoder().decode([String: [Data]].self, from: Data(contentsOf: url))
  }

  private func updatesURL(_ origin: String) -> URL {
    fixturesURL.appending(path: "updates/\(origin).json")
  }
}

/// The repository's `fixtures` directory, used in place: simulator tests can read and write host files.
private let fixturesURL = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "fixtures")
