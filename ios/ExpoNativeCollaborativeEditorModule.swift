import ExpoModulesCore
import ExpoUI

public class ExpoNativeCollaborativeEditorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoNativeCollaborativeEditor")

    ExpoUIView(EditingSurfaceView.self)
  }
}
