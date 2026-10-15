// Records Yjs updates for the corpus.json scenarios that updates/js.json lacks. Recorded updates
// are golden: existing entries are never rewritten.
import { file as bunFile, deepEquals, write } from 'bun';
import { Doc } from 'yjs';

import { type SemanticMark, type SemanticSnapshot, semanticSnapshot } from './semanticSnapshot';

function changedAttributes(before: SemanticMark | undefined, after: SemanticMark | undefined) {
  const attributes: Record<string, boolean | number | null> = {};
  for (const key of ['bold', 'italic', 'heading'] as const) {
    if (before?.[key] !== after?.[key]) {
      attributes[key] = after?.[key] ?? null;
    }
  }
  return attributes;
}

/** Yjs updates that take an empty document through `steps`, one transaction per step. */
const recordDiffs = (steps: SemanticSnapshot[]): string[] => {
  const doc = new Doc();
  const body = doc.getText('body');
  const updates: string[] = [];
  doc.on('update', (update: Uint8Array) => updates.push(Buffer.from(update).toString('base64')));
  for (const step of steps) {
    const { text, marks = [], features = [] } = step;
    // The smallest replacement aligned to code points, so no edit splits a surrogate pair.
    const before = [...body.toString()];
    const after = [...text];
    let prefix = 0;
    while (prefix < before.length && before[prefix] === after[prefix]) {
      prefix += 1;
    }
    let suffix = 0;
    while (
      suffix < before.length - prefix &&
      suffix < after.length - prefix &&
      before.at(-1 - suffix) === after.at(-1 - suffix)
    ) {
      suffix += 1;
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
      for (let i = 0; i + 1 < boundaries.length; i += 1) {
        const start = boundaries[i];
        const length = boundaries[i + 1] - start;
        const beforeMark = current.find(
          (mark) => mark.offset <= start && start < mark.offset + mark.length
        );
        const afterMark = marks.find(
          (mark) => mark.offset <= start && start < mark.offset + mark.length
        );
        const attributes = changedAttributes(beforeMark, afterMark);
        if (length > 0 && Object.keys(attributes).length) {
          body.format(start, length, attributes);
        }
      }
      const manifest = doc.getMap('features');
      for (const feature of features) {
        if (!manifest.has(feature)) {
          manifest.set(feature, 1);
        }
      }
    });
  }
  return updates;
};

type Script = (doc: Doc) => void;

const useFeature = (doc: Doc, feature: string) => {
  const manifest = doc.getMap('features');
  if (!manifest.has(feature)) {
    manifest.set(feature, 1);
  }
};

/** Explicit block-model edits, one transaction per step (text/marks scenarios use diffs). */
const scripts: Record<string, Script[]> = {
  // Mirrors malformedBlocks() in ios/Tests/ListTests.swift.
  'malformed-blocks': [
    (doc) => {
      const body = doc.getText('body');
      body.insert(0, 'Head\nA\nA2\nB\nC\nD\nE\nF\nG');
      for (const [at, key] of [
        [4, 'a'],
        [6, 'a'],
        [9, 'b'],
        [11, 'c'],
        [13, 'd'],
        [15, 'e'],
        [17, 'f'],
        [19, 'g'],
      ] as const) {
        body.format(at, 1, { block: key });
      }
      body.format(0, 4, { block: 'x' });
      const blocks = doc.getMap('blocks');
      for (const [entry, value] of Object.entries({
        'a/kind': 'ordered',
        'b/checked': 1,
        'b/kind': 'checklist',
        'b/parent': 'c',
        'c/kind': 'unordered',
        'c/parent': 'b',
        'd/checked': 'true',
        'd/kind': 'checklist',
        'd/parent': 'missing',
        'e/id': 'dup',
        'e/kind': 'unordered',
        'f/id': 'dup',
        'f/kind': 'ordered',
        'g/kind': 'bogus',
      })) {
        blocks.set(entry, value);
      }
      doc.getArray('order').push(['c', 'b', 'a', 'e', 'f', 'g', 'ghost']);
    },
  ],
  'nested-lists': [
    (doc) => {
      const body = doc.getText('body');
      body.insert(0, 'Plan', { block: null });
      for (const [key, text] of [
        ['task', 'Task'],
        ['detail', 'Detail'],
        ['other', 'Other'],
        ['tail', ''],
      ]) {
        body.insert(body.length, '\n', { block: key });
        body.insert(body.length, text, { block: null });
        doc.getArray('order').push([key]);
      }
    },
    (doc) => {
      doc.getMap('blocks').set('head/kind', 'ordered');
      doc.getMap('blocks').set('head/id', 'plan');
      useFeature(doc, 'lists.ordered@1');
    },
    (doc) => {
      doc.getMap('blocks').set('task/kind', 'checklist');
      doc.getMap('blocks').set('task/checked', false);
      useFeature(doc, 'lists.checklist@1');
    },
    (doc) => {
      doc.getMap('blocks').set('detail/kind', 'unordered');
      useFeature(doc, 'lists.unordered@1');
    },
    (doc) => {
      doc.getMap('blocks').set('other/kind', 'checklist');
      doc.getMap('blocks').set('other/checked', false);
    },
    (doc) => doc.getMap('blocks').set('task/parent', 'head'),
    (doc) => doc.getMap('blocks').set('detail/parent', 'head'),
    (doc) => doc.getMap('blocks').set('detail/parent', 'task'),
    (doc) => doc.getMap('blocks').set('task/checked', true),
    (doc) => doc.getMap('blocks').set('other/checked', true),
    // `Plan\nTask\nDetail…`: remove task's LF and text.
    (doc) => doc.getText('body').delete(4, 5),
    // `Plan\nDetail\nOther\n`: remove head text, then detail's LF and text.
    (doc) => {
      doc.getText('body').delete(4, 7);
      doc.getText('body').delete(0, 4);
      doc.getMap('blocks').set('head/removed', true);
    },
  ],
};

const recordScript = (name: string, steps: SemanticSnapshot[], script: Script[]): string[] => {
  if (script.length !== steps.length) {
    throw new Error(`${name}: ${script.length} script steps for ${steps.length} corpus steps`);
  }
  const doc = new Doc();
  const updates: string[] = [];
  doc.on('update', (update: Uint8Array) => updates.push(Buffer.from(update).toString('base64')));
  script.forEach((edit, step) => {
    doc.transact(() => edit(doc));
    const actual = semanticSnapshot(doc);
    if (!deepEquals(actual, steps[step])) {
      throw new Error(
        `${name} step ${step}: ${JSON.stringify(actual)} != ${JSON.stringify(steps[step])}`
      );
    }
  });
  return updates;
};

const corpus: Record<string, SemanticSnapshot[]> = await bunFile(
  `${import.meta.dir}/corpus.json`
).json();
const file = bunFile(`${import.meta.dir}/updates/js.json`);
const recorded: Record<string, string[]> = (await file.exists()) ? await file.json() : {};
for (const [name, steps] of Object.entries(corpus)) {
  const script = scripts[name];
  recorded[name] ??= script ? recordScript(name, steps, script) : recordDiffs(steps);
}
await write(file, `${JSON.stringify(recorded, null, 2)}\n`);
