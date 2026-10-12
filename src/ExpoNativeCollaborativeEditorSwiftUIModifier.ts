import { createModifier, type ModifierConfig } from '@expo/ui/swift-ui/modifiers';

export const expoNativeCollaborativeEditorSwiftUIModifier = (params: {
  color?: string;
  width?: number;
  cornerRadius?: number;
}): ModifierConfig => createModifier('expoNativeCollaborativeEditorSwiftUIModifier', params);
