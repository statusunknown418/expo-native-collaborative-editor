import ExpoModulesCore
import ExpoUI

public class ExpoNativeCollaborativeEditorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoNativeCollaborativeEditor")
    Constant("capabilities") { FeaturePlugins.capabilities }

    Class("DocumentSession", DocumentSessionHandle.self) {
      Property("state") { (handle: DocumentSessionHandle) in handle.state }

      AsyncFunction("setPlugins") { (handle: DocumentSessionHandle, registrations: [[String: Any]]) throws in
        let plugins = try validatedPlugins(registrations)
        try MainActor.assumeIsolated { try handle.session.setPlugins(plugins) }
      }.runOnQueue(.main)

      AsyncFunction("toggleBold") { (handle: DocumentSessionHandle) throws in
        try MainActor.assumeIsolated { try handle.session.toggleBold() }
      }.runOnQueue(.main)

      AsyncFunction("toggleItalic") { (handle: DocumentSessionHandle) throws in
        try MainActor.assumeIsolated { try handle.session.toggleItalic() }
      }.runOnQueue(.main)

      AsyncFunction("setHeading") { (handle: DocumentSessionHandle, level: Int) throws in
        try MainActor.assumeIsolated { try handle.session.setHeading(level) }
      }.runOnQueue(.main)

      AsyncFunction("undo") { (handle: DocumentSessionHandle) throws in
        try MainActor.assumeIsolated { try handle.session.undo() }
      }.runOnQueue(.main)

      AsyncFunction("redo") { (handle: DocumentSessionHandle) throws in
        try MainActor.assumeIsolated { try handle.session.redo() }
      }.runOnQueue(.main)

      AsyncFunction("close") { (handle: DocumentSessionHandle) throws in
        try MainActor.assumeIsolated { try documentSessionRegistry().close(handle.session) }
      }.runOnQueue(.main)
    }

    AsyncFunction("openDocument") { (accountNamespace: String, documentID: String, registrations: [[String: Any]]) throws -> DocumentSessionHandle in
      let plugins = try validatedPlugins(registrations)
      return try MainActor.assumeIsolated {
        let session = try documentSessionRegistry()
          .session(accountNamespace: accountNamespace, documentID: documentID, plugins: plugins)
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

private func validatedPlugins(_ registrations: [[String: Any]]) throws -> FeaturePlugins {
  do {
    return try FeaturePlugins(registrations: registrations)
  } catch let error as EditorConfigurationError {
    throw Exception(name: "EditorConfigurationError", description: error.message, code: "ERR_EDITOR_CONFIGURATION")
  }
}
