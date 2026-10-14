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
bun install                 # module deps; `prepare` builds src/ into build/
cd example
bun install
bun run prebuild            # expo prebuild --platform ios (generates example/ios, runs pod install)
bun run ios                 # builds Debug, boots the simulator, starts Metro, launches the app
```

The example opens the proof screen: a local-only document (`example-account` / `proof-document`) in the module's `EditingSurface`, with "Saved on this phone" shown once every edit is committed and a button that unmounts and remounts the surface. Launching with `-documentId <id>` opens another document; the UI test uses this for a fresh document per run.

`example/ios` is generated and git-ignored. After changing `example/app.json`, `example/plugins/`, the podspec, or native dependencies, regenerate it with `bunx expo prebuild --platform ios --clean`.

While editing the module's TypeScript, run `bun run build` at the root to rebuild `build/` on change; Metro resolves the module through its `main` entry.

## Native tests

Run from `example/` after `bun run prebuild`:

```sh
bun run test:ios:unit       # module unit tests: scheme ExpoNativeCollaborativeEditor-Unit-Tests
bun run test:ios:ui         # example UI tests: app scheme, Release build (JS bundle embedded, no Metro)
```

`bun run ios` and both test scripts use the simulator in `example/package.json` `config` (`simulator`, `simulatorOS`); edit those values to target a different iOS 26 simulator. The test scripts pass `-quiet` to `xcodebuild`, so a passing run prints only warnings; failures print `error:` lines and exit non-zero.

- Unit tests live in `ios/Tests/` and build as the podspec's `Tests` test spec.
- UI tests live in `example/uitests/` and build as the `ExampleUITests` target.

`example/plugins/withNativeTests.js` wires both into the generated project during prebuild: it adds the module pod with `:testspecs => ['Tests']` to the Podfile, and adds the `ExampleUITests` target (every `example/uitests/*.swift` file) to the app's Xcode project and scheme. After adding a Swift file to either directory, rerun `bunx expo prebuild --platform ios --clean`.
