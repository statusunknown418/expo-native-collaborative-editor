# Host-defined inline references

Applications can supply dynamically loaded records for typed inline references, together with suggestions, permitted labels, and tap actions, through [the public feature-plugin interface](0007-core-feature-plugins-and-sync-adapters.md) without changing the editor core. A document retains stable reference identities rather than copying host database records; new record types reuse the existing record-reference semantics and do not, by themselves, introduce new document features or require a plugin per record model.

The first release supports host-defined inline content, commands, menus, and resolver hooks using the existing native appearance through JavaScript configuration. A new native appearance requires a host-supplied Swift renderer and a native rebuild, not a fork of the editor core; arbitrary full-content block widgets remain outside the first release. Disclosure follows [the document privacy policy](0001-document-privacy-and-offline-access.md), while genuinely unknown document features follow [the read-only compatibility policy](0002-unknown-document-features-are-read-only.md).

## Reference behavior

Reference names are live, host-supplied display data: a target rename updates the permitted display name without changing reference identity or creating a document-content edit. Offline presentation uses an approved cached name or fallback under the document privacy policy.

Mentions and record references are selectable and deletable as whole units rather than editable letter by letter. Explicit conversion to ordinary text removes the reference; editing its display name must never silently retarget it.
