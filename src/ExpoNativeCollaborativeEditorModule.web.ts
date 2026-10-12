import { registerWebModule, NativeModule } from 'expo';

import { ExpoNativeCollaborativeEditorModuleEvents } from './ExpoNativeCollaborativeEditor.types';

// ExpoNativeCollaborativeEditorModule is not available on the web platform.
class ExpoNativeCollaborativeEditorModule extends NativeModule<ExpoNativeCollaborativeEditorModuleEvents> {}

export default registerWebModule(ExpoNativeCollaborativeEditorModule, 'ExpoNativeCollaborativeEditorModule');
