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

type Kind = SemanticListItem['kind'];
type Fields = { kind?: Kind; id?: string; parent?: string; checked: boolean; removed: boolean };
type Chunk = { text: string; attributes: Record<string, unknown> };
type Segment = {
  key: string;
  lfAttributes: Record<string, unknown>;
  chunks: Chunk[];
  length: number;
};

const HEAD = 'head';
const KINDS: unknown[] = ['ordered', 'unordered', 'checklist'];
const byKey = (a: string, b: string) => {
  if (a === b) {
    return 0;
  }
  return a < b ? -1 : 1;
};

/** A first-seen labeled LF starts a block; any other LF is a line break inside one. */
function readSegments(doc: Y.Doc) {
  const segments: Segment[] = [{ chunks: [], key: HEAD, length: 0, lfAttributes: {} }];
  const appendChunk = (text: string, attributes: Record<string, unknown>) => {
    const segment = segments.at(-1) as Segment;
    segment.chunks.push({ attributes, text });
    segment.length += text.length;
  };
  const segmentIndex = new Map([[HEAD, 0]]);
  for (const { insert, attributes = {} } of doc.getText('body').toDelta()) {
    if (typeof insert !== 'string') {
      continue; // ponytail: embeds are not projected until record references (#15).
    }
    let pieceStart = 0;
    const key = attributes.block;
    const lf = insert.indexOf('\n');
    if (typeof key === 'string' && key.length > 0 && !segmentIndex.has(key) && lf !== -1) {
      appendChunk(insert.slice(0, lf), attributes);
      segmentIndex.set(key, segments.length);
      segments.push({ chunks: [], key, length: 0, lfAttributes: attributes });
      pieceStart = lf + 1;
    }
    appendChunk(insert.slice(pieceStart), attributes);
  }
  return { segmentIndex, segments };
}

/** Flat `<key>/<field>` entries, split at the last `/`. */
function readFields(doc: Y.Doc) {
  const fields = new Map<string, Fields>();
  for (const [entry, value] of Object.entries(doc.getMap('blocks').toJSON())) {
    const slash = entry.lastIndexOf('/');
    const key = entry.slice(0, slash);
    if (slash === -1 || key.length === 0) {
      continue;
    }
    const f = fields.get(key) ?? { checked: false, removed: false };
    fields.set(key, f);
    const isText = typeof value === 'string' && value.length > 0;
    switch (entry.slice(slash + 1)) {
      case 'kind':
        f.kind = KINDS.includes(value) ? (value as Kind) : undefined;
        break;
      case 'id':
        f.id = isText ? value : f.id;
        break;
      case 'parent':
        f.parent = isText && value !== key ? value : f.parent;
        break;
      case 'checked':
        f.checked = value === true;
        break;
      case 'removed':
        f.removed = value === true;
        break;
      default:
    }
  }
  return fields;
}

/** Sibling rank: first occurrence in `order`; a present block missing from it follows its body
 * predecessor. */
function readRank(doc: Y.Doc, segments: Segment[]) {
  const ranked: string[] = [];
  for (const key of doc.getArray('order').toArray()) {
    if (typeof key === 'string' && key !== HEAD && !ranked.includes(key)) {
      ranked.push(key);
    }
  }
  segments.forEach(({ key }, index) => {
    if (index > 0 && !ranked.includes(key)) {
      const predecessor = segments[index - 1].key;
      ranked.splice(predecessor === HEAD ? 0 : ranked.indexOf(predecessor) + 1, 0, key);
    }
  });
  const rank = new Map(ranked.map((key, index) => [key, index]));
  rank.set(HEAD, -1);
  return rank;
}

/** List blocks keep their declared parent, present or removed; others are roots. Each cycle
 * becomes a tree rooted at its smallest key. Returns each node's sorted children; roots under ''. */
function buildTree(
  segments: Segment[],
  segmentIndex: Map<string, number>,
  fields: Map<string, Fields>,
  rank: Map<string, number>
) {
  const parent = new Map<string, string>();
  const nodes = segments.map(({ key }) => key);
  const known = new Set(nodes);
  const pending = [...nodes];
  for (let key = pending.pop(); key !== undefined; key = pending.pop()) {
    const declared = fields.get(key)?.parent;
    const isParagraph = segmentIndex.has(key) && fields.get(key)?.kind === undefined;
    if (key === HEAD || isParagraph || declared === undefined) {
      continue;
    }
    parent.set(key, declared);
    if (!known.has(declared)) {
      known.add(declared);
      nodes.push(declared);
      pending.push(declared);
    }
  }
  const visited = new Map<string, boolean>(); // false while on the current path
  for (const start of nodes) {
    const path: string[] = [];
    let current: string | undefined = start;
    while (current !== undefined && !visited.has(current)) {
      visited.set(current, false);
      path.push(current);
      current = parent.get(current);
    }
    if (current !== undefined && visited.get(current) === false) {
      parent.delete(path.slice(path.indexOf(current)).sort(byKey)[0]);
    }
    for (const node of path) {
      visited.set(node, true);
    }
  }
  const children = new Map<string, string[]>();
  for (const node of nodes) {
    const key = parent.get(node) ?? '';
    children.set(key, [...(children.get(key) ?? []), node]);
  }
  for (const list of children.values()) {
    list.sort((a, b) => {
      const left = rank.get(a) ?? Number.POSITIVE_INFINITY;
      const right = rank.get(b) ?? Number.POSITIVE_INFINITY;
      return left === right ? byKey(a, b) : left - right;
    });
  }
  return children;
}

function appendMark(
  marks: SemanticMark[],
  offset: number,
  attributes: Record<string, unknown>,
  length: number
) {
  const { bold, italic, heading } = attributes;
  const formatting = {
    ...(bold === true ? { bold: true as const } : {}),
    ...(italic === true ? { italic: true as const } : {}),
    ...(typeof heading === 'number' && heading > 0 ? { heading } : {}),
  };
  if (Object.keys(formatting).length === 0 || length === 0) {
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

/** The list item a visible block projects to; duplicate IDs project as ordinary paragraphs. */
function listItem(
  key: string,
  f: Fields | undefined,
  ancestors: string[],
  ids: Set<string>,
  offset: number,
  length: number
): SemanticListItem | undefined {
  const id = f?.id ?? key;
  if (!f?.kind || ids.has(id)) {
    return;
  }
  ids.add(id);
  return {
    id,
    kind: f.kind,
    ...(ancestors.length ? { parent: ancestors.at(-1) } : {}),
    ...(f.kind === 'checklist' ? { checked: f.checked } : {}),
    depth: ancestors.length,
    length,
    offset,
  };
}

/** Empty `marks`, `features`, and `listItems` are omitted. */
const withoutEmpty = (
  text: string,
  marks: SemanticMark[],
  features: string[],
  listItems: SemanticListItem[]
): SemanticSnapshot => ({
  text,
  ...(marks.length ? { marks } : {}),
  ...(features.length ? { features } : {}),
  ...(listItems.length ? { listItems } : {}),
});

/** The block model projection; mirrors BlockProjection in ios/Core/Blocks.swift. */
export const semanticSnapshot = (doc: Y.Doc): SemanticSnapshot => {
  const { segments, segmentIndex } = readSegments(doc);
  const fields = readFields(doc);
  const children = buildTree(segments, segmentIndex, fields, readRank(doc, segments));
  // Preorder: removed or ordinary blocks pass their list ancestry to their children unchanged.
  const marks: SemanticMark[] = [];
  const listItems: SemanticListItem[] = [];
  const ids = new Set<string>();
  let text = '';
  let paragraphs = 0;
  const stack: [string, string[]][] = (children.get('') ?? []).toReversed().map((key) => [key, []]);
  for (let next = stack.pop(); next; next = stack.pop()) {
    const [key, ancestors] = next;
    const childAncestors = [...ancestors];
    const segment = segments[segmentIndex.get(key) ?? -1] as Segment | undefined;
    const f = fields.get(key);
    const visible = segment !== undefined && !(f?.removed === true && segment.length === 0);
    if (visible) {
      if (paragraphs > 0) {
        appendMark(marks, text.length, segment.lfAttributes, 1);
        text += '\n';
      }
      paragraphs += 1;
      const item = listItem(key, f, ancestors, ids, text.length, segment.length);
      if (item) {
        listItems.push(item);
        childAncestors.push(item.id);
      }
      for (const chunk of segment.chunks) {
        appendMark(marks, text.length, chunk.attributes, chunk.text.length);
        text += chunk.text;
      }
    }
    for (const child of (children.get(key) ?? []).toReversed()) {
      stack.push([child, childAncestors]);
    }
  }
  return withoutEmpty(text, marks, [...doc.getMap('features').keys()].sort(byKey), listItems);
};
