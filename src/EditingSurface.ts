import { requireNativeView } from 'expo';

export type EditingSurfaceProps = {
  /** Accessibility identifier for UI tests. */
  testID?: string;
};

/** Must be rendered inside an `@expo/ui/swift-ui` `Host`. */
export const EditingSurface = requireNativeView<EditingSurfaceProps>(
  'ExpoNativeCollaborativeEditor',
  'EditingSurfaceView'
);
