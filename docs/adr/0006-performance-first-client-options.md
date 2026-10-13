# Performance-first client options

Optional editing behavior and optional work belong in feature-scoped typed plugin options within editor/document-session client configuration, which host hooks or a UI configuration provider can pass through, not in the sync adapter. `caution__enableChecklistChildrenAutoCompletion` is an opt-in experimental checklist feature option and defaults to `false`, preserving independent checklist item state by default. Composition follows [the core, plugin, and adapter architecture](0007-core-feature-plugins-and-sync-adapters.md).

## Scope and constraints

- Add options only for concrete optional behavior or work, rather than a speculative flag catalog or a separate flag service. Reuse existing feature configuration and optional hooks where they express the choice.
- Disabled optional features avoid their associated optional work; disabling creation or UI affordances must not strip, normalize away, or misrepresent already-stored content.
- Flags cannot weaken local durability, access checks, input validation, or unknown-content preservation. Unsupported document features still follow the read-only compatibility policy.
- The native session receives the configuration needed to execute editing behavior without a JavaScript round trip for each keystroke or checkbox action. Updating client options must not reset document content or undo history.
- With checklist child auto-completion disabled, a parent toggle must not perform an extra descendant traversal for cascade behavior. Enabled behavior may involve subtree-sized work and requires native performance and correctness proof; no benchmark result is implied by this decision.

## Enabled behavior

With `caution__enableChecklistChildrenAutoCompletion` enabled, an explicit local parent check/uncheck action sets the same state on all currently known descendant checklist items at every nesting level, including descendants beneath ordered or unordered items. There is no upward completion roll-up.

Cascading does not run on document open, option enablement, remote updates, or later/concurrent child insertion. The action produces concrete document edits that synchronize normally; receiving clients apply those edits without rerunning the cascade, regardless of their own option value. A later or concurrently inserted child retains its own state even beneath a checked parent.

## Native proof

Treat a cascade as one undoable user action, with durable local persistence before a saved acknowledgement. Verify mixed client option values, concurrent subtree edits and child insertion, restart recovery, selective undo after remote edits, and subtree-sized work on native devices. Exact public configuration signatures and supported limits remain implementation decisions to establish through this proof.
