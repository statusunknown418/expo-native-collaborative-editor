import { NativeModule, requireNativeModule } from 'expo';

import { ExpoNativeCollaborativeEditorModuleEvents } from './ExpoNativeCollaborativeEditor.types';

declare class ExpoNativeCollaborativeEditorModule extends NativeModule<ExpoNativeCollaborativeEditorModuleEvents> {}

export default requireNativeModule<ExpoNativeCollaborativeEditorModule>('ExpoNativeCollaborativeEditor');
