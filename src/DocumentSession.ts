import { NativeModule, requireNativeModule, SharedObject } from 'expo';

// Provisional session API; the stable editor/hooks API belongs to #19.

export type DocumentSessionState = {
  /** Every local edit is durable on this device; marked input is still unsaved. */
  savedOnThisPhone: boolean;
  /**
   * Committed local edits await receipts. A local-only document's edits stay pending until it
   * synchronizes.
   */
  pendingSynchronization: boolean;
  /** Whether this open session has a local edit available to undo. */
  canUndo: boolean;
  /** Whether this open session has an undone local edit available to redo. */
  canRedo: boolean;
};

export type DocumentSessionEvents = {
  stateChange(state: DocumentSessionState): void;
};

/** Handle to a shared native document session. It carries state, never document content. */
export declare class DocumentSession extends SharedObject<DocumentSessionEvents> {
  readonly state: DocumentSessionState;
  /** Undoes the latest local edit without undoing remote changes. Rejects marked input. */
  undo(): Promise<void>;
  /** Redoes the latest undone local edit. Rejects marked input. */
  redo(): Promise<void>;
  /**
   * Explicitly closes the native session and discards its undo history. Rejects unsaved input,
   * pending commits, or failed commits, leaving the session open. Releasing a JS handle does not close it.
   */
  close(): Promise<void>;
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
