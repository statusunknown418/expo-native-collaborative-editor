// Adds the native test targets run by `bun run test:ios:unit` and `bun run test:ios:ui`:
// - the module pod's `Tests` test spec (scheme `ExpoNativeCollaborativeEditor-Unit-Tests`);
// - a UI-test target for the example app built from `uitests/*.swift`, run by the app scheme.
const { withPodfile, withXcodeProject } = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');

const UI_TESTS = 'ExampleUITests';
const UI_TESTS_DIR = path.join(__dirname, '..', 'uitests');

const withModuleTestSpec = (config) =>
  withPodfile(config, (config) => {
    const modulePath = path.relative(
      config.modRequest.platformProjectRoot,
      path.join(config.modRequest.projectRoot, '..', 'ios')
    );
    // Declared before `use_expo_modules!`, which then skips re-adding the pod without test specs.
    const line = `  pod 'ExpoNativeCollaborativeEditor', :path => '${modulePath}', :testspecs => ['Tests']\n`;
    if (!config.modResults.contents.includes(line)) {
      config.modResults.contents = config.modResults.contents.replace(
        /^(\s*use_expo_modules!)/m,
        `${line}$1`
      );
    }
    return config;
  });

const withUITestTarget = (config) =>
  withXcodeProject(config, (config) => {
    const project = config.modResults;
    if (project.pbxTargetByName(UI_TESTS)) return config;

    const objects = project.hash.project.objects;
    const projectId = project.hash.project.rootObject;
    const pbxProject = objects.PBXProject[projectId];
    const app = project.getFirstTarget();
    const appName = app.firstTarget.name.replace(/"/g, '');
    const add = (isa, comment, fields) => {
      const id = project.generateUuid();
      objects[isa] ??= {};
      objects[isa][id] = { isa, ...fields };
      objects[isa][`${id}_comment`] = comment;
      return { value: id, comment };
    };

    const sources = fs.readdirSync(UI_TESTS_DIR).filter((file) => file.endsWith('.swift'));
    const fileRefs = sources.map((file) =>
      add('PBXFileReference', file, {
        lastKnownFileType: 'sourcecode.swift',
        path: file,
        sourceTree: '"<group>"',
      })
    );
    const group = add('PBXGroup', UI_TESTS, {
      children: fileRefs,
      path: `"${path.relative(config.modRequest.platformProjectRoot, UI_TESTS_DIR)}"`,
      sourceTree: '"<group>"',
    });
    objects.PBXGroup[pbxProject.mainGroup].children.push(group);

    const product = add('PBXFileReference', `${UI_TESTS}.xctest`, {
      explicitFileType: 'wrapper.cfbundle',
      includeInIndex: 0,
      path: `${UI_TESTS}.xctest`,
      sourceTree: 'BUILT_PRODUCTS_DIR',
    });
    objects.PBXGroup[pbxProject.productRefGroup].children.push(product);

    const sourcesPhase = add('PBXSourcesBuildPhase', 'Sources', {
      buildActionMask: 2147483647,
      files: fileRefs.map((ref) =>
        add('PBXBuildFile', `${ref.comment} in Sources`, {
          fileRef: ref.value,
          fileRef_comment: ref.comment,
        })
      ),
      runOnlyForDeploymentPostprocessing: 0,
    });
    const proxy = add('PBXContainerItemProxy', 'PBXContainerItemProxy', {
      containerPortal: projectId,
      containerPortal_comment: 'Project object',
      proxyType: 1,
      remoteGlobalIDString: app.uuid,
      remoteInfo: appName,
    });
    const dependency = add('PBXTargetDependency', 'PBXTargetDependency', {
      target: app.uuid,
      target_comment: appName,
      targetProxy: proxy.value,
      targetProxy_comment: proxy.comment,
    });

    const buildSettings = {
      GENERATE_INFOPLIST_FILE: 'YES',
      IPHONEOS_DEPLOYMENT_TARGET: config.ios.deploymentTarget,
      PRODUCT_BUNDLE_IDENTIFIER: `"${config.ios.bundleIdentifier}.uitests"`,
      PRODUCT_NAME: '"$(TARGET_NAME)"',
      SWIFT_VERSION: '5.0',
      TARGETED_DEVICE_FAMILY: '"1,2"',
      TEST_TARGET_NAME: appName,
    };
    const configList = add(
      'XCConfigurationList',
      `Build configuration list for PBXNativeTarget "${UI_TESTS}"`,
      {
        buildConfigurations: ['Debug', 'Release'].map((name) =>
          add('XCBuildConfiguration', name, { buildSettings: { ...buildSettings }, name })
        ),
        defaultConfigurationIsVisible: 0,
        defaultConfigurationName: 'Release',
      }
    );

    const target = add('PBXNativeTarget', UI_TESTS, {
      buildConfigurationList: configList.value,
      buildConfigurationList_comment: configList.comment,
      buildPhases: [sourcesPhase],
      buildRules: [],
      dependencies: [dependency],
      name: UI_TESTS,
      productName: UI_TESTS,
      productReference: product.value,
      productReference_comment: product.comment,
      productType: '"com.apple.product-type.bundle.ui-testing"',
    });
    pbxProject.targets.push(target);
    pbxProject.attributes.TargetAttributes[target.value] = { TestTargetID: app.uuid };

    // Point the app scheme's test action at the new target.
    const schemePath = path.join(
      config.modRequest.platformProjectRoot,
      `${appName}.xcodeproj/xcshareddata/xcschemes/${appName}.xcscheme`
    );
    const testables = `<Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "${target.value}"
               BuildableName = "${UI_TESTS}.xctest"
               BlueprintName = "${UI_TESTS}"
               ReferencedContainer = "container:${appName}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>`;
    const scheme = fs.readFileSync(schemePath, 'utf8');
    const testablesBlock = /<Testables>[\s\S]*?<\/Testables>/;
    if (!testablesBlock.test(scheme)) {
      throw new Error(`withNativeTests: no <Testables> block in ${schemePath}`);
    }
    fs.writeFileSync(schemePath, scheme.replace(testablesBlock, testables));

    return config;
  });

module.exports = (config) => withUITestTarget(withModuleTestSpec(config));
