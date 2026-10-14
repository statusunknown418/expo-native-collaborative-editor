import ExpoModulesCore
import ExpoUI

public class ExpoNativeCollaborativeEditorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoNativeCollaborativeEditor")

    Class("DocumentSession", DocumentSessionHandle.self) {
      Property("state") { (handle: DocumentSessionHandle) in handle.state }
    }

    AsyncFunction("openDocument") { (accountNamespace: String, documentID: String) throws -> DocumentSessionHandle in
      try MainActor.assumeIsolated {
        let session = try documentSessionRegistry()
          .session(accountNamespace: accountNamespace, documentID: documentID)
        return DocumentSessionHandle(session: session)
      }
    }.runOnQueue(.main)

    ExpoUIView(EditingSurfaceView.self)
  }
}
