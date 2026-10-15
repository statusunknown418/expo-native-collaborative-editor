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

## From a clean clone

```sh
bun install                 # module deps; `prepare` builds src/ into build/ and installs Git hooks
cd example
bun install
bun run prebuild            # expo prebuild --platform ios (generates example/ios, runs pod install)
bun run ios                 # builds Debug, boots the simulator, starts Metro, launches the app
```

The example opens the proof screen: a local-only document (`example-account` / `proof-document`) in the module's `EditingSurface`, with "Saved on this phone" shown once every edit is committed and a button that unmounts and remounts the surface. Launching with `-documentId <id>` opens another document; the UI tests use this for a fresh document per run. Launching with `-remoteEdits <percent-encoded JSON>`, an array of `{ "offset", "deleteCount", "text" }` in UTF-16 code units, connects a test-only scripted remote replica through the in-process delivery harness, shows "Pending synchronization" until receipts acknowledge every committed edit, and adds a "Remote edit" button that makes the next edit; `RemoteEditTests` uses it.

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

`bun run ios` and both test scripts use the simulator in `example/package.json` `config` (`simulator`, `simulatorOS`); edit those values to target a different iOS 26 simulator. The test scripts pass `-quiet` to `xcodebuild`, so a passing run prints only warnings; failures print `error:` lines and exit non-zero.

- Unit tests live in `ios/Tests/` and build as the podspec's `Tests` test spec.
- UI tests live in `example/uitests/` and build as the `ExampleUITests` target.

`EditingSurfaceTests` is a native editing-surface integration test: it hosts the actual SwiftUI/`UITextView` surface and drives public `UITextInput` calls for composition and system replacements. Run it alone while changing the input adapter:

```sh
bun run test:ios:unit -only-testing:ExpoNativeCollaborativeEditor-Unit-Tests/EditingSurfaceTests
```

Remote updates persist during marked-text composition, but their surface patches wait until composition ends; the local commit rebases through their deltas. Marked text is unsaved input and never an outbox operation. Simulator keyboard limits and the physical-device checklist for #18 are recorded in [`m1-evidence.md`](m1-evidence.md#composition-and-system-replacements-g6-6).


`FormattingTests` covers plugin validation, option changes without content/history reset, mixed selection state, UTF-16 boundaries, incremental mark-only updates, metadata upgrade, concurrent mark/deletion manifest convergence, and concurrent text/formatting on three replicas with recorded seeds 1–20. `EditingSurfaceTests` also exercises native typing fonts, remote mark-only patches, and formatting during composition.

To use one existing simulator without creating test clones, pass its UDID explicitly rather than using the package's name-based defaults:

```sh
xcodebuild test -workspace ios/exponativecollaborativeeditorexample.xcworkspace \
  -scheme ExpoNativeCollaborativeEditor-Unit-Tests \
  -destination 'platform=iOS Simulator,id=ACB21CAA-329B-45B3-AE1C-B62FDC03F8BF' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
```

For the example UI suite, use scheme `exponativecollaborativeeditorexample` and add `-configuration Release`. Run both commands from `example/`.

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

Recorded updates are golden: recording adds only the scenarios an origin's file lacks. After adding a scenario to `corpus.json`, record JavaScript first, so that the Swift run, which also verifies, finds both origins:

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

Equality is exact: canonically equivalent text, such as `é` and `e` + U+0301, differs. Empty `marks` and `features` keys are omitted, keeping the existing text scenarios valid. The `marks` scenario covers overlapping bold/italic, headings, surrogate-pair insertion inside a marked run, mark removal, and deletion to an empty document with retained feature requirements.

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

Collapsed-selection bold/italic commands change native typing attributes without writing content. Inserting text commits those semantic attributes in the same core transaction as the insertion. Selection commands change only the corresponding retained range. Heading commands expand to whole touched paragraphs; empty paragraphs use typing attributes until text exists. Heading changes preserve separately chosen inline typing marks. The provisional linear representation uses `YText` attributes `bold`, `italic`, and `heading` across paragraph characters and separators, including an unterminated final paragraph; it adds no hidden characters. Fonts and Dynamic Type sizes remain presentation, not document data. Representation is not frozen before #18.

`session.state.selectedFormatting` and `stateChange` expose `{ bold, italic, heading }`. `null` means mixed; heading 0 means ordinary paragraphs. The example uses these values for selected button styles and accessibility values, and includes a runtime enable/disable control. Native typing, rendering, commands, and persistence run without per-keystroke JavaScript.

Semantic requirements live in the CRDT root map `features` (`formatting.bold@1`, `formatting.italic@1`, `formatting.heading@1`, value 1), written with the first use in the same transaction and persisted/synchronized through the ordinary outbox. They are not part of the body-only undo scope. The unused SQLite seed column `feature_manifest` is removed on upgrade only when every legacy value is an empty array; nonempty legacy requirements fail visibly rather than being discarded. Application ID, lifecycle generation, and the original provisional schema identifier stay in SQLite metadata.
