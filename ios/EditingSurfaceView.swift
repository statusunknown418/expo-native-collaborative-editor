import ExpoModulesCore
import ExpoUI
import SwiftUI
import os

private let logger = Logger(subsystem: "expo.modules.nativecollaborativeeditor", category: "EditingSurface")

final class EditingSurfaceViewProps: UIBaseViewProps {
  @Field var session: DocumentSessionHandle?
}

/// Holds no document state: remounting binds a new view to the same session.
struct EditingSurfaceView: ExpoSwiftUI.View {
  @ObservedObject public var props: EditingSurfaceViewProps

  var body: some View {
    if let session = props.session?.session {
      PlainTextEditor(session: session)
    }
  }
}

private struct PlainTextEditor: View {
  @ObservedObject var session: DocumentSession

  var body: some View {
    TextEditor(
      text: Binding(
        get: { session.text },
        set: { newText in
          do {
            try session.replaceText(with: newText)
          } catch {
            logger.fault("Engine rejected a local edit: \(String(describing: error), privacy: .public)")
          }
        }))
  }
}
