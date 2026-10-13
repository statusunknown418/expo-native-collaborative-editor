# Core, feature plugins, and sync adapters

Use a Better Auth-inspired composition model: a configured editor instance combines a small native core, explicitly registered feature plugins with typed options, and an optional sync adapter. Borrow the package composition pattern, not Better Auth's authentication runtime or HTTP request middleware; no Better Auth dependency is needed for this architecture.

## Composition

- The core owns native document sessions, serialized editing transactions, selection/composition binding, encrypted local persistence, and the guarantees in the editing and privacy contracts. Select one CRDT engine after native proof rather than making engines another public plugin category.
- Feature plugins expose commands, menus, host-data integration, resolvers, and feature-scoped typed options through one public extension interface. Built-in feature plugins provide the agreed formatting, nested lists/checklists, references/mentions, and photo capabilities; hosts can select their authoring affordances and optional work without requiring a package or a plugin for every record model.
- Plugin options are configuration, not a flat global flag framework. `caution__enableChecklistChildrenAutoCompletion` remains the exact experimental option name, belongs to checklist feature configuration, and defaults to `false`; the native session receives normalized configuration for future local actions.
- The sync adapter satisfies the provider-neutral bootstrap, bounded pull/subscription, immutable append, durable receipt, and checkpoint-recovery contract. It does not own editing semantics, feature options, application records, or authentication policy. Without an adapter, the same core provides durable local-only documents rather than a fake networking implementation.

## Native and compatibility constraints

All feature mutations go through the core's validated transaction and persistence path; plugins cannot bypass durability, access checks, or error reporting through direct document/storage writes. Native typing and checkbox behavior must not require per-keystroke JavaScript or network middleware.

JavaScript plugins can configure and integrate capabilities already supported by the native build. New native appearances or native editing behavior require the corresponding Swift implementation and a native rebuild; declaring a JavaScript plugin must not pretend an unavailable native capability exists. Unknown unsafe document features remain read-only under the compatibility policy. Disabling authoring UI or optional work does not strip, hide, or normalize away supported stored content; compatible fallback presentation remains distinct from unsupported semantics.

Record models reuse the generic reference feature and host-supplied records. Their types are not new document features by themselves, and arbitrary custom block widgets remain outside the initial release.

## Convex first

Ship a separate Convex client sync adapter and reusable server storage component. The client accepts the host's authenticated Convex client and authorized function references; host wrappers derive identity and authorize document scope before invoking the component. Convex synchronizes the native durable document store rather than replacing it. Core imports work without Convex, and backend code imports protocol contracts rather than the native UI package. Other production adapters are not required for the first release; the controllable reference adapter remains a conformance tool, not proof of production durability.

## Proof before freezing the interface

M1 must demonstrate host-defined record integration and native extension registration without core source changes, reject unavailable native capabilities, preserve supported content when optional authoring features are disabled, and keep local input/persistence working without JavaScript networking. Actual public signatures, plugin/native capability descriptors, and the selected document representation follow these results rather than precede them.

## Primary-source inspiration

- [Better Auth plugins](https://better-auth.com/docs/concepts/plugins): explicit server/client plugin arrays, unique plugin IDs, option-bearing plugin factories, and client actions.
- [Better Auth database adapters](https://better-auth.com/docs/concepts/database): database integration is configured separately from feature plugins.
- [Better Auth options](https://better-auth.com/docs/reference/options): typed feature options, including enable/disable settings, complement plugin composition rather than replace it.
