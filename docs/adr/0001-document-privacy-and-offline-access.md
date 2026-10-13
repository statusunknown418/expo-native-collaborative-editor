# Document privacy and offline access

The first synchronized release uses server-readable document content, with authorized access and no end-to-end encryption claim, to support the planned server search, projections, compaction, and recovery. Offline continuity and access restrictions are separate guarantees: server authentication expiry must not silently disable eligible local work, and cached permissions must not authorize new server operations.

## Accepted policy

- An already locally unlocked account may read and edit cached documents under its last confirmed permissions without periodic connectivity. Expired server authentication pauses networking, not local writing; learned revocation stops ordinary access to affected content.
- Unsynced changes survive sign-out in encrypted, account-isolated storage and remain inaccessible until the same account reauthenticates. Another account must neither display nor upload them; destructive removal requires explicit consent. The host application owns the retention/discard policy, and the editor must support it.
- The host application approves disclosure of a record reference and any descriptive fallback text to the document's audience. Unauthorized targets use a neutral placeholder, rather than exposing cached descriptive labels. Unavailable and unauthorized targets are distinct; denying resolution cannot retract text already embedded in a shared document.
- Pending changes rejected after learned revocation or document deletion are quarantined in protected storage; delivery stops and ordinary access remains blocked. The host application decides permitted recovery, export, or discard; the editor neither silently loses the changes nor automatically copies them into a private document or revives a deleted document. Forbidden editing attempts follow [the editing-error contract](0005-document-editing-contract.md).
- Encryption covers all locally stored document content, including synchronized cached documents, local-only documents, staged photos, and stored reference labels, not just pending changes. Missing encryption keys produce a visible recovery failure rather than silently replacing the store with an empty one.

## Implementation and host policy

Encryption and key recovery mechanisms still require native proof. The host application's specific permissions for recovery/export/discard remain application policy, not editor-owned UI. This ADR does not claim that a disconnected device can immediately learn revocation or retract previously disclosed content.
