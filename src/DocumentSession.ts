import { NativeModule, requireNativeModule, SharedObject } from 'expo';

import type { FeaturePlugin, HeadingLevel, ListKind, NativeCapabilities } from './FeaturePlugins';

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
  /** null means mixed; heading 0 means ordinary paragraphs. */
  selectedFormatting: {
    bold: boolean | null;
    italic: boolean | null;
    heading: HeadingLevel | 0 | null;
  };
};

export type DocumentSessionEvents = {
  stateChange(state: DocumentSessionState): void;
};

/** Handle to a shared native document session. It carries state, never document content. */
export declare class DocumentSession extends SharedObject<DocumentSessionEvents> {
  readonly state: DocumentSessionState;
  /** Replaces authoring configuration atomically; content and history remain untouched. */
  setPlugins(plugins: readonly FeaturePlugin[]): Promise<void>;
  /** Toggles selection marks, or typing attributes when selection is collapsed. */
  toggleBold(): Promise<void>;
  toggleItalic(): Promise<void>;
  /** Formats every selected paragraph; 0 restores ordinary paragraphs. */
  setHeading(level: HeadingLevel | 0): Promise<void>;
  /** Converts selected paragraphs; null restores ordinary paragraphs and promotes children. */
  setListKind(kind: ListKind | null): Promise<void>;
  indentListItem(): Promise<void>;
  outdentListItem(): Promise<void>;
  insertReturn(): Promise<void>;
  deleteBackward(): Promise<void>;
  removeListItem(id: string, includingChildren?: boolean): Promise<void>;
  /** Existing checklists remain toggleable when list authoring is disabled. */
  toggleChecklistItem(id: string): Promise<void>;
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
  /** No authoring plugins are enabled implicitly. */
  plugins?: readonly FeaturePlugin[];
};

declare class ExpoNativeCollaborativeEditorModule extends NativeModule {
  readonly capabilities: NativeCapabilities;
  openDocument(
    accountNamespace: string,
    documentId: string,
    plugins: readonly FeaturePlugin[]
  ): Promise<DocumentSession>;
}

const nativeModule = requireNativeModule<ExpoNativeCollaborativeEditorModule>(
  'ExpoNativeCollaborativeEditor'
);

/** The capabilities actually compiled into this native build, not a JavaScript wish list. */
export const nativeCapabilities: NativeCapabilities = nativeModule.capabilities;

/**
 * Opens the latest lifecycle generation of a document in an account namespace, creating the document
 * if it does not exist. Handles to the same document share one native session.
 */
export function openDocument({
  accountNamespace,
  documentId,
  plugins = [],
}: OpenDocumentOptions): Promise<DocumentSession> {
  return nativeModule.openDocument(accountNamespace, documentId, plugins);
}
