# Native Collaborative Editor

Rich-text documents that people can edit on a device and, when synchronization is enabled, together with other people. Application records and their access rules remain distinct from document content.

## Language

**Document**:
The persistent rich-text body being edited, including its formatting, lists, checklists, references, and photo attachments. A host application's note can contain a document as well as separate title, collection, visibility, and lifecycle metadata.
_Avoid_: Note (when referring only to the editor-owned body)

**List item**:
An entry in an ordered list, unordered list, or checklist. A list item can have child list items.

**Checklist item**:
A list item with a checked or unchecked state.

**Checklist cascade**:
An explicit local action that sets a parent checklist item and its currently known descendant checklist items to the same checked or unchecked state. It neither derives parent state from children nor imposes a continuing rule on future children.

**Editing surface**:
A presentation through which someone reads or edits a document, such as a full note, compact composer, or read-only view. The surface is not the document itself.

**Document session**:
An open document on one device, shared by every editing surface that presents it. It holds the document's undo history and unsaved input from opening until the host closes it or the app terminates.
_Avoid_: Session (unqualified; an authentication session belongs to the host application), editor session

**Feature plugin**:
A selectable editor extension that supplies a feature's controls, behavior, or host-data integration. It is distinct from a sync adapter.

**Local-only document**:
A document saved durably on a device without synchronization.
_Avoid_: Offline document (a synchronized document can also be edited offline)

**Synchronized document**:
A document with durable local content whose changes are exchanged with other authorized replicas.
_Avoid_: Synced document (synchronization being enabled is distinct from current delivery status)

**Sync adapter**:
The connection through which a synchronized document exchanges durable changes with authorized remote storage.
_Avoid_: Sync provider (for this interface); provider without qualification (a UI configuration provider is a different concept)

**Mention**:
A reference to a person embedded in a document, with identity distinct from its displayed name.
_Avoid_: Record reference (for a person mention)

**Record reference**:
A typed reference embedded in a document to an application-owned record. It is neither a duplicate of the target nor an implicit grant of access to it.
_Avoid_: Mention (for a non-person record)

**Record type**:
A host application's category of records that a record reference can target, such as a task, goal, meal, or recipe. A new record type is not, by itself, a new kind of document content.

**Photo attachment**:
A photo associated with a document through a stable reference. Its local availability and upload completion are distinct states.

**Saved on this phone**:
An acknowledgement that content is durable on the current device. It does not imply server acceptance, partner delivery, or that anyone has read it.

**Unsaved input**:
Document changes not yet durably committed on the current device. Retained unsaved input is distinct from saved content and is not guaranteed to survive process termination.

**Pending synchronization**:
Committed local document changes waiting for durable server acceptance. They are already saved on the device, unlike unsaved input; photo upload completion is a separate state.
_Avoid_: Unsaved (for already committed local work)
