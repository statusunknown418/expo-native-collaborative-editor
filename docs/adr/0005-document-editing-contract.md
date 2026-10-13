# Document editing contract

The first feature-complete release includes nested checklists, nested unordered lists, and nested ordered lists. This supersedes the input proposal's single-level list limit and its deferral of nested structures; arbitrary custom block widgets remain out of scope under the reference extension contract.

## List editing

- Return splits an item: the left part keeps its identity, checked state, and existing children; the new right item is a sibling with no children and starts unchecked if it is a checklist item.
- Return on an empty nested item outdents it by one level with its children. At the root level it exits the list into an ordinary paragraph, preserving and promoting any children to root level; this applies to all three list kinds.
- Joining items preserves both texts and keeps the left item's identity and checked state. Both groups of children remain under the left item, with the left group followed by the right group.
- Ordered lists, unordered lists, and checklists can nest within one another.
- Indent/outdent moves an item with all its descendants, preserving relative positions and checked states. Indent makes it a child of its previous sibling; outdent moves it up one level.
- Removing only a parent item promotes its children by one level rather than deleting unselected content. Selecting the parent and its children still deletes that selected content.

Checklist completion is independent per item by default: changing a parent does not automatically change its children, and changing children does not automatically change the parent. The host may opt into the explicit local cascade defined by `caution__enableChecklistChildrenAutoCompletion` in [client configuration](0006-performance-first-client-options.md).

## Undo lifetime

Selective local undo survives navigation and editing-surface remounts within the same document session, but resets when that session closes or the app terminates. Committed content and pending synchronization survive restart independently of undo history.

## Clipboard behavior

Copy/paste preserves supported formatting and nested list structure. Pasted checklist items have independent identities and completion states; checking a pasted item does not change its source.

Within the same host application, a pasted record reference retains its target only when the host approves the destination. Otherwise paste permitted plain text, or a neutral placeholder if the label cannot be disclosed. References copied outside the host application become their permitted display text, not application-internal record IDs.

## Editing errors

An attempted content mutation forbidden by read-only, revoked, deleted, or incompatible document state must fail with an error exposed to the host application; it must not change committed content or queue a new update. Command calls throw or reject, while direct native input reports the same classified failure through a host error callback rather than an uncaught application-crashing exception. The host decides whether to show a toast, message, or another recovery flow; the editor supplies no notification UI of its own.

Expired server authentication and temporary network unavailability do not by themselves forbid eligible offline editing. Already-pending changes rejected after revocation or deletion follow [the quarantine policy](0001-document-privacy-and-offline-access.md).

## Local persistence failure

If a local commit fails, retain the current unsaved input, expose the failure to the host, and reject further content mutations until persistence succeeds. The host may offer retry, permitted export, or explicitly confirmed discard; uncommitted content neither uploads nor receives a saved acknowledgement.

Recovery retries the retained pending work rather than repeating the original insertion command, avoiding duplicate insertion. Retained unsaved input is not guaranteed to survive process termination until it is durably committed or successfully exported; committed changes waiting for synchronization remain distinct from that volatile input.

## Native proof

M1 must exercise nested-list indentation and parent/child edits under concurrency, not only a single checklist item. The linear separator-based representation remains a candidate, not a selected schema; it must demonstrate the agreed hierarchy semantics before adoption, or be replaced by an explicit block model. Native proof must also cover permission changes during input/composition, rejected command calls, and host-visible errors without falsely acknowledging rejected content as saved.

Clipboard proof must demonstrate independent pasted checklist items and destination-authorized references without leaking record IDs into external representations. Storage-failure proof must exercise retained input, rejected subsequent mutations, retry without duplication, and no false saved or uploaded state.
