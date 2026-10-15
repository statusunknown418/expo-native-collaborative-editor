// Records Yjs updates for the corpus.json scenarios that updates/js.json lacks. Recorded updates
// are golden: existing entries are never rewritten.
import { file as bunFile, write } from 'bun';
import { Doc, type Text as YText } from 'yjs';

import {
  type SemanticListItem,
  type SemanticMark,
  type SemanticSnapshot,
  semanticSnapshot,
} from './semanticSnapshot';

function changedAttributes(before: SemanticMark | undefined, after: SemanticMark | undefined) {
  const attributes: Record<string, boolean | number | null> = {};
  for (const key of ['bold', 'italic', 'heading'] as const) {
    if (before?.[key] !== after?.[key]) {
      attributes[key] = after?.[key] ?? null;
    }
  }
  return attributes;
}

function listAttributeChanges(
  attributes: Record<string, unknown>,
  item: SemanticListItem | undefined
) {
  const desired = {
    listChecked: item?.kind === 'checklist' ? (item.checked ?? false) : null,
    listDepth: item?.depth ?? null,
    listID: item?.id ?? null,
    listKind: item?.kind ?? null,
  };
  const changed: Record<string, string | number | boolean | null> = {};
  for (const key of ['listID', 'listKind', 'listDepth', 'listChecked'] as const) {
    if ((attributes[key] ?? null) !== desired[key]) {
      changed[key] = desired[key];
    }
  }
  return changed;
}

function formatListSeparators(body: YText, listItems: SemanticListItem[]) {
  let offset = 0;
  for (const { insert, attributes = {} } of body.toDelta()) {
    if (typeof insert !== 'string') {
      continue;
    }
    for (let index = 0; index < insert.length; index += 1) {
      const item =
        insert[index] === '\n'
          ? listItems.find(({ offset: start, length }) => start + length === offset + index)
          : undefined;
      const changed = listAttributeChanges(attributes, item);
      if (Object.keys(changed).length) {
        body.format(offset + index, 1, changed);
      }
    }
    offset += insert.length;
  }
}

/** Yjs updates that take an empty document through `steps`, one transaction per step. */
const record = (steps: SemanticSnapshot[]): string[] => {
  const doc = new Doc();
  const body = doc.getText('body');
  const updates: string[] = [];
  doc.on('update', (update: Uint8Array) => updates.push(Buffer.from(update).toString('base64')));
  for (const step of steps) {
    const { text, marks = [], features = [], listItems = [] } = step;
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
      // List identity belongs only to real LF separators, never to inserted paragraph text.
      formatListSeparators(body, listItems);
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

const corpus: Record<string, SemanticSnapshot[]> = await bunFile(
  `${import.meta.dir}/corpus.json`
).json();
const file = bunFile(`${import.meta.dir}/updates/js.json`);
const recorded: Record<string, string[]> = (await file.exists()) ? await file.json() : {};
for (const [name, steps] of Object.entries(corpus)) {
  recorded[name] ??= record(steps);
}
await write(file, `${JSON.stringify(recorded, null, 2)}\n`);
