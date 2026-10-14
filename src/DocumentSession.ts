import { NativeModule, requireNativeModule, SharedObject } from 'expo';

// Unstable until the M1 foundation decision (#1).

export type DocumentSessionState = {
  /** Every local edit is durably committed on this device. */
  savedOnThisPhone: boolean;
};

export type DocumentSessionEvents = {
  stateChange(state: DocumentSessionState): void;
};

/** Handle to a shared native document session. It carries state, never document content. */
export declare class DocumentSession extends SharedObject<DocumentSessionEvents> {
  readonly state: DocumentSessionState;
}

export type OpenDocumentOptions = {
  accountNamespace: string;
  documentId: string;
};

declare class ExpoNativeCollaborativeEditorModule extends NativeModule {
  openDocument(accountNamespace: string, documentId: string): Promise<DocumentSession>;
}

const nativeModule = requireNativeModule<ExpoNativeCollaborativeEditorModule>(
  'ExpoNativeCollaborativeEditor'
);

/**
 * Opens the latest lifecycle generation of a document in an account namespace, creating the document
 * if it does not exist. Handles to the same document share one native session.
 */
export function openDocument({
  accountNamespace,
  documentId,
}: OpenDocumentOptions): Promise<DocumentSession> {
  return nativeModule.openDocument(accountNamespace, documentId);
}
