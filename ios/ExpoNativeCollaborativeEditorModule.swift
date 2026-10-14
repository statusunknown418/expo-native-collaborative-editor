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

    // Test-only: the example app's scripted remote replica.
    Class("ScriptedReplica", ScriptedReplica.self) {
      AsyncFunction("edit") { (replica: ScriptedReplica, offset: Int, deleteCount: Int, text: String) throws in
        guard offset >= 0, deleteCount >= 0 else { throw InvalidRemoteEditException() }
        MainActor.assumeIsolated { replica.edit(offset..<(offset + deleteCount), with: text) }
      }.runOnQueue(.main)
    }

    AsyncFunction("connectScriptedReplica") { (handle: DocumentSessionHandle) throws -> ScriptedReplica in
      try MainActor.assumeIsolated { try ScriptedReplica(connectingTo: handle.session) }
    }.runOnQueue(.main)

    ExpoUIView(EditingSurfaceView.self)
  }
}

private final class InvalidRemoteEditException: Exception, @unchecked Sendable {
  override var reason: String { "offset and deleteCount must not be negative" }
}
