import type * as Y from 'yjs';

export type SemanticMark = {
  offset: number;
  length: number;
  bold?: true;
  italic?: true;
  heading?: number;
};

export type SemanticListItem = {
  id: string;
  kind: 'ordered' | 'unordered' | 'checklist';
  parent?: string;
  checked?: boolean;
  offset: number;
  length: number;
  depth: number;
};

/** Engine-independent projection, shared with Swift's SemanticSnapshot. */
export type SemanticSnapshot = {
  text: string;
  marks?: SemanticMark[];
  features?: string[];
  listItems?: SemanticListItem[];
};

export const semanticSnapshot = (doc: Y.Doc): SemanticSnapshot => {
  const body = doc.getText('body');
  const marks: SemanticMark[] = [];
  const listItems: SemanticListItem[] = [];
  const seenIDs = new Set<string>();
  const ancestors: string[] = [];
  let paragraphStart = 0;
  let offset = 0;
  function appendListItem(attributes: Record<string, unknown>, separator: number) {
    const { listID, listKind, listDepth, listChecked } = attributes;
    if (
      typeof listID !== 'string' ||
      listID.length === 0 ||
      seenIDs.has(listID) ||
      (listKind !== 'ordered' && listKind !== 'unordered' && listKind !== 'checklist') ||
      typeof listDepth !== 'number' ||
      !Number.isInteger(listDepth) ||
      listDepth < 0
    ) {
      ancestors.length = 0;
      return;
    }
    const depth = Math.min(listDepth, ancestors.length);
    ancestors.length = depth;
    const parent = ancestors.at(-1);
    listItems.push({
      id: listID,
      kind: listKind,
      ...(parent === undefined ? {} : { parent }),
      ...(listKind === 'checklist' ? { checked: listChecked === true } : {}),
      depth,
      length: separator - paragraphStart,
      offset: paragraphStart,
    });
    seenIDs.add(listID);
    ancestors.push(listID);
  }
  function appendMark(attributes: Record<string, unknown>, length: number) {
    const { bold, italic, heading } = attributes;
    const formatting = {
      ...(bold === true ? { bold: true as const } : {}),
      ...(italic === true ? { italic: true as const } : {}),
      ...(typeof heading === 'number' && heading > 0 ? { heading } : {}),
    };
    if (Object.keys(formatting).length === 0) {
      return;
    }
    const last = marks.at(-1);
    if (
      last &&
      last.offset + last.length === offset &&
      last.bold === formatting.bold &&
      last.italic === formatting.italic &&
      last.heading === formatting.heading
    ) {
      last.length += length;
    } else {
      marks.push({ length, offset, ...formatting });
    }
  }
  for (const { insert, attributes = {} } of body.toDelta()) {
    if (typeof insert !== 'string') {
      continue;
    }
    for (let index = insert.indexOf('\n'); index !== -1; index = insert.indexOf('\n', index + 1)) {
      const separator = offset + index;
      appendListItem(attributes, separator);
      paragraphStart = separator + 1;
    }
    appendMark(attributes, insert.length);
    offset += insert.length;
  }
  const features = [...doc.getMap('features').keys()].sort();
  return {
    text: body.toString(),
    ...(marks.length ? { marks } : {}),
    ...(features.length ? { features } : {}),
    ...(listItems.length ? { listItems } : {}),
  };
};
