# Development

The repository is one Expo module (`/`) and its example app (`/example`). iOS 26 is the only target; there is no Android, web, or tvOS code or configuration.

## Toolchain pins

Expo 57.0.28 was npm's `latest` tag on 2026-10-13. Every other package below is the version that SDK bundles (`expo/bundledNativeModules.json`, `expo-template-blank-typescript@57`). The module's `devDependencies` and `peerDependencies` and the example's `dependencies` use the same versions.

| Package                      | Version  |
| ---------------------------- | -------- |
| `expo`                       | ~57.0.28 |
| `react-native`               | 0.86.3   |
| `react`                      | 19.2.3   |
| `@expo/ui`                   | ~57.0.23 |
| `@types/react`               | ~19.2.2  |
| `typescript`                 | ~6.0.3   |
| `babel-preset-expo` (module) | ~57.0.15 |
| `jest-expo` (module)         | ~57.0.6  |

iOS deployment target: 26.0, set in `ios/ExpoNativeCollaborativeEditor.podspec` and `example/app.json` (`ios.deploymentTarget`).

Native dependencies outside the Expo SDK:

| Dependency                                                 | Version             | Integration                                                                                                                                                                                               |
| ---------------------------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [SwiftYrs](https://github.com/siuying/SwiftYrs) (Yrs 0.27) | 0.7.0 (exact)       | Swift package declared in the podspec with React Native's `spm_dependency`; `pod install` adds it to the Pods project and Xcode downloads it and its prebuilt `YrsBridge.xcframework` on the first build. |
| SQLite                                                     | system `libsqlite3` | `import SQLite3`; no package.                                                                                                                                                                             |

Engine evaluation, packaging cost, and editing-surface findings: [`docs/m1-evidence.md`](m1-evidence.md).

Toolchain used to verify the baseline:

| Tool              | Version                         |
| ----------------- | ------------------------------- |
| Xcode             | 27.0 (27A266a)                  |
| Simulator runtime | iOS 26.2 (23C54), iPhone 17 Pro |
| Bun               | 1.4.2                           |
| Node.js           | 24.15.0                         |
| CocoaPods         | 1.17.0                          |

Bun is the only package manager. Commit `bun.lock` changes; do not add other lockfiles.

### Swift 6.4 framework compatibility

The example's Bun patch for `expo-modules-jsi@57.1.2` fixes its framework sanitizer: Swift 6.4 emits `__ObjC::` instead of `__ObjC.`, so the old filter left private C++ conformances in the public Swift interface and imports failed with `cannot find type '__ObjC::expo' in scope`. The patch handles both spellings; `bun install` in `example/` applies it and the framework's source hash triggers a rebuild. Remove the patch when an upstream fix passes the native build.

Regression check from `example/`: `bun run test:ios:unit -only-testing:ExpoNativeCollaborativeEditor-Unit-Tests/BaselineTests`. This compiles the real Expo/editor import chain.

## From a clean clone

```sh
bun install                 # module deps; `prepare` builds src/ into build/ and installs Git hooks
cd example
bun install
bun run prebuild            # expo prebuild --platform ios (generates example/ios, runs pod install)
bun run ios                 # builds Debug, boots the simulator, starts Metro, launches the app
```

The example opens the proof screen: a local-only document (`example-account` / `proof-document`) in the module's `EditingSurface`, with "Saved on this phone" shown once every edit is committed and a button that unmounts and remounts the surface. Launching with `-documentId <id>` opens another document; the UI tests use this for a fresh document per run. Launching with `-remoteEdits <percent-encoded JSON>`, an array of `{ "offset", "deleteCount", "text" }` in UTF-16 code units, connects a test-only scripted remote replica through the in-process delivery harness, shows "Pending synchronization" until receipts acknowledge every committed edit, and adds a "Remote edit" button that makes the next edit; `RemoteEditTests` uses it. Launching with `-nestedListScenario 1` connects the replica for the scripted concurrent nested-list scenario: "Nested-list scenario" makes the replica write `Parent` (checklist) > `Child` (unordered) > `Grandchild` (ordered) and deliver it, then remove only `Child` and check `Parent` while holding delivery; edits typed meanwhile are concurrent with the removal. "Deliver remote edits" releases delivery, and "Nested lists converged" appears once both replicas show the same document.

`example/ios` is generated and git-ignored. After changing `example/app.json`, `example/plugins/`, the podspec, or native dependencies, regenerate it from `example/` with `bunx expo prebuild --platform ios --clean`. Run at the repository root, the same command deletes the module's `ios/` sources.

From the repository root, run `bun run dev` to watch/rebuild the module's TypeScript and build, install, and launch the example's Debug app with Metro. Bun runs both processes together; Ctrl+C stops them.

Fast Refresh picks up changes to `example/App.tsx` and the module's `src/` (compiled into `build/`, its package entry). Swift changes cannot Fast Refresh: stop and rerun `bun run dev` to rebuild the native app. This uses the custom example app, not Expo Go, which does not contain this module.

## Lint and format

Biome runs Ultracite 8.0.1's core and React presets for supported files across the module, example, fixtures, and scripts. The lint and format scripts invoke Biome directly; lint-staged invokes the installed Ultracite CLI. Formatting keeps two-space indentation, 100-column lines, single JavaScript quotes, and ES5 trailing commas. Git-ignored build output, dependencies, and generated native projects are excluded; unsupported files such as Swift and Markdown are skipped.

`biome.json` keeps the repository's camelCase/PascalCase filenames, `type` definitions, and method-style event contracts. Narrow overrides allow CommonJS `__dirname` in tooling, the public `src/index.ts` package entry, and the example's module import supplied by its Metro alias rather than an installed dependency.

Run from the repository root:

```sh
bun run lint                # lint without modifying files
bun run format              # format supported files
bun run lint-staged         # manually run the staged-file checks
bunx ultracite doctor        # verify presets and Biome compatibility
```

`bun install` installs the Husky pre-commit hook without replacing the module's existing build step. Each commit runs lint-staged, which applies `ultracite fix` only to staged files and stages formatting and safe fixes. Remaining errors block the commit; unsafe fixes are never applied. Unstaged hunks stay unstaged. Full builds and tests are not added to the hook.

### Agent auto-fix hooks

Repository-local hooks run Ultracite after file edits:

- Claude Code: `.claude/settings.json`, after `Write` or `Edit`.
- Codex: `.codex/hooks.json`, after `apply_patch`, including multi-file patches.
- Cursor: `.cursor/hooks.json`, after `afterFileEdit`.

The hooks use `bunx ultracite fix --skip=correctness/noUnusedImports --hook`. Ultracite reads the edited paths from the hook's stdin payload and applies safe fixes only to those files. Unused imports stay intact while an agent builds a change across multiple edits; the commit-time command still removes unused imports. Remaining lint errors are reported back to the agent.

Run `bun install` before starting agents, and start terminal agents from the repository root. Start a new session to pick up the hook configuration. Codex additionally requires a trusted project and [reviewing/trusting the hook definition through `/hooks`](https://developers.openai.com/codex/hooks#review-and-trust-hooks); changed definitions require review again. No hook-trust bypass is configured.

## Native tests

Run from `example/` after `bun run prebuild`:

```sh
bun run test:ios:unit       # module unit tests: scheme ExpoNativeCollaborativeEditor-Unit-Tests
bun run test:ios:ui         # example UI tests: app scheme, Release build (JS bundle embedded, no Metro)
```

`bun run ios` and all native test scripts reuse the existing simulator pinned by UDID in `example/package.json` `config.simulator`. Native tests run serially with `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`; do not create or clone simulators or fall back to another device. If the pinned simulator is unavailable, stop and report it. The unit and UI test scripts pass `-quiet` to `xcodebuild`, so a passing run prints only warnings; failures exit non-zero.

- Unit tests live in `ios/Tests/` and build as the podspec's `Tests` test spec.
- UI tests live in `example/uitests/` and build as the `ExampleUITests` target.

`EditingSurfaceTests` is a native editing-surface integration test: it hosts the actual SwiftUI/`UITextView` surface and drives public `UITextInput` calls for composition and system replacements. Run it alone while changing the input adapter:

```sh
bun run test:ios:unit -only-testing:ExpoNativeCollaborativeEditor-Unit-Tests/EditingSurfaceTests
```

Remote updates persist during marked-text composition, but their surface patches wait until composition ends; the local commit rebases through their deltas. Marked text is unsaved input and never an outbox operation. Simulator keyboard limits and the physical-device checklist for #18 are recorded in [`m1-evidence.md`](m1-evidence.md#composition-and-system-replacements-g6-6).


`FormattingTests` covers plugin validation, option changes without content/history reset, mixed selection state, UTF-16 boundaries, incremental mark-only updates, metadata upgrade, concurrent mark/deletion manifest convergence, and concurrent text/formatting on three replicas with recorded seeds 1–20. `EditingSurfaceTests` also exercises native typing fonts, remote mark-only patches, and formatting during composition.

`ListTests` exercises all 27 three-level combinations of ordered, unordered, and checklist items, the ADR 0005 structural commands, stable identities, attributed subtree moves, undo/redo, restart, the stored block layout, and the deterministic projection of malformed structure without writes. `ConcurrentListTests` runs the seven G4 concurrent scenarios between two replicas and G3's 20 recorded seeds of random concurrent text, mark, structure, and checklist edits on three replicas (ADR 0008 records the results). `ListEditingSurfaceTests` drives native Return, Backspace, selected deletion, checkbox touch/accessibility actions, composition, scrolling, resizing, and Dynamic Type. `ListPluginTests` covers configuration changes and explicit checklist cascades. The Release UI list scenario creates four mixed levels, toggles parent and child independently, and reopens the saved document; `RemoteEditTests` also runs the scripted concurrent nested-list scenario on the editing surface.

`example/plugins/withNativeTests.js` wires both into the generated project during prebuild: it adds the module pod with `:testspecs => ['Tests']` to the Podfile, and adds the `ExampleUITests` target (every `example/uitests/*.swift` file) to the app's Xcode project and scheme. After adding a Swift file to either directory, rerun `bunx expo prebuild --platform ios --clean`.

## Cross-language fixtures

`fixtures/` holds golden updates showing that Yrs (SwiftYrs) and Yjs 13.6.33, the engine's JavaScript implementation (pinned in the root `devDependencies`), decode the same bytes to the same document. Verify the corpus from `example/` after `bun run prebuild`:

```sh
bun run test:fixtures       # fixtures/corpus.test.ts (Yjs), then FixtureCorpusTests (Yrs) on the simulator
```

Both tests decode every fixture: they apply each update twice, since replaying an update must change nothing, then replay every update again, comparing the result with the scenario's semantic snapshots. Each failure names its fixture as `<origin>/<scenario>`, such as `swift/zwj-sequences`; Swift failures add the step. The Swift half runs `xcodebuild` without `-quiet`, which in Xcode 27 hides assertion messages, and prints only its `error:` lines and result.

| File                          | Contents                                                                                  |
| ----------------------------- | ----------------------------------------------------------------------------------------- |
| `fixtures/corpus.json`        | Scenario name → the semantic snapshot after each step. Hand-written: the expected values. |
| `fixtures/updates/swift.json` | Scenario name → the Yrs v1 updates a `DocumentSession` committed, one per step (base64).  |
| `fixtures/updates/js.json`    | Scenario name → Yjs v1 updates, one transaction per step (base64).                        |

Recorded updates are golden: recording adds only the scenarios an origin's file lacks. Scenarios a snapshot diff cannot express have explicit Yjs scripts in `fixtures/record.ts` (`nested-lists`, `malformed-blocks`); sessions never write malformed structure, so Swift records `malformed-blocks` from a raw Yrs document. After adding a scenario to `corpus.json`, record JavaScript first, so that the Swift run, which also verifies, finds both origins:

```sh
bun ../fixtures/record.ts
TEST_RUNNER_RECORD_FIXTURES=1 bun run test:ios:unit -only-testing:ExpoNativeCollaborativeEditor-Unit-Tests/FixtureCorpusTests
bun run test:fixtures
```

To re-record a changed scenario, first delete its entry from both update files.

### Semantic snapshot

The engine-independent projection of a document that tests compare: `SemanticSnapshot` in Swift (`ios/Core/SemanticSnapshot.swift`, also the source of the document session's plain text) and `semanticSnapshot` in JavaScript (`fixtures/semanticSnapshot.ts`). It is a JSON object:

| Key    | Value                                                                   |
| ------ | ----------------------------------------------------------------------- |
| `text` | The document text: Unicode scalars exactly as stored, never normalized. |
| `marks` | Optional, ordered nonoverlapping runs: `{ offset, length, bold?: true, italic?: true, heading?: 1..6 }`. Offsets and lengths count UTF-16 code units. Adjacent equal runs coalesce; plain runs are omitted. |
| `features` | Optional, sorted semantic requirements, such as `formatting.bold@1`. Monotonic: removing marks or undoing their creation does not remove requirements. |
| `listItems` | Optional display-order items: `{ id, kind: 'ordered' \| 'unordered' \| 'checklist', parent?, checked?, offset, length, depth }`. UTF-16 offsets start at paragraph text; length excludes the LF that joins it to the next paragraph. Depth is zero-based; roots omit `parent`, and only checklist items carry `checked`. |

Equality is exact: canonically equivalent text, such as `é` and `e` + U+0301, differs. Empty `marks`, `features`, and `listItems` keys are omitted, keeping the existing text scenarios valid. The `marks` scenario covers overlapping bold/italic, headings, surrogate-pair insertion inside a marked run, mark removal, and deletion to an empty document with retained feature requirements. The twelve-step `nested-lists` scenario covers fixed identities, three mixed levels, independent checked states, outdent/indent, and parent/subtree deletion. `malformed-blocks` is one document with a duplicate label, a cycle, a parent that never existed, a reused identity, an unknown kind, non-boolean checked values, and `order` entries that disagree with the text; both engines must project it identically.

## Formatting feature plugin (provisional, #8)

```ts
import { formattingPlugin, nativeCapabilities, openDocument } from 'expo-native-collaborative-editor';

const session = await openDocument({
  accountNamespace: 'account',
  documentId: 'document',
  plugins: [formattingPlugin({ bold: true, italic: true, headingLevels: [1, 2, 3] })],
});
await session.toggleBold();
await session.toggleItalic();
await session.setHeading(1); // 0 restores ordinary paragraphs.
await session.setPlugins([]); // Disables authoring; does not clear content, typing marks, or history.
```

`nativeCapabilities` describes the actual native build. Each `FeaturePlugin` carries a nonempty unique `id`, `capability`, `version`, and typed `options`. One registration per capability is allowed. `formattingPlugin` uses ID/capability `formatting`, version 1; defaults are bold/italic enabled and heading levels 1–6. Heading levels normalize to sorted unique integers. The native boundary revalidates and normalizes every registration before opening or changing a session. Missing capabilities, incompatible versions, duplicate IDs/capabilities, and malformed/unknown options reject with `error.code === 'ERR_EDITOR_CONFIGURATION'`; failed configuration leaves the live session unchanged.

Opening a document without `plugins` enables no authoring plugins. Reopening a live session with explicit configuration updates that shared session; views and undo history stay attached. Runtime changes affect future commands, never remove stored marks or change how supported content renders. Existing formatting can still be inherited while typing when its authoring controls are disabled.

Collapsed-selection bold/italic commands change native typing attributes without writing content. Inserting text commits those semantic attributes in the same core transaction as the insertion. Selection commands change only the corresponding retained range. Heading commands expand to whole touched paragraphs; empty paragraphs use typing attributes until text exists. Heading changes preserve separately chosen inline typing marks. Marks are `YText` attributes `bold`, `italic`, and `heading` across paragraph characters and the LF joining a paragraph to the next, including an unterminated final paragraph; there are no hidden characters. Fonts and Dynamic Type sizes remain presentation, not document data.

`session.state.selectedFormatting` and `stateChange` expose `{ bold, italic, heading }`. `null` means mixed; heading 0 means ordinary paragraphs. The example uses these values for selected button styles and accessibility values, and includes a runtime enable/disable control. Native typing, rendering, commands, and persistence run without per-keystroke JavaScript.

Semantic requirements live in the CRDT root map `features` (`formatting.bold@1`, `formatting.italic@1`, `formatting.heading@1`, value 1), written with the first use in the same transaction and persisted/synchronized through the ordinary outbox. They are outside the undo scope (`body`, `blocks`, `order`). The unused SQLite seed column `feature_manifest` is removed on upgrade only when every legacy value is an empty array; nonempty legacy requirements fail visibly rather than being discarded. Application ID, lifecycle generation, and the schema identifier (`yrs-update-v1/blocks-1`) stay in SQLite metadata.

## Lists/checklists feature plugin (provisional, #9)

```ts
import { listsPlugin, openDocument } from 'expo-native-collaborative-editor';

const session = await openDocument({
  accountNamespace: 'account',
  documentId: 'document',
  plugins: [listsPlugin()],
});
await session.setListKind('checklist'); // Converts the selected paragraphs.
```

`listsPlugin` registers ID/capability `lists`, version 1, advertised by `nativeCapabilities.lists`. Options `ordered`, `unordered`, and `checklist` default to `true`; `caution__enableChecklistChildrenAutoCompletion` defaults to `false`. Options must be booleans; the same atomic registration validation as formatting applies. Combine `listsPlugin()` and `formattingPlugin()` in the session's plugin array when both are needed. Changing plugins replaces the array, so retain every capability the host still wants enabled.

| Session command | Behavior |
| --- | --- |
| `setListKind(kind)` | Converts selected paragraphs to the requested kind while retaining existing item identities. `null` restores ordinary paragraphs and promotes surviving children; a nested conversion first exits the enclosing root subtree, preserving unselected sibling parentage. |
| `insertReturn()` | Splits text into siblings. The left item retains identity, checked state, and children; the new right item follows that subtree, has a new identity and no children, and starts unchecked. An empty nested item outdents with its subtree; an empty root item exits the list and promotes children. |
| `deleteBackward()` | At an item start, joins the previous sibling's text while keeping the left identity, kind, checked state, and both child groups in order. Without a previous sibling, outdents or exits the list. Otherwise deletes the selection or previous grapheme. |
| `indentListItem()` / `outdentListItem()` | Moves the current item and its entire subtree, preserving relative structure and checked states. Indent uses the previous sibling as parent; outdent places the subtree after its former parent's remaining children. |
| `removeListItem(id, includingChildren = false)` | Removes only that item's paragraph and promotes children one level. Pass `true` to delete the entire subtree. Native selected deletion removes only selected content. |
| `toggleChecklistItem(id)` | Toggles only that item by default. Existing checklists remain toggleable even when list authoring is disabled. |

Disabling a kind prevents creating/converting items to that kind, not rendering or editing already stored content. Structural commands reject marked-text composition; native input waits for composition to commit. The example provides native list-kind, indent/outdent, and ordinary-paragraph controls without sending document text through JavaScript.

With unordered authoring enabled, inserting one unmarked ASCII space at a collapsed caret immediately after a lone ASCII `-` at the start of a non-list paragraph converts it to an unordered item. The native shortcut consumes `- `, preserves suffix text and formatting, and puts the caret before the suffix (offset zero for an empty item). One undo restores the literal prefix in an ordinary paragraph; redo restores the item. Missing/disabled unordered authoring, composition (including its commit), selected replacements, other prefixes, mid-paragraph input, and multi-character pasted `- ` remain literal. Opening and remote delivery never run recognition; converted items use ordinary durable commits and selective undo, and render on replicas with authoring disabled.

`ListTests` covers recognition boundaries, attributed suffixes, earlier undo history, restart, and unreliable delivery with unrelated remote edits. `ListEditingSurfaceTests` drives native `insertText`, `UITextInput.replace`, composition, undo/redo, continued typing, Return, and Backspace. The example's `ProofScreenTests.testTypingHyphenThenSpaceConvertsToListAndSupportsNativeUndoRedoAndContinuedTyping` exercises the same shortcut through the on-screen editor.

The opt-in `caution__enableChecklistChildrenAutoCompletion` action sets the tapped checklist item and its currently known checklist descendants to the same checked state in one undoable transaction. It never derives parent state from children, runs on open/remote delivery, or imposes a rule on later children. With the option disabled, toggling does no descendant traversal.

The explicit block model ([ADR 0008](adr/0008-explicit-block-document-model.md)) stores every paragraph as a block: `YText body` holds the text, each block after the first starting with an LF labeled `block: <key>`; the `blocks` map holds `<key>/kind`, `/id`, `/parent`, `/checked`, and `/removed`; the `order` array holds sibling order. Structural commands change only those properties, so concurrent edits inside a moved item move with it; Return inserts one labeled LF and never copies text. Removed items keep their properties and position, so their children, including ones added concurrently, are promoted in place. The projection to display paragraphs is deterministic and never writes: cycles, missing parents, reused identities, and unknown kinds project the same way in Swift and JavaScript.

Semantic requirements `lists.ordered@1`, `lists.unordered@1`, and `lists.checklist@1` use the existing monotonic CRDT `features` map and ordinary durable outbox. Local undo does not erase requirements. Subtree moves preserve formatting runs and item IDs. Lines pasted into an item with children follow its subtree, like Return, and the session sends the surface a correcting edit.

The existing TextKit 2 fallback renders native checkbox buttons beside editable text, with 44-by-44-point hit targets, item-text labels (or “Empty checklist item”), Checked/Unchecked values, selected traits, and a VoiceOver `Toggle` action. Markers follow native scrolling, resizing, and Dynamic Type. The public `testID` identifies the editable `UITextView`, not its checkbox container. Public `TextEditor` checkbox limitations and native proof are recorded in [`m1-evidence.md`](m1-evidence.md#nested-lists-and-checklists-g2g6g12-9).

Unordered markers are presentation-only ASCII `-`; neither markers nor spacing enter document text. List paragraphs keep native font-sized text lines and carets; paragraph spacing reserves checkbox room without a 44-point minimum line height. Marker hit targets remain 44 by 44 points, aligned to the first text line's baseline. Empty final items carry indentation in native typing attributes because no stored character exists to style. `ListEditingSurfaceTests` compares list carets with ordinary text and checks empty/wrapped/nested items through scrolling, resizing, and Dynamic Type.
