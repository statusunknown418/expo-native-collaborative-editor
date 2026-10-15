// Decodes every recorded fixture with Yjs and compares it with its scenario in corpus.json.

import { expect, test } from 'bun:test';
import { file as bunFile } from 'bun';
import { applyUpdate, Doc } from 'yjs';

import { type SemanticSnapshot, semanticSnapshot } from './semanticSnapshot';

/** Scenario name → the semantic snapshot after each step. */
const corpus: Record<string, SemanticSnapshot[]> = await bunFile(
  `${import.meta.dir}/corpus.json`
).json();

const recordings = await Promise.all(
  ['swift', 'js'].map(async (origin) => {
    const file = bunFile(`${import.meta.dir}/updates/${origin}.json`);
    /** Scenario name → base64 v1 updates, one per step. */
    const recorded: Record<string, string[]> = (await file.exists()) ? await file.json() : {};
    return { origin, recorded };
  })
);
for (const { origin, recorded } of recordings) {
  for (const [name, steps] of Object.entries(corpus)) {
    test(`${origin}/${name}`, () => {
      const updates = (recorded[name] ?? []).map((update) => Buffer.from(update, 'base64'));
      expect(updates).toHaveLength(steps.length);
      const doc = new Doc();
      updates.forEach((update, step) => {
        // The second application replays the update, which must change nothing.
        for (const _ of [1, 2]) {
          applyUpdate(doc, update);
          expect(semanticSnapshot(doc)).toEqual(steps[step]);
        }
      });
      for (const update of updates) {
        applyUpdate(doc, update);
      }
      expect<SemanticSnapshot | undefined>(semanticSnapshot(doc)).toEqual(steps.at(-1));
    });
  }
}
