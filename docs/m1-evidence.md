# M1 evidence log

Findings from M1 tickets, recorded as input to the foundation decision (#18). Nothing here is a decision yet.

## Engine packaging (G1, #3)

Candidate: Yrs through [SwiftYrs](https://github.com/siuying/SwiftYrs) 0.7.0 (a C-ABI shim over Yrs 0.27, released 2026-09-11), integrated with React Native's `spm_dependency` in `ios/ExpoNativeCollaborativeEditor.podspec`. SwiftYrs was evaluated before YSwift because it binds current Yrs and already exposes the capabilities #1 requires (rich-text attributes, sticky indexes, origin-filtered undo, state vectors, snapshots). YSwift's latest release is 0.2.1 from 2024-04-04; it was not built.

Result: **pass** for packaging. The candidate builds and links through Expo autolinking with no host steps:

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

Scope: text. The corpus (`fixtures/corpus.json`) covers emoji (skin-tone modifiers, flags, a keycap), ZWJ sequences, combining marks (including a change between canonically equivalent NFD and NFC text), CJK (including a supplementary-plane character), right-to-left Hebrew and Arabic with a directional mark, deleted content followed by insertion at the deletion point, and deletion-only updates ending in an empty document. Marks, lists, checklist states, record references, and the unknown-feature document join the corpus with their tickets.

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

- Each document session creates one `YUndoManager`, scoped to `body`, after replaying committed updates. Only transactions with the explicit `local` origin enter its history; incoming updates use `remote`. One committed input replacement is one undo step, without time-based grouping.
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
- Result: **pass** for text. Seeds 1–20 each run three replicas through 80 random steps (insertions of emoji, ZWJ sequences, combining marks, CJK, Hebrew, and newlines; deletions of up to three grapheme clusters) interleaved with harness ticks. Every seed converges to identical semantic snapshots, redelivering every feed changes nothing, and every store reopens to the converged text with nothing pending. A seed reproduces its run only with fixed engine client IDs, because concurrent insertions at one position are ordered by client ID; `DocumentSessionRegistry.session(…, clientID:)` accepts one for tests.
- Engine finding: Yrs 0.27 (SwiftYrs 0.7.0) loses deletions that arrive before the insertions they delete are integrated. Three updates from one client (insert `abc`; insert `def` after it; delete three characters at offset 1) yield `aef` applied in order 1,2,3 or 2,1,3, but `adef` in orders 3,2,1, 3,1,2, and 2,3,1. Yjs 13.6.33 yields `aef` in all four. With a harness that accepted operations in arrival order, randomized runs also panicked inside Yrs (`block_store.rs:315`, surfaced as `nativePanic`). Out-of-order application is an engine capability #1 requires; #20 tracks the decision, as input to #18. Until then, no replica applies an update before its dependencies: the server accepts each replica's operations in commit order, so every feed is causally ordered, and replicas apply their feed in position order.

## Local store (#3)

- Library: the system SQLite (`import SQLite3`), no package. One database at `Application Support/ExpoNativeCollaborativeEditor/documents.sqlite`, opened with WAL, `synchronous = FULL`, and `fullfsync = ON`.
- `documents` holds the account namespace, document ID, lifecycle generation, schema/encoding identifier (`yrs-update-v1/plain-text-0`), and feature manifest as separate columns. Creating a document writes only this row; reopening writes nothing.
- Each local edit produces one Yrs v1 update, the update its write transaction emits. It is committed with its outbox operation (a random UUID; a trigger rejects updates to outbox rows) in one `BEGIN IMMEDIATE` transaction on the store's serial queue. "Saved on this phone" is published on the main actor after `COMMIT` returns.
- Remote updates join `updates` with their delivery position in `deliveries`, never the outbox; reopening replays local and remote updates in commit order.
- A failed commit is only logged and withholds "Saved on this phone" for the rest of the session, even after later commits succeed. Retaining the input, rejecting further edits, the host error callback, and retry are #13.
- Engine access and published state stay on the main actor; commits run on the storage queue; the editing surface updates on the main thread.
- Content is not yet encrypted (#12) and is never compacted: reopening replays every stored update, one per edit.
