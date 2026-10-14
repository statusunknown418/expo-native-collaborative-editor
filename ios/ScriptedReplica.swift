import ExpoModulesCore
import os

private let logger = Logger(subsystem: "expo.modules.nativecollaborativeeditor", category: "ScriptedReplica")

/// Test-only: another replica of a session's document, with its own temporary store, connected to
/// the session through a delivery harness that a timer drives in real time. It makes each edit it
/// is given once every earlier operation has been delivered, so it edits the text the person sees.
final class ScriptedReplica: SharedObject, @unchecked Sendable {
  private let session: DocumentSession
  private let replica: DocumentSession
  private let harness: DeliveryHarness
  private var edits: [(range: Range<Int>, text: String)] = []
  private var timer: Timer?

  @MainActor
  init(connectingTo session: DocumentSession) throws {
    let key = session.metadata.key
    let store = try DocumentStore(
      url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/documents.sqlite"))
    self.session = session
    replica = try DocumentSessionRegistry(store: store)
      .session(accountNamespace: key.accountNamespace, documentID: key.documentID)
    harness = DeliveryHarness(seed: 1, faults: .unreliable)
    super.init()
    try harness.connect(session)
    try harness.connect(replica)
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  deinit {
    timer?.invalidate()
  }

  /// Queues an edit to the UTF-16 `range` of the replica's text.
  @MainActor
  func edit(_ range: Range<Int>, with text: String) {
    edits.append((range, text))
  }

  @MainActor
  private func tick() {
    do {
      try harness.tick()
      guard !edits.isEmpty, harness.isIdle, session.isSavedOnThisPhone, replica.isSavedOnThisPhone else { return }
      let edit = edits.removeFirst()
      try replica.replaceText(in: edit.range, with: edit.text)
    } catch {
      logger.fault("Scripted replica failed: \(String(describing: error), privacy: .public)")
    }
  }
}
