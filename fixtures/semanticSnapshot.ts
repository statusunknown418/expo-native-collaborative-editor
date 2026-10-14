import type * as Y from 'yjs';

/**
 * Engine-independent projection of a document's content. Swift's `SemanticSnapshot` produces the
 * same value from the same updates. Format: docs/development.md#semantic-snapshot.
 */
export type SemanticSnapshot = {
  /** The document text: Unicode scalars exactly as stored, never normalized. */
  text: string;
};

export const semanticSnapshot = (doc: Y.Doc): SemanticSnapshot => ({
  text: doc.getText('body').toString(),
});
