import type * as Y from 'yjs';

export type SemanticMark = {
  offset: number;
  length: number;
  bold?: true;
  italic?: true;
  heading?: number;
};

/** Engine-independent projection, shared with Swift's SemanticSnapshot. */
export type SemanticSnapshot = {
  text: string;
  marks?: SemanticMark[];
  features?: string[];
};

export const semanticSnapshot = (doc: Y.Doc): SemanticSnapshot => {
  const body = doc.getText('body');
  const marks: SemanticMark[] = [];
  let offset = 0;
  for (const { insert, attributes = {} } of body.toDelta()) {
    if (typeof insert !== 'string') continue;
    const { bold, italic, heading } = attributes;
    const formatting = {
      ...(bold === true ? { bold: true as const } : {}),
      ...(italic === true ? { italic: true as const } : {}),
      ...(typeof heading === 'number' && heading > 0 ? { heading } : {}),
    };
    if (Object.keys(formatting).length > 0) {
      const last = marks.at(-1);
      if (
        last &&
        last.offset + last.length === offset &&
        last.bold === formatting.bold &&
        last.italic === formatting.italic &&
        last.heading === formatting.heading
      ) {
        last.length += insert.length;
      } else {
        marks.push({ offset, length: insert.length, ...formatting });
      }
    }
    offset += insert.length;
  }
  const features = [...doc.getMap('features').keys()].sort();
  return {
    text: body.toString(),
    ...(marks.length ? { marks } : {}),
    ...(features.length ? { features } : {}),
  };
};
