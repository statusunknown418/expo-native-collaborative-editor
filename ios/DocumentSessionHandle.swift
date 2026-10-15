import Combine
import ExpoModulesCore
import Synchronization

/// JavaScript's handle to a shared native document session. It carries status, never document content.
final class DocumentSessionHandle: SharedObject, @unchecked Sendable {
  private struct State: Equatable {
    var savedOnThisPhone: Bool
    var pendingSynchronization: Bool
    var canUndo: Bool
    var canRedo: Bool

    var payload: [String: Any] {
      [
        "savedOnThisPhone": savedOnThisPhone, "pendingSynchronization": pendingSynchronization,
        "canUndo": canUndo, "canRedo": canRedo,
      ]
    }
  }

  let session: DocumentSession
  /// Last published state, readable from the JavaScript thread.
  private let published: Synchronization.Mutex<State>
  private var stateSubscription: AnyCancellable?

  @MainActor
  init(session: DocumentSession) {
    self.session = session
    published = Mutex(
      State(
        savedOnThisPhone: session.isSavedOnThisPhone, pendingSynchronization: session.hasPendingSynchronization,
        canUndo: session.canUndo, canRedo: session.canRedo))
    super.init()
    stateSubscription = session.$isSavedOnThisPhone.combineLatest(
      session.$hasPendingSynchronization, session.$canUndo, session.$canRedo)
      .map(State.init)
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] state in
        guard let self else { return }
        published.withLock { $0 = state }
        emit(event: "stateChange", payload: state.payload)
      }
  }

  var state: [String: Any] {
    published.withLock { $0 }.payload
  }
}

/// One registry per process, so every handle and editing surface for a document shares one session.
@MainActor private var sharedRegistry: DocumentSessionRegistry?

@MainActor
func documentSessionRegistry() throws -> DocumentSessionRegistry {
  if let sharedRegistry { return sharedRegistry }
  let url = try FileManager.default
    .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    .appendingPathComponent("ExpoNativeCollaborativeEditor/documents.sqlite")
  let registry = DocumentSessionRegistry(store: try DocumentStore(url: url))
  sharedRegistry = registry
  return registry
}
