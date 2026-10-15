// Decodes every recorded fixture with Yjs and compares it with its scenario in corpus.json.
import { expect, test } from 'bun:test';
import * as Y from 'yjs';

import { type SemanticSnapshot, semanticSnapshot } from './semanticSnapshot';

/** Scenario name → the semantic snapshot after each step. */
const corpus: Record<string, SemanticSnapshot[]> = await Bun.file(
  `${import.meta.dir}/corpus.json`
).json();

for (const origin of ['swift', 'js']) {
  const file = Bun.file(`${import.meta.dir}/updates/${origin}.json`);
  /** Scenario name → base64 v1 updates, one per step. */
  const recorded: Record<string, string[]> = (await file.exists()) ? await file.json() : {};
  for (const [name, steps] of Object.entries(corpus)) {
    test(`${origin}/${name}`, () => {
      const updates = (recorded[name] ?? []).map((update) => Buffer.from(update, 'base64'));
      expect(updates).toHaveLength(steps.length);
      const doc = new Y.Doc();
      updates.forEach((update, step) => {
        // The second application replays the update, which must change nothing.
        for (const _ of [1, 2]) {
          Y.applyUpdate(doc, update);
          expect(semanticSnapshot(doc)).toEqual(steps[step]);
        }
      });
      for (const update of updates) Y.applyUpdate(doc, update);
      expect(semanticSnapshot(doc)).toEqual(steps[steps.length - 1]);
    });
  }
}
