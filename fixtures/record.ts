// Records Yjs updates for the corpus.json scenarios that updates/js.json lacks. Recorded updates
// are golden: existing entries are never rewritten.
import * as Y from 'yjs';

import { type SemanticSnapshot, semanticSnapshot } from './semanticSnapshot';

/** Yjs updates that take an empty document through `steps`, one transaction per step. */
const record = (steps: SemanticSnapshot[]): string[] => {
  const doc = new Y.Doc();
  const body = doc.getText('body');
  const updates: string[] = [];
  doc.on('update', (update: Uint8Array) => updates.push(Buffer.from(update).toString('base64')));
  for (const step of steps) {
    const { text, marks = [], features = [] } = step;
    // The smallest replacement aligned to code points, so no edit splits a surrogate pair.
    const before = [...body.toString()];
    const after = [...text];
    let prefix = 0;
    while (prefix < before.length && before[prefix] === after[prefix]) prefix++;
    let suffix = 0;
    while (
      suffix < before.length - prefix &&
      suffix < after.length - prefix &&
      before[before.length - 1 - suffix] === after[after.length - 1 - suffix]
    ) {
      suffix++;
    }
    const at = before.slice(0, prefix).join('').length;
    doc.transact(() => {
      body.delete(at, before.slice(prefix, before.length - suffix).join('').length);
      body.insert(at, after.slice(prefix, after.length - suffix).join(''));
      // Apply only changed mark intervals, including explicit removals.
      const current = semanticSnapshot(doc).marks ?? [];
      const boundaries = [
        ...new Set([
          0,
          text.length,
          ...[...current, ...marks].flatMap(({ offset, length }) => [offset, offset + length]),
        ]),
      ].sort((a, b) => a - b);
      for (let i = 0; i + 1 < boundaries.length; i++) {
        const start = boundaries[i];
        const length = boundaries[i + 1] - start;
        const before = current.find(
          (mark) => mark.offset <= start && start < mark.offset + mark.length
        );
        const after = marks.find(
          (mark) => mark.offset <= start && start < mark.offset + mark.length
        );
        const attributes: Record<string, boolean | number | null> = {};
        for (const key of ['bold', 'italic', 'heading'] as const) {
          if (before?.[key] !== after?.[key]) attributes[key] = after?.[key] ?? null;
        }
        if (length > 0 && Object.keys(attributes).length) body.format(start, length, attributes);
      }
      const manifest = doc.getMap('features');
      for (const feature of features) if (!manifest.has(feature)) manifest.set(feature, 1);
    });
  }
  return updates;
};

const corpus: Record<string, SemanticSnapshot[]> = await Bun.file(
  `${import.meta.dir}/corpus.json`
).json();
const file = Bun.file(`${import.meta.dir}/updates/js.json`);
const recorded: Record<string, string[]> = (await file.exists()) ? await file.json() : {};
for (const [name, steps] of Object.entries(corpus)) recorded[name] ??= record(steps);
await Bun.write(file, `${JSON.stringify(recorded, null, 2)}\n`);
