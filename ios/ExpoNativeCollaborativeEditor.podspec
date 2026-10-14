Pod::Spec.new do |s|
  s.name           = 'ExpoNativeCollaborativeEditor'
  s.version        = '1.0.0'
  s.summary        = 'A sample project summary'
  s.description    = 'A sample project description'
  s.author         = ''
  s.homepage       = 'https://docs.expo.dev/modules/'
  s.platforms      = { :ios => '26.0' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.dependency 'ExpoUI'

  # CRDT engine (Yrs). SwiftYrs is SwiftPM-only; React Native's Podfile helper adds the package to the
  # Pods project during `pod install`, so autolinking needs no host steps.
  spm_dependency(s,
    url: 'https://github.com/siuying/SwiftYrs',
    requirement: { kind: 'exactVersion', version: '0.7.0' },
    products: ['SwiftYrs']
  )
  # SwiftYrs ships arm64 device and simulator slices only, so the host's simulator builds (Release
  # builds every architecture) leave out x86_64.
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64',
  }

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
  s.exclude_files = "Tests/**/*"

  s.test_spec 'Tests' do |test_spec|
    test_spec.source_files = "Tests/**/*.swift"
    # React Native's static C++ pods are linked transitively.
    test_spec.libraries = "c++"
  end
end
