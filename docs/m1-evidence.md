# M1 evidence log

Findings from M1 tickets, recorded as input to the foundation decision (#18). The accepted engine-ordering restriction is recorded in ADR 0007; the final foundation decision remains #18.

## Engine packaging (G1, #3)

Candidate: Yrs through [SwiftYrs](https://github.com/siuying/SwiftYrs) 0.7.0 (a C-ABI shim over Yrs 0.27, released 2026-09-11), integrated with React Native's `spm_dependency` in `ios/ExpoNativeCollaborativeEditor.podspec`. SwiftYrs was evaluated before YSwift because it binds current Yrs and already exposes the capabilities #1 requires (rich-text attributes, sticky indexes, origin-filtered undo, state vectors, snapshots). YSwift's latest release is 0.2.1 from 2024-04-04; it was not built.

Result: **pass for packaging only**. Unrestricted out-of-order application fails on the bound engine; [#20's decision](#out-of-order-engine-decision-g1g3-20) records the accepted G1/G3 restriction. The candidate builds and links through Expo autolinking with no host steps:

| Configuration | Destination                      | Result             |
| ------------- | -------------------------------- | ------------------ |
| Debug         | iOS 26.2 simulator (unit tests)  | built, tests pass  |
| Debug         | `generic/platform=iOS Simulator` | built (arm64)      |
| Release       | `generic/platform=iOS Simulator` | built (arm64)      |
| Release       | iOS 26.2 simulator (UI test)     | built, test passes |
| Debug         | `generic/platform=iOS`           | built (arm64)      |
| Release       | `generic/platform=iOS`           | built (arm64)      |

Command: `xcodebuild -workspace ios/exponativecollaborativeeditorexample.xcworkspace -scheme exponativecollaborativeeditorexample -configuration <Debug|Release> -destination <destination> CODE_SIGNING_ALLOWED=NO build`, run from `example/` after `bun run prebuild`. No physical iPhone was connected; device builds are unsigned `generic/platform=iOS` builds.

Cost, measured with clean Release `generic/platform=iOS` builds into a fresh `-derivedDataPath` (Xcode 27.0, Apple silicon, warm SwiftPM download cache). Baseline is 2436b24, built from a worktree in the same session:

| Measure                        | Baseline 2436b24       | With SwiftYrs          | Delta                                     |
| ------------------------------ | ---------------------- | ---------------------- | ----------------------------------------- |
| App executable                 | 7,942,896 B            | 10,512,600 B           | +2,569,704 B (+32%)                       |
| `.app` bundle                  | 34,348 KB              | 36,856 KB              | +2,508 KB                                 |
| Clean build, wall clock (runs) | 88.5 s, 85.5 s, 73.8 s | 69.7 s, 86.4 s, 78.4 s | none above run-to-run spread (about 15 s) |
| Package resolution             | none                   | 7.5 s                  | +7.5 s                                    |

Yrs arrives as a prebuilt `YrsBridge.xcframework`, so a clean build compiles only SwiftYrs's Swift sources and adds no Rust step.

Packaging findings:

- SwiftYrs's XCFramework has arm64 device and simulator slices only (its ADR 0006). Release simulator builds include x86_64 and failed to link (`Undefined symbol: _yrs_bridge_*` for x86_64) until the podspec set `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` through `user_target_xcconfig`. Intel simulators are unsupported.
- `pod install` prints React Native's warning that a Swift package in a statically linked pod "might cause linker errors". None occurred in the builds above.
- SwiftYrs's `Package.swift` declares SQLite.swift and stream-video-swift-webrtc for its other products, so resolution downloads them even though only the `SwiftYrs` product links. On disk after resolution: StreamWebRTC artifact 95 MB, `YrsBridgeFFI` artifact 62 MB (all slices). Neither the WebRTC nor the SQLite.swift code reaches the app.
- SwiftYrs exports a class named `Observation`, which shadows the `Observation` module in files that import SwiftYrs, so the `@Observable` macro fails to expand there. `DocumentSession` uses `ObservableObject` instead.
- Yrs text offsets are UTF-16 code units (SwiftYrs ADR 0023 creates every document with `OffsetKind::Utf16`). `TextEdit` converts Swift `String` indices to those offsets explicitly, and `DocumentSessionTests` show emoji modifiers, ZWJ sequences, combining marks, and canonically equivalent clusters are replaced as whole grapheme clusters.
- The cross-language half of the candidate (Yjs decoding the same bytes): see [Cross-language fixtures](#cross-language-fixtures-g2-4).

## Cross-language fixtures (G2, #4)

Scope: text. The corpus (`fixtures/corpus.json`) covers emoji (skin-tone modifiers, flags, a keycap), ZWJ sequences, combining marks (including a change between canonically equivalent NFD and NFC text), CJK (including a supplementary-plane character), right-to-left Hebrew and Arabic with a directional mark, deleted content followed by insertion at the deletion point, and deletion-only updates ending in an empty document. Formatting joins in [#8's evidence below](#formatting-feature-integration-g2g3g6g12-8); lists, checklist states, record references, and the unknown-feature document join with their tickets.

Result: **pass** for text. Yjs 13.6.33 decodes every update a SwiftYrs 0.7.0 `DocumentSession` committed, and SwiftYrs decodes every update Yjs produced, to identical semantic snapshots after every step; replaying any update changes nothing. Command and layout: [`docs/development.md`](development.md#cross-language-fixtures).

- Steps that edit after surrogate-pair characters (emoji, `𠮷`) decode identically, so the engines agree on item lengths; no fixture needed a conversion beyond the session's existing `TextEdit`.
- `Y.decodeUpdate` confirms the deletion-only steps of both origins carry a delete set and no structs.
- A deliberate NFC/NFD mismatch in the expected snapshot fails in both languages; Swift compares snapshots by Unicode scalars because `String ==` treats canonically equivalent text as equal.

## Editing surface (#3)

#3 bound SwiftUI `TextEditor(text: Binding<String>)` to the document session; #5 replaced it with the TextKit fallback ([below](#remote-edits-on-the-editing-surface-g6-5)). Limitations found through `TextEditor`'s public API, none blocking plain-text typing:

- The binding receives each new value as a whole string, with no edited range. The session derives one grapheme-aligned replacement from the common prefix and suffix, scanning the text on every change. #6 removed this diff from the native input path: the `UITextView` adapter reads the actual UTF-16 storage edit, including system replacements.
- Inside a run of identical characters the whole-text diff cannot identify the edited position: typing `a` at the start of `aa` was recorded at the end. #6 verifies the native input path records the insertion at offset 0.
- `TextEditor` exposes no marked-text (composition) state. #6 exercises the adopted `UITextView` fallback through public `UITextInput` APIs.

## Remote edits on the editing surface (G6, #5)

Result: **fail** for SwiftUI `TextEditor`, so the editing surface now uses the fallback #1 specifies: a `UITextView` (TextKit 2) in a `UIViewRepresentable` inside the SwiftUI component. The session, store, and JavaScript API did not change. `RemoteEditTests` (example UI tests) types while a scripted remote replica edits through the delivery harness:

| Surface                                                                                                                | Caret through remote edits before, at, after, and spanning it | Visible text through remote edits above and below the viewport                 |
| ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `TextEditor(text: Binding<String>)`                                                                                    | fail: each remote change moves the caret to the end           | not run                                                                        |
| iOS 26 `TextEditor(text: Binding<AttributedString>, selection:)`, patched with `AttributedString.transform(updating:)` | pass                                                          | fail: the edit above and the edit below each shifted the visible lines         |
| `UITextView` (TextKit 2)                                                                                               | pass                                                          | pass: screenshots of the editor before and after each edit are pixel-identical |

Blocker: no public API reads or sets `TextEditor`'s scroll offset, so the surface cannot restore the visible text after a remote change.

How the surface applies a remote change:

- The session applies the update, then moves its selection through the change's text delta (UTF-16 offsets). A caret sticks to the character before it, so text inserted at the caret lands after it and the person's typing stays contiguous. A range keeps its own characters: text inserted at either edge stays outside it. A deletion spanning the caret leaves it at the deletion point. `SynchronizationTests` covers these cases with emoji, ZWJ sequences, and a cluster replaced before the caret.
- The surface patches `NSTextStorage` in place with the delta's edits, sets the session's selection, and, unless scrolled to the very top, restores the first visible character's position on screen. Without that restore (checked by disabling it), UIKit keeps the content offset numerically, so an edit above the viewport shifts the visible text.
- Composition is covered below (#6). Undo/redo use the same incremental patch path ([selective undo](#selective-undo-g7-7)).

## Composition and system replacements (G6, #6)

Result: **pass at the native input seam** on iOS 26.2 / iPhone 17 Pro simulator, Xcode 27.0. `EditingSurfaceTests` hosts the same SwiftUI representable as the example in a real window with a first-responder `UITextView`; it calls public `setMarkedText`, `unmarkText`, `insertText`, and `replace(_:withText:)`, not delegate methods or a simulated document model.

Observed blockers and implementation:

- The old adapter persisted each marked-text revision: composing `に`, then `日本`, produced two outbox operations before the input system committed. Marked input now remains only on the editing surface; "Saved on this phone" is withheld while it exists. Unmarking or accepting a candidate produces one exact-range incremental transaction. Cancelling an insertion queues nothing.
- A direct `NSTextStorage` remote patch clears `markedTextRange`, even without restoring `selectedRange`. During composition, the session still persists and applies incoming updates immediately, but the surface queues their deltas without touching the input system. At commit, it rebases the local replacement and selection through those deltas, then projects the queued patches around the composed text. Remote text becomes visible when composition ends. No marked-text reconstruction or IME restart is used.
- UIKit can notify delegates before updating its marked range; the adapter waits until each public input call returns. Actual storage character ranges capture typing, autocorrect, predictive replacements, and smart substitutions without ambiguous whole-text diffs. The document/session/store/JavaScript boundary is unchanged apart from the saved status accounting for marked input.
- The example's scripted replica now distinguishes uncommitted document operations from marked input, so an unsaved composition no longer prevents remote delivery.

Native coverage:

- Provisional Japanese text stays out of the document/outbox, then decodes as only an insertion at UTF-16 offset 5. A suspended storage queue proves no saved acknowledgement appears before the single commit completes.
- Remote insertions, deletions, and replacements before/after a selected marked range, plus insertions at both adjacent edges, preserve its marked text and selection. Candidate acceptance yields the exact expected text on both replicas, with one local operation.
- Multiple queued remote edits, including insertion at the same empty document position, preserve continued composition, the committed caret, and subsequent typing without duplication.
- Chinese marked text survives timer-driven `ScriptedReplica` delivery through the example's harness. Cancellation queues no operation.
- Autocorrect-style `teh` → `the`, predictive `ca` → `cannot `, repeated-character insertion at offset 0, and NFD → NFC replacement after a surrogate pair decode as exact incremental ranges.

Reproduce from `example/` after prebuild:

```sh
bun run test:ios:unit -only-testing:ExpoNativeCollaborativeEditor-Unit-Tests/EditingSurfaceTests
```

Final regression run:

| Command | Result |
| --- | --- |
| `bun run test:ios:unit` (example) | 21 passed, including 6 editing-surface tests |
| `bun run test:ios:ui` (example, Release) | 3 passed |
| `bun test ./fixtures` (root) | 14 passed |
| `bunx tsc --noEmit`, plus `-p example/tsconfig.json` and `-p fixtures/tsconfig.json` | passed |

Runtime smoke: launched the Release example directly with `simctl launch` on the probe's persisted document; the actual screen displayed `I typed teh` and "Saved on this phone".

Simulator limits: its configured keyboards were `en_US` and emoji, not Japanese or Chinese. An example UI probe typed `I typed teh `; iOS left `teh` unchanged, including after relaunch, so it did not exercise autocorrection. That environment-dependent probe was removed rather than retained as false proof. Native replacement tests cover the editing path, not keyboard dictionaries or candidate UI.

### Physical-device checklist for #18

Record each on both M1 iPhones; these remain **unverified**, not G14 passes:

- Japanese kana-to-kanji and Chinese Pinyin: revise marked text, navigate/change candidates, accept and cancel; repeat for insertion and selection replacement. Verify candidate UI and marked selection remain active during remote edits before, after, at both adjacent edges, and at the same insertion point; also queue several remote edits before committing.
- Confirm remote presentation catches up only after composition ends, final text matches the chosen candidate exactly on both replicas, and continued typing remains at the committed caret.
- Autocorrect, explicit predictive-candidate selection, inline prediction acceptance/rejection, and smart punctuation: verify the proposed text survives remote edits and relaunch without duplicate characters.
- Composition cancellation by Backspace/Escape, focus loss, and editing-surface unmount/remount: verify no provisional input is uploaded or falsely acknowledged.
- Dictation, including correction/replacement and remote edits during speech input.
- Hardware keyboard where available: composition/dead keys, candidate navigation, Return acceptance, Escape cancellation, and continued typing after remote delivery.

These results address #6's portion of G6 only. They do not establish the full native-input gate, device performance, access changes during composition, or persistence-failure recovery; the remaining M1 tickets and #18 own those checks.

## Selective undo (G7, #7)

Result: **pass for plain text** on iOS 26.2 / iPhone 17 simulator (`ExpoNativeNotesModule`, `ACB21CAA-329B-45B3-AE1C-B62FDC03F8BF`), Xcode 27.0.

- Each document session creates one `YUndoManager`, scoped to `body` (and, since #10, the block model's `blocks` and `order`), after replaying committed updates. Only transactions with the explicit `local` origin enter its history; incoming updates use `remote`. One committed input replacement is one undo step, without time-based grouping.
- Undo and redo take the engine's incremental update through the same SQLite/outbox/receipt path as typing. They publish text deltas to mounted surfaces and retain the viewport anchor. Remote edits and undo transform the current selection; redo collapses the caret after the last reapplied edit, or at the deletion gap when no text was inserted.
- The text view's `UndoManager` delegates availability and actions to the session. UIKit undo recording stays disabled, including after UIKit clears its native stack. Release UI tests exercise Command-Z, Shift-Command-Z, and the system three-finger double-tap undo gesture after a remote edit; none reverts remote content.
- Native undo first commits marked input, then undoes that committed action. Direct session commands reject marked input instead of dropping or replacing it.
- The registry strongly owns open sessions by account/document/lifecycle generation. Releasing the last JavaScript handle or editing surface does not close a session. The provisional JavaScript handle exposes `undo()`, `redo()`, `close()` (promises), plus `canUndo`/`canRedo` in its state and state-change events. Stable editor/hooks signatures remain #19.
- Explicit close clears history and invalidates the old session; opening again replays committed content and retains its pending synchronization without restoring history. Close rejects marked input, pending commits, or failed commits, leaving the session open. Waiting for commits and host error callbacks belong to #19/#13, not this provisional API.
- A remount regression caught an old, detached text view still receiving history deltas before SwiftUI dismantled it: undoing a character typed in the new view tried to delete beyond the old view's text. Native window detachment now cancels subscriptions immediately; reattachment binds from current session state. Clearing or dismantling a surface never clears engine history.

Evidence:

- Three replicas converge after a local replacement, remote prefix insertion, local undo, another remote insertion, and local redo. Every replica keeps both remote insertions; remote updates neither enter local history nor clear redo.
- Undoing and redoing one character in the 20,000-character fixture decodes to only that deletion/insertion; each update is under 100 bytes. Reopening keeps the exact committed text and pending operations.
- Native surface tests cover selective undo/redo and synchronization, remount plus continued typing, direct session commands, close disabling editing, and undo/redo of composition after a deferred remote edit.
- Redo cursor regressions cover insertion, replacement, and deletion after a remote emoji prefix, with the caret moved elsewhere before redo. Native and direct session redo both restore the UTF-16 caret at the redone edit, and subsequent typing preserves the remote content. Remount coverage no longer manually repairs the cursor before typing.
- Releasing the last native JavaScript handle preserves session identity and usable history. Explicit close refuses pending/marked input; stale repeated close cannot evict a newly opened session.
- Release UI tests exercise command buttons, remote-preserving undo/redo, remount with redo pending, immediate typing after redo (`Ra!`, not `R!a`), and process termination/relaunch: committed content remains, Undo and Redo are disabled.

Verification from `example/` used `xcodebuild test -quiet -workspace ios/exponativecollaborativeeditorexample.xcworkspace -scheme <scheme> -destination 'platform=iOS Simulator,id=ACB21CAA-329B-45B3-AE1C-B62FDC03F8BF' -parallel-testing-enabled NO`; the app scheme used `-configuration Release`.

| Check | Result |
| --- | --- |
| `ExpoNativeCollaborativeEditor-Unit-Tests` scheme | 30 passed |
| `exponativecollaborativeeditorexample` scheme, Release | 5 passed |
| `bun test ./fixtures` (root) | 14 passed |
| `bunx tsc --noEmit` for root, example, and fixtures | passed |
| `bun run build`, `bun run lint` | passed |

Runtime smoke: launched the Release app directly with `simctl launch` on the remount/redo typing test's persisted document. The actual surface showed `Ra!`, "Saved on this phone", and disabled Undo/Redo after the new process opened it.

Physical-device shake-to-undo and three-finger gestures remain unverified; simulator gesture/shortcut proof does not replace #18's device checks.

## Delivery and convergence (G3 text, #5)

- `DeliveryHarness` (`ios/Core`) is a test-only in-process server for one document's replicas: it accepts each replica's operations in commit order, appends them to every other replica's feed, and returns a receipt per operation. Every message is delayed (1–6 ticks, so messages reorder) and may be duplicated (20%) or dropped (20%, redelivered once nothing else is in flight). In the example app, `ScriptedReplica` drives it on a 50 ms timer. It is not a sync adapter.
- A receipt deletes the outbox rows it names in one transaction; IDs no longer pending are ignored. "Pending synchronization" holds while the document's outbox is non-empty, for local-only and synchronized documents alike: connecting a document that was edited local-only uploads its outbox with no migration.
- An incoming update is committed with its feed position (`deliveries` table) in one transaction before the session applies it. Positions persist contiguously: a position already stored is ignored, a later one waits in memory until the gap fills, and a restart resumes after the last stored position. The commit runs synchronously on the storage queue, blocking the main actor for one commit per remote update.
- Result: **pass for text under causal acceptance and contiguous feed application only**, not arbitrary engine application order. Seeds 1–20 each run three replicas through 80 random steps (insertions of emoji, ZWJ sequences, combining marks, CJK, Hebrew, and newlines; deletions of up to three grapheme clusters) interleaved with harness ticks. Every seed converges to identical semantic snapshots, redelivering every feed changes nothing, and every store reopens to the converged text with nothing pending. A seed reproduces its run only with fixed engine client IDs, because concurrent insertions at one position are ordered by client ID; `DocumentSessionRegistry.session(…, clientID:)` accepts one for tests.
- Engine finding: the SwiftYrs-bound Yrs revision loses part of an early deletion. With a harness that accepted operations in arrival order, randomized runs also panicked inside Yrs (`block_store.rs:315`, surfaced as `nativePanic`). The direct reproduction and accepted contract below resolve #20's ordering decision, not the remaining non-text G3 checks or the final #18 foundation gate.

### Out-of-order engine decision (G1/G3, #20)

**Decision:** the maintainer selected causal sync order for [#20](https://github.com/statusunknown418/expo-native-collaborative-editor/issues/20). Keep SwiftYrs 0.7.0 and require causal per-replica acceptance, dependency-complete bootstrap/checkpoints, and contiguous replay as specified in [ADR 0007](adr/0007-core-feature-plugins-and-sync-adapters.md#causal-synchronization). This deliberately narrows #1's unrestricted engine-ordering requirement. G1's raw out-of-order capability fails; G3's text evidence passes only inside that contract. No Automerge fallback or custom engine binary is adopted under this accepted restriction.

**Layer and versions:** SwiftYrs v0.7.0's [Cargo.lock](https://github.com/siuying/SwiftYrs/blob/ffdff22f632296b6ed7b1a15f8d8ddeec2d60713/native/yrs-bridge/Cargo.lock#L455-L458) binds Yrs 0.27.0 at git `ae61429251af410f82e85b8c6577cad585b3585a`, not the crates.io 0.27.0 release. The latest non-yanked registry release checked on 2026-10-15 is [Yrs 0.28.0](https://crates.io/crates/yrs/0.28.0), published 2026-09-17. SwiftYrs v0.8.0's [lockfile](https://github.com/siuying/SwiftYrs/blob/46169a5ba38396123c9dfefbf090f7df71154072/native/yrs-bridge/Cargo.lock#L455-L458) still binds the same broken revision; a SwiftYrs-only version bump is not an engine fix.

**Direct Rust proof:** [`internal/yrs-out-of-order`](../internal/yrs-out-of-order) pins both engines and runs the same public Rust APIs, without SwiftYrs. Fixed distinct client IDs, UTF-16 offsets, one transaction per update: insert `abc` at 0; insert `def` at 3; remove 3 characters at 1. Each transaction emits only its own v1 update. The source reads `aef`; a fresh receiver applies all three unique updates before replaying them.

| Arrival order | SwiftYrs-bound Yrs `ae614292` | Yrs 0.28.0 |
| --- | --- | --- |
| 1,2,3 | `aef` | `aef` |
| 1,3,2 | `adef` | `aef` |
| 2,1,3 | `aef` | `aef` |
| 2,3,1 | `adef` | `aef` |
| 3,1,2 | `adef` | `aef` |
| 3,2,1 | `adef` | `aef` |

Replaying all three updates repairs each old-engine failure; measuring only after replay would conceal lost deletion tails on first delivery. Yrs 0.28.0 passes initial delivery and replay in every order. This establishes a Yrs defect rather than a Swift bridge defect. It does **not** establish that 0.28.0 fixes the separate randomized `BlockStore::push` panic.

Run from the repository root with Rust/Cargo installed (verified with 1.99.0 on macOS arm64):

```sh
cargo run --manifest-path internal/yrs-out-of-order/Cargo.toml
```

The diagnostic prints every version/order/delivery/replay result and intentionally exits **1** while the historical revision fails; it is not a passing-suite check. Cargo's generated lockfile and build output stay ignored inside that directory; the app's build still requires no Rust toolchain.

**Upstream:** [y-crdt/y-crdt#719](https://github.com/y-crdt/y-crdt/issues/719) contains the runnable minimal reproduction, exact pins, and observed results, explicitly noting that latest Yrs passes.

**Native contract proof:** `SynchronizationTests.testCausalFeedPreservesAnEarlyDeletionInEveryDeliveryOrder` passes all six transport arrival orders through the actual document session with causal feed positions, checking each contiguous prefix, duplicates, restart, and replay. All seven synchronization tests passed on iOS 26.2 / iPhone 17 Pro Max. The test-only harness still proves neither a production adapter nor durable server acceptance. #18 must carry this accepted ordering limitation into its engine decision.

## Local store (#3)

- Library: the system SQLite (`import SQLite3`), no package. One database at `Application Support/ExpoNativeCollaborativeEditor/documents.sqlite`, opened with WAL, `synchronous = FULL`, and `fullfsync = ON`.
- `documents` holds the account namespace, document ID, lifecycle generation, and schema/encoding identifier (`yrs-update-v1/plain-text-0`, replaced by `yrs-update-v1/blocks-1` in #10) as separate columns. Creating a document writes only this row; ordinary reopening writes no content or outbox operations. #8 moves the unused manifest seed column into the synchronized CRDT `features` map, with a one-time schema upgrade for empty legacy values.
- Each local edit produces one Yrs v1 update, the update its write transaction emits. It is committed with its outbox operation (a random UUID; a trigger rejects updates to outbox rows) in one `BEGIN IMMEDIATE` transaction on the store's serial queue. "Saved on this phone" is published on the main actor after `COMMIT` returns.
- Remote updates join `updates` with their delivery position in `deliveries`, never the outbox; reopening replays local and remote updates in commit order.
- A failed commit is only logged and withholds "Saved on this phone" for the rest of the session, even after later commits succeed. Retaining the input, rejecting further edits, the host error callback, and retry are #13.
- Engine access and published state stay on the main actor; commits run on the storage queue; the editing surface updates on the main thread.
- Content is not yet encrypted (#12) and is never compacted: reopening replays every stored update, one per edit.

## Formatting feature integration (G2/G3/G6/G12, #8)

Formatting-scope checks pass on iOS 26.2 / iPhone 17 simulator `ACB21CAA-329B-45B3-AE1C-B62FDC03F8BF`, named `ExpoNativeNotesModule`, with Xcode 27.0. No additional simulators or test clones were created. Lists/checklists and record-reference plugin gates remain with their own tickets.

- Explicit JavaScript `formattingPlugin` registration carries normalized typed options. Native capability/version, unique-ID/capability, and option validation reject unsupported or malformed configurations before changing a session. The Expo boundary classifies these as `ERR_EDITOR_CONFIGURATION`.
- `FormattingTests` exercises enabled/disabled commands, rejected configuration without content/outbox changes, mixed selection state, Unicode scalar boundaries, heading paragraph expansion, typing attributes without speculative document writes, and undo/redo across option changes. Reopening retains marks and the monotonic CRDT feature manifest; undo history still resets.
- Applying bold to UTF-16 range 10,000–10,003 in a 20,000-character document decodes to retain 10,000 followed by retain 3 with `bold: true`, with no inserted or deleted text; the incremental update is under 200 bytes, including the first semantic feature declaration.
- Twenty recorded seeds (1–20) run three replicas through concurrent text, bold, italic, and heading changes with delayed, duplicated, reordered, and dropped-then-redelivered transport. One replica has formatting authoring disabled. Semantic snapshots converge, replay is idempotent, stores reopen to the same snapshot, and receipts drain pending work. The accepted causal-feed restriction in ADR 0007 still applies.
- A deterministic concurrent format/delete regression first failed: the deleting replica's semantic snapshot missed a manifest-only update because the old publication path returned on an empty body delta. Snapshots now refresh for manifest changes even when no surface patch is needed.
- `EditingSurfaceTests` drives actual native input and checks rendered bold/italic/heading fonts, supported rendering after plugin disable/remount, undo, selection preservation through a remote mark-only change, and committed typing marks after remote formatting during marked-text composition.
- The example's Release UI suite types bold/italic/heading text, changes selected marks, disables and re-enables authoring, undoes/redoes across configuration and remount, and relaunches to persisted formatting. Selected button styles and accessibility values track session state. Its retained screenshot shows `Rich text` as a bold heading with Bold/Heading selected and Italic off.
- The corpus adds a ten-step `marks` scenario: overlap, headings, Unicode insertion, mark removal, and deletion with retained feature requirements. SwiftYrs 0.7.0 and Yjs 13.6.33 decode both origins after every step and duplicate replay; all 16 JavaScript corpus cases pass.
- A regression caught heading changes restoring inline typing marks that had been explicitly switched off. Heading commands now retain independently chosen collapsed-caret bold/italic state.
- The legacy empty SQLite manifest field upgrades without losing text or pending operations. Nonempty legacy requirements reject the upgrade and remain stored rather than being discarded.

Reproduction: run the explicit-UDID native and Release UI commands in [`development.md`](development.md#native-tests), plus `bun test fixtures` from the repository root. API, semantic encoding, option behavior, and manifest upgrade are documented in [Formatting feature plugin](development.md#formatting-feature-plugin-provisional-8). No encryption, production-sync, or physical-iPhone performance result is implied by this ticket.

Final verification on 2026-10-15: 41/41 native tests, 6/6 Release UI tests, 16/16 JavaScript fixture cases; module build, module lint, example typecheck, and fixture typecheck pass. A throwaway Bun assertion also verifies option normalization without modifying the host's heading-level array.

Manual smoke after the final suites: launched the installed Release app directly with `simctl launch --terminate-running-process` on the same UDID, reopening the formatting document created by the UI scenario. The captured native surface restores the bold heading, shows matching Bold/Heading selection with Italic off and “Saved on this phone,” and has empty undo/redo history after process restart.

## Nested lists and checklists (G2/G6/G12, #9)

Candidate 1 is implemented in the existing native document session: ordered lists, unordered lists, and checklists share a preorder hierarchy and can nest within one another. Item IDs, kinds, depths, and checklist states live only on real LF separators in `YText body`; parents are derived in semantic snapshots. #10's concurrent proof failed this representation and replaced it with the explicit block model ([below](#concurrent-nested-lists-and-the-document-representation-g3g4-10)).

### Public TextEditor checkbox blocker

API inspection of iOS 26's public [`TextEditor(text:selection:)`](https://developer.apple.com/documentation/swiftui/texteditor/init(text:selection:)-11r0a) and [`AttributedTextFormattingDefinition`](https://developer.apple.com/documentation/swiftui/attributedtextformattingdefinition) finds attributed-text/selection bindings and formatting constraints, not an API for inserting an interactive checkbox view at a paragraph, reading its glyph rectangle for hit testing, or exposing a separate per-item accessibility action. The attributed editor also does not automatically translate UIKit formatting attributes. A checkbox glyph or a whole-editor accessibility action does not meet the per-item control contract.

The TextKit 2 fallback already adopted for #5/#6 is therefore retained and extended, not replaced by a custom engine. A non-accessible container hosts the editable `UITextView` and a sibling marker overlay. Checkbox `UIButton`s have 44-by-44-point hit targets, item-text labels (or “Empty checklist item”), Checked/Unchecked values, button/selected traits, and an explicit `Toggle` [`UIAccessibilityCustomAction`](https://developer.apple.com/documentation/uikit/uiaccessibilitycustomaction) for VoiceOver's Actions rotor. Keeping controls outside the text view's accessibility subtree prevents its editable-text representation from hiding them.

### Native and interoperability proof

- The built-in `listsPlugin` uses the existing feature-plugin registration/capability interface. Native validation rejects duplicate, unsupported, and malformed registrations before changing the session. Runtime plugin changes preserve content and undo history. Disabling creation does not discard stored lists or prevent toggling existing checklist items.
- Core checks cover all 27 three-level combinations, stable identities, every ADR 0005 Return/Backspace/indent/outdent rule, moving attributed subtrees past remaining sibling branches, parent-only removal with promotion, and selected subtree deletion. Splitting retains the left identity, state, and children; the right sibling follows the left subtree and starts unchecked. Joining preserves left state and both child groups in order.
- Native surface checks drive public `UITextInput` Return, Backspace, and selected replacement/deletion, then inspect the resulting document and rendered controls. They exercise checkbox touch and accessibility-action handlers, independent parent/child states, disabled authoring, marked-text composition, remote checkbox changes, scrolling, resize, and Dynamic Type.
- Screenshot inspection caught markers sitting roughly 11 points above their text because caret rectangles include minimum-line-height leading. Markers now align to the cached TextKit 2 glyph baseline and font cap height. The native geometry regression checks alignment against independently enumerated text segments; the retained Release screenshot shows checkbox, bullet, and number markers aligned with their item text.
- An input regression initially expanded a one-character composition edit to include the unchanged paragraph suffix. The trace showed `willProcessEditing` range `{5, 1}` becoming `{5, 6}` in `didProcessEditing` after paragraph attribute fixing. Capturing the former restores exact incremental edits, composition rebasing, provisional formatting, and redo caret placement; the existing input regressions pass without changing their expected behavior.
- A Release UI regression exposed the example's `testID` on a wrapper instead of the editable text. The surface now registers its own Expo SwiftUI props directly and assigns the existing `testID` to the `UITextView`; no extra public prop or identifier alias is needed.
- The Release list scenario creates checklist → unordered → ordered → checklist, taps parent and child independently, disables formatting without unregistering lists, outdents/indents, remounts, and relaunches to the same saved structure and checked states. Its retained screenshot shows the four levels, unchecked Parent, checked Task, and “Saved on this phone.”
- The twelve-step `nested-lists` corpus records actual native session commands and Yjs transactions with fixed IDs. Both engines decode both origins after every step and duplicate replay. JavaScript passes all 18 corpus cases. A native boundary regression also verifies oversized integral floating-point depths clamp to available ancestry, matching Yjs rather than silently omitting an item.

Reproduction: the explicit-UDID native and Release UI commands in [`development.md`](development.md#native-tests), plus `bun test fixtures`. Public API, representation, semantic snapshot fields, and disabled-authoring/cascade behavior are documented in [Lists/checklists feature plugin](development.md#listschecklists-feature-plugin-provisional-9).

This local-list ticket did not prove concurrent subtree-edit semantics or imply physical-iPhone performance or a physical-device VoiceOver run; #10 covers the concurrency gate, #18 the device gates.

Final verification on 2026-10-15: 74/74 native tests, 7/7 Release UI tests, and 18/18 JavaScript fixture cases pass. Module build, module lint, example typecheck, and fixture typecheck pass. Every native run used only iOS 26.2 simulator `ACB21CAA-329B-45B3-AE1C-B62FDC03F8BF`, with parallel testing disabled; no additional devices or test clones were created.

Manual smoke after the final suites: launched the installed Release app directly with `simctl launch --terminate-running-process`, reopening the saved four-level list document from the UI scenario. The captured native surface restores Parent → Group → Step → Task, aligned checkbox/bullet/number markers, unchecked Parent, checked Task, “Saved on this phone,” and empty undo/redo history after process restart. This cold-open smoke is visual; the native and Release UI scenarios provide the touch/accessibility-action checks above.

## Concurrent nested lists and the document representation (G3/G4, #10)

Result: **Candidate 1 fails G4; the explicit block model passes** and is the selected representation ([ADR 0008](adr/0008-explicit-block-document-model.md), which records every converged result). Simulator `ACB21CAA-329B-45B3-AE1C-B62FDC03F8BF` only, iOS 26.2, Xcode 27.0, parallel testing disabled.

- `ConcurrentListTests` runs the seven G4 scenarios through the session seam: two replicas with fixed client IDs share a mixed three-level list, edit concurrently, and converge through the unreliable harness; a full redelivery and both reopened stores agree. On Candidate 1 (3e53c42) four failed: a child added beneath a concurrently removed parent became its sibling's child, a child added within a concurrently moved subtree stayed at the old location, concurrent indents nested at the wrong parent, and text typed into an item outdented by Return landed in the next item. All seven pass on the block model.
- G3: 20 recorded seeds, three replicas, 150 random steps each from a shared three-level list, covering Unicode and LF text, bold/italic/heading, list conversion, indent/outdent, Return, Backspace, removal with and without children, and checklist toggles, with delayed, duplicated, reordered, and dropped-then-redelivered delivery. Every seed converges with unique identities, a valid tree, and checked state only on checklist items; redelivery and reopening change nothing and leave nothing pending.
- Normalization: a document with a duplicate label, a cycle, a parent that never existed, a reused identity, an unknown kind, non-boolean checked values, and `order` entries that disagree with the text projects to one hand-derived snapshot whether it arrives as one update or two, and after reopening; opening it queues no operation. The same document is the `malformed-blocks` fixture, which Yrs and Yjs decode identically in both directions; `nested-lists` was re-recorded in both engines.
- Editing surface: the example's scripted scenario (`-nestedListScenario 1`, `RemoteEditTests`, Release) holds a remote removal of `Child` while Return and `Deep` are typed after `Grandchild`; both replicas show `Parent > Grandchild, Deep` with `Parent` checked. Its first run crashed: the surface styled every list item through its terminating LF, which the last paragraph lacks without Candidate 1's materialized LF (`NSRangeException`). `ListEditingSurfaceTests` now covers a final item without a trailing LF arriving remotely.
- Behaviour changes from Candidate 1, all within ADR 0005: deleting the LF between two items keeps the left item's identity, as Backspace does, where Candidate 1 kept the right one's; lines pasted into an item split it like Return; converting the last paragraph adds no LF. Only the tests that pinned Candidate 1 storage or those outcomes changed: four `ListTests`, the Release list scenario's expected text (no trailing LF), and the schema identifier assertion. Stores written under Candidate 1 are not migrated; backward compatibility is out of scope.

Final verification on 2026-10-15: 83/83 native tests, 8/8 Release UI tests, and 20/20 JavaScript fixture cases pass. Module build, module lint, and root, example, and fixture typechecks pass. The Release UI runs drive the actual example app on the simulator, including the scripted concurrent scenario end to end.

## Unordered markers and native caret geometry (#21)

The 44-point list `minimumLineHeight` also enlarged TextKit's insertion caret: triage measured 47.67 points versus 23.67 for ordinary text. Lists now reserve checkbox space with paragraph spacing, leaving native text-line/caret metrics intact. Unordered markers render ASCII `-` in the overlay only; stored text, structure, and offsets do not change. Vertical text-container padding keeps the first and last 44-by-44-point marker targets inside the surface. Empty final items use native typing paragraph attributes for indentation and caret geometry for marker placement, without adding a hidden character.

`ListEditingSurfaceTests` passes 14/14, including three new regressions: both `Added` end carets match ordinary native text (23.67 points); markers align to independently enumerated first-line text segments through wrapping, nesting, scrolling, resizing, and accessibility Dynamic Type; empty final items of every kind keep indentation, visible markers, typing, and undo. Existing numbering, checkbox touch/accessibility actions, and 44-by-44-point targets pass unchanged. Remounting preserves semantic snapshot, selection, history availability, and emits no surface edits.

Visual smoke drove the actual Release example: type `Added\nAdded`, select both paragraphs, convert to unordered, then place the caret at the end of each item. Both inspected screenshots show ASCII hyphens beside their text and a font-sized caret confined to the active item. Captured in `/tmp/issue21-example-visual.xcresult`; exported screenshots in `/tmp/issue21-example-visual/`. The throwaway UI probe was removed after capture. All native/UI commands used only existing iOS 26.2 simulator `ACB21CAA-329B-45B3-AE1C-B62FDC03F8BF`, with parallel testing disabled and one destination.

Final verification: 86/86 native tests, 8/8 Release UI tests, and 20/20 JavaScript fixture cases pass. Module build, lint, and root/example/fixture typechecks pass. Standards and spec reviews found no actionable defects. Result bundles: `/tmp/issue21-native-full.xcresult` and `/tmp/issue21-ui-full.xcresult`.

## Checklist cascades (G5, #11)

The cascade option and basic two-item implementation already existed from #9. #11 adds the missing mixed-list, persistence, concurrency, and real-example proof. A performance probe exposed an avoidable full paragraph lookup per descendant. `toggleChecklistItem` now walks the projected preorder directly, stops at the subtree boundary, and allocates no target arrays. The default-off branch does not visit descendants for cascade work. Transactions, update encoding, schema, and the JavaScript plugin API are unchanged.

### Behavior and native surface

- `ListPluginTests` checks independent default/disabled-plugin toggles and a cascade beneath an unchecked checklist ancestor, through ordered and unordered groups to depth 3. Checking and unchecking affect only the selected subtree; a prechecked descendant, sibling, and outside item keep the expected states. Enabling the option writes nothing. Checklist creation can be disabled while existing items still cascade.
- A suspended storage queue keeps the cascade's saved-state publication at `[true, false]`; resuming produces `[true, false, true]` and exactly one additional outbox operation. Reopening with the option enabled restores the committed snapshot and identical pending operations without cascading again. One undo restores every prior checked state; redo and earlier undo history survive option changes.
- `ConcurrentListTests.testChecklistCascadeConvergesWithoutCapturingConcurrentChildrenOrUndoingRemoteEdits` uses three fixed-client-ID replicas, mixed option values, and unreliable harness seed 11. A cascade races with an inserted child, a subtree outdent, and a text edit. The enabled receiver already knows the new child when the cascade arrives, but does not check it. All replicas agree on the literal expected hierarchy; a single selective undo/redo preserves the remote child, text, and placement. Redelivery is idempotent; all three reopened stores agree and have no pending synchronization after receipts. The accepted causal-feed contract in ADR 0007 still applies.
- The actual Release example's `ProofScreenTests.testMixedNestedListsNativeCheckboxCascadesRuntimeOptionsAndPersistence` exercises native checkbox taps through the host's runtime `Checklist cascade` control. It verifies default independence, no action on enablement, check/uncheck cascades, one-step undo/redo after option changes, preservation of formatting configuration, later-child independence, remount, and process relaunch. The inspected screenshot shows checked `Parent` and `Task`, unchecked `Later` beneath ordered/unordered groups, cascade On, and formatting disabled, with the native keyboard/caret still active.

Targeted native run: four behavior tests and the temporary timing probe passed in `/tmp/issue11-cascade-targeted.xcresult`. Release surface smoke: 1/1 passed in `/tmp/issue11-ui-smoke.xcresult`; retained screenshot exported to `/tmp/issue11-ui-smoke-images/`. Commands used the existing iOS 26.2 / iPhone 17 simulator `ACB21CAA-329B-45B3-AE1C-B62FDC03F8BF` (`ExpoNativeNotesModule`), Xcode 27.0, with parallel testing disabled and one destination. Reproduce behavior with the documented native unit suite and the Release UI selector above.

### Large-subtree simulator timings

Debug unit-test configuration, macOS arm64, same pinned simulator; no editing surface mounted. Each document contains a root checklist and 100, 1,000, or 5,000 direct checklist descendants, each with text `Task`. Setup creates the text/list items and assigns their parent before timing. Each option value gets one discarded warm-up toggle, then five alternating check/uncheck samples, waiting for durable saved state after each action. Timers use `ProcessInfo.processInfo.systemUptime`; saved latency includes main-run-loop delivery, not just SQLite commit time. Values below are medians in milliseconds.

| Descendants | Cascade | Before: command return | After: command return | After: saved acknowledgement |
| --- | --- | --- | --- | --- |
| 100 | Off | 3.27 | 3.80 | 5.42 |
| 100 | On | 5.42 | 5.35 | 6.75 |
| 1,000 | Off | 30.21 | 25.10 | 25.79 |
| 1,000 | On | 282.25 | 107.46 | 108.28 |
| 5,000 | Off | 780.06 | 142.66 | 142.72 |
| 5,000 | On | 11,341.90 | 2,060.07 | 2,060.14 |

The original 5,000-descendant enabled samples ranged from 6,064.33 to 18,835.50 ms; the direct-scan samples ranged from 2,042.02 to 2,075.42 ms. The runs are noisy workstation observations, not a controlled speedup claim; even the Off path varied substantially between runs. Only the descendant-selection loop is now linear in the subtree; the complete command still includes engine writes, undo capture, whole-document projection, and selection publication on the main actor. The 5,000-descendant result still stalls that actor for about two seconds in Debug. This is not a Release/device latency pass or an accepted size limit. Device measurements and foundation acceptance remain #18.

The temporary `testCascadeTimingProbe` was removed after capture. Result bundles: `/tmp/issue11-timing-before.xcresult` and `/tmp/issue11-cascade-targeted.xcresult`. Exported diagnostics (`StandardOutputAndStandardError.txt`, `CASCADE_TIMING` JSON records) are in `/tmp/issue11-timing-before-logs/` and `/tmp/issue11-timing-after-logs/`.

### Final verification

Full native suite: **97/97 passed** (`/tmp/issue11-native-full.xcresult`). Full Release example UI suite: **9/9 passed** (`/tmp/issue11-ui-full.xcresult`). Bun/Yjs fixtures: **20/20 passed**. Module build, lint, and root/example/fixture typechecks passed. After strengthening the reopen assertion to compare against operations captured before opening, the affected durability test passed again (`/tmp/issue11-reopen-invariant.xcresult`).

Independent standards and spec reviews found no actionable defects. The standards reviewer noted only that the pre-existing `formattingValue` helper now also supplies the cascade control's On/Off accessibility value; it is reused unchanged. No simulator or test clone was created. Physical-device performance, access-state extensions (#14), and the final M1 foundation acceptance remain outside this ticket.
