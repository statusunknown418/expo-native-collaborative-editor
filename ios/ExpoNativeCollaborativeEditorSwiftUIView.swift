import SwiftUI
import ExpoModulesCore
import ExpoUI

final class ExpoNativeCollaborativeEditorSwiftUIViewProps: UIBaseViewProps {
  @Field var title: String = ""
}

struct ExpoNativeCollaborativeEditorSwiftUIView: ExpoSwiftUI.View {
  @ObservedObject public var props: ExpoNativeCollaborativeEditorSwiftUIViewProps

  var body: some View {
    VStack {
      Text(props.title)
        .font(.headline)
      Children()
    }
  }
}
