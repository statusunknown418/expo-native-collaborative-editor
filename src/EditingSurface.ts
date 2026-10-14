import { requireNativeView } from 'expo';

import type { DocumentSession } from './DocumentSession';

export type EditingSurfaceProps = {
  /** The session this surface edits. Unmounting the surface leaves the session open. */
  session: DocumentSession;
  /** Accessibility identifier for UI tests. */
  testID?: string;
};

/** Must be rendered inside an `@expo/ui/swift-ui` `Host`. */
export const EditingSurface = requireNativeView<EditingSurfaceProps>(
  'ExpoNativeCollaborativeEditor',
  'EditingSurfaceView'
);
