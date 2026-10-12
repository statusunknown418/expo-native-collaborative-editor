import ExpoModulesCore
import ExpoUI

public class ExpoNativeCollaborativeEditorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoNativeCollaborativeEditor")

    Events("onChange")

    ExpoUIView(ExpoNativeCollaborativeEditorSwiftUIView.self)

    OnCreate {
      ViewModifierRegistry.register("expoNativeCollaborativeEditorSwiftUIModifier") { params, appContext, _ in
        return try ExpoNativeCollaborativeEditorSwiftUIModifier(from: params, appContext: appContext)
      }
    }

    OnDestroy {
      ViewModifierRegistry.unregister("expoNativeCollaborativeEditorSwiftUIModifier")
    }
  }
}
