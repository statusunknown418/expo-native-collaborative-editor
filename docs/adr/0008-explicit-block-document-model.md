# Explicit block document model

The linear representation (Candidate 1: list kind, absolute depth, checked state, and identity on LF separators of one `YText`) failed the G4 concurrent nested-list gate, so documents use an explicit block model: every paragraph is a block with a stable key, a parent pointer, and a sibling position, and moving a block changes only those properties, never its text. Text, marks, and ordinary typing keep the single `YText`, so plain-text edits and their fixtures are unchanged.

## Representation

Yrs v1 updates to four root types, schema identifier `yrs-update-v1/blocks-1` for documents created from now on:

- `body` (`YText`): the head block's text, then for each other block an LF whose attribute `block` is that block's key, followed by the block's text. Marks (`bold`, `italic`, `heading`) stay text attributes. Inserted text carries `block: null`, so it never inherits a label. An LF without a valid, first-seen label is a line break inside its block.
- `blocks` (`YMap`), flat keys `<key>/<field>`: `kind` (`ordered` | `unordered` | `checklist`; absent for an ordinary paragraph), `id` (list-item identity; defaults to the key), `parent` (a block key), `checked` (boolean), and `removed` (boolean; only the head block, which has no LF to delete, is removed this way). Flat keys give per-field last-writer-wins without nested maps whose concurrent creation would overwrite each other.
- `order` (`YArray` of keys): sibling order; the first occurrence counts. Structural commands place a moved key right after its new previous sibling.
- `features` (`YMap`): unchanged.

Return inserts one labeled LF at the caret: the text after it becomes the new block, which is placed after the left block among its siblings, so it shows after the left block's subtree. Indent, outdent, Return on an empty nested item, and conversion of a nested item to a paragraph change `parent` and `order` only. Removing a block deletes its LF and text and keeps its fields and position, so its children, including ones inserted concurrently, are promoted in its place. Joining appends the right block's text to the left block (deleting the LF when the texts are adjacent in `body`, copying otherwise) and moves the right block's children after the left block's own.

## Deterministic projection

Display paragraphs and the semantic snapshot are a pure function of the stored state, implemented identically in `ios/Core/Blocks.swift` and `fixtures/semanticSnapshot.ts`, and never written back: opening a document creates no update. Ordinary paragraphs and the head block are roots, siblings sort by `order` rank then key, and preorder traversal assigns depth from list ancestors. A removed block or a block named only as a parent is a tombstone whose children are promoted in place; a cycle is cut at its smallest key; a reused identity, an unknown kind, or a non-boolean `checked` projects as an ordinary paragraph, an ordinary paragraph, or unchecked. The `malformed-blocks` fixture decodes to the same snapshot in Swift and JavaScript.

## Evidence

Two replicas, harness seed 1 with delayed, duplicated, reordered, and dropped deliveries; base `[x] Parent > - Child > 1. Grandchild`, `[ ] Sibling` under Parent, root `1. Next` (`ConcurrentListTests`). Both replicas, a full redelivery, and both reopened stores agree; every result keeps all text and items.

| Scenario | Candidate 1 | Candidate 2 converged result |
| --- | --- | --- |
| Indent Sibling ∥ edit its text | pass | Sibling edited under Child, after Grandchild |
| Indent Sibling ∥ outdent Sibling | pass (outdent won) | Sibling under Child (indent's parent) before Grandchild (outdent's position) |
| Remove only Child ∥ add New after Grandchild | **fail**: New became Grandchild's child | Grandchild, New, Sibling, all under Parent |
| Split Child at `Ch` ∥ join Sibling into Child | pass: `ChSibling`, `ild` | `Ch` keeps Grandchild; `ildSibling` after it |
| Outdent Child past Sibling ∥ add Deep after Grandchild | **fail**: Deep stayed under Parent | Parent > Sibling; Child > Grandchild, Deep |
| Indent Sibling ∥ indent Next twice | **fail**: Next became Sibling's sibling | Parent > Child > Grandchild, Sibling > Next (four mixed levels) |
| Return on empty nested item ∥ type into it | **fail**: text landed in Sibling, item empty | Parent > Sibling; root item `Typed` |

Candidate 1 failed because an absolute depth loses which item is the parent, and its subtree moves delete and reinsert text, leaving concurrent insertions at the old location.

- G3: 20 recorded seeds, three replicas, 150 random steps from a shared three-level list (text with Unicode and LFs, bold/italic/heading, list conversion, indent/outdent, Return, Backspace, removal with and without children, checklist toggles) converge with unique identities, a valid tree, and checked state only on checklist items; redelivery and reopening change nothing.
- The example's scripted scenario (`RemoteEditTests`, Release) holds a remote parent removal while Return and `Deep` are typed beneath it on the editing surface; both replicas converge to `Parent > Grandchild, Deep`.
- Every existing editing-surface, list, formatting, undo, and synchronization test passes unchanged except those that pinned Candidate 1 storage or outcomes (four `ListTests`, the Release list scenario's trailing LF) and the schema identifier; the `nested-lists` fixtures were re-recorded in both engines. Evidence log: [`m1-evidence.md`](../m1-evidence.md#concurrent-nested-lists-and-the-document-representation-g3g4-10).

## Consequences

- Text inserted concurrently into a block that another replica removes, or joins by copying (only non-adjacent texts are copied), is kept but joins whichever block precedes the removed one in `body`.
- Concurrent placements of one key may combine one replica's parent with another's sibling position, as in the indent/outdent row; the result is valid but neither replica's exact intent.
- Removed blocks keep their fields and `order` entries, and a removed head block stays in `body` as a hidden empty paragraph; compaction is future work.
- Documents created under `yrs-update-v1/plain-text-0` decode unchanged as text; list structure they stored under Candidate 1 is not migrated.
- Lines pasted into a list item that has children follow its subtree, so the session sends the surface a correcting edit.
