import { requireNativeView } from 'expo';
import { type CommonViewModifierProps } from '@expo/ui/swift-ui';
import { createViewModifierEventListener } from '@expo/ui/swift-ui/modifiers';
import * as React from 'react';

export interface ExpoNativeCollaborativeEditorSwiftUIViewProps extends CommonViewModifierProps {
  title: string;
  children?: React.ReactNode;
}

const NativeExpoNativeCollaborativeEditorSwiftUIView = requireNativeView<ExpoNativeCollaborativeEditorSwiftUIViewProps>(
  'ExpoNativeCollaborativeEditor',
  'ExpoNativeCollaborativeEditorSwiftUIView'
);

export default function ExpoNativeCollaborativeEditorSwiftUIView({
  modifiers,
  ...rest
}: ExpoNativeCollaborativeEditorSwiftUIViewProps) {
  return (
    <NativeExpoNativeCollaborativeEditorSwiftUIView
      modifiers={modifiers}
      {...(modifiers ? createViewModifierEventListener(modifiers) : undefined)}
      {...rest}
    />
  );
}
