import Combine
import ExpoModulesCore
import Synchronization

/// JavaScript's handle to a shared native document session. It carries status, never document content.
final class DocumentSessionHandle: SharedObject, @unchecked Sendable {
  let session: DocumentSession
  /// Last published state, readable from the JavaScript thread.
  private let savedOnThisPhone: Synchronization.Mutex<Bool>
  private var stateSubscription: AnyCancellable?

  @MainActor
  init(session: DocumentSession) {
    self.session = session
    savedOnThisPhone = Mutex(session.isSavedOnThisPhone)
    super.init()
    stateSubscription = session.$isSavedOnThisPhone.dropFirst().removeDuplicates().sink { [weak self] saved in
      guard let self else { return }
      savedOnThisPhone.withLock { $0 = saved }
      emit(event: "stateChange", payload: ["savedOnThisPhone": saved])
    }
  }

  var state: [String: Any] {
    ["savedOnThisPhone": savedOnThisPhone.withLock { $0 }]
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
