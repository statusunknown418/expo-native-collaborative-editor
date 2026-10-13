import SwiftUI
import ExpoModulesCore
import ExpoUI

final class EditingSurfaceViewProps: UIBaseViewProps {}

// Empty until M1 binds it to a document session.
struct EditingSurfaceView: ExpoSwiftUI.View {
  @ObservedObject public var props: EditingSurfaceViewProps

  var body: some View {
    Color.clear.accessibilityElement()
  }
}
