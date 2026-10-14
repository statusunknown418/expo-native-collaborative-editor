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

`EditingSurfaceView` binds SwiftUI `TextEditor(text: Binding<String>)` to the document session. Limitations found through its public API, none blocking plain-text typing:

- The binding receives each new value as a whole string, with no edited range. The session derives one grapheme-aligned replacement from the common prefix and suffix, which scans the text on every change.
- Inside a run of identical characters the edited position is ambiguous: typing `a` at the start of `aa` is recorded as an insertion at the end. The text is the same, but the engine records a different position, which matters for concurrent edits and caret positions (#5). The iOS 26 `TextEditor(text:selection:)` initializer with `AttributedString` exposes the selection that would disambiguate it.
- `TextEditor` exposes no marked-text (composition) state. Composition was not exercised here; #6 covers it.

## Local store (#3)

- Library: the system SQLite (`import SQLite3`), no package. One database at `Application Support/ExpoNativeCollaborativeEditor/documents.sqlite`, opened with WAL, `synchronous = FULL`, and `fullfsync = ON`.
- `documents` holds the account namespace, document ID, lifecycle generation, schema/encoding identifier (`yrs-update-v1/plain-text-0`), and feature manifest as separate columns. Creating a document writes only this row; reopening writes nothing.
- Each local edit produces one Yrs v1 update, the update its write transaction emits. It is committed with its outbox operation (a random UUID; a trigger rejects updates to outbox rows) in one `BEGIN IMMEDIATE` transaction on the store's serial queue. "Saved on this phone" is published on the main actor after `COMMIT` returns.
- A failed commit is only logged and withholds "Saved on this phone" for the rest of the session, even after later commits succeed. Retaining the input, rejecting further edits, the host error callback, and retry are #13.
- Engine access and published state stay on the main actor; commits run on the storage queue; the editing surface updates on the main thread.
- Content is not yet encrypted (#12) and is never compacted: reopening replays every stored update, one per edit.
