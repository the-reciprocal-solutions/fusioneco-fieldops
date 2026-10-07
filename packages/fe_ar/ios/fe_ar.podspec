#
# fe_ar iOS: ARKit (+ LiDAR scene depth) tracking, Filament (Metal) rendering,
# Vision barcodes, and the shared C core (../src, via Classes/fe_ar_core_shim.c).
#
# CocoaPods, not Swift Package Manager: Filament ships for iOS as a pod (or a
# release tarball), not as a Swift package. The FieldOps app builds its other
# plugins with SwiftPM; Flutter falls back to CocoaPods for a plugin that has
# no Package.swift, so enabling fe_ar makes the app's iOS build use both
# (a Podfile appears on the first `flutter build ios`).
#
Pod::Spec.new do |s|
  s.name             = 'fe_ar'
  s.version          = '0.1.0'
  s.summary          = 'FieldOps AR engine: ARKit + Filament, native half of the fusioneco/ar channel.'
  s.description      = 'Headless AR engine for the FusionEco FieldOps app. See README.md and CHANNEL.md.'
  s.homepage         = 'https://fusionapps.com'
  s.license          = { :type => 'Proprietary', :text => 'Internal to FusionEco FieldOps.' }
  s.author           = { 'FusionEco' => 'dev@fusionapps.com' }
  s.source           = { :path => '.' }

  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.requires_arc     = true

  # Static, although the app's Podfile says `use_frameworks!` (dynamic).
  # Filament ships static libraries inside xcframeworks, and CocoaPods puts
  # their -l flags only on the app's link line (Pods-Runner), never on a
  # dependent pod's. A dynamic fe_ar.framework therefore failed its own link
  # step with ~100 "Undefined symbol: filament::… / utils::EntityManager /
  # _UBERARCHIVE_PACKAGE" errors (first Xcode build, 2026-10-05). A static
  # framework has no link step of its own: the app links fe_ar and Filament
  # together, once. Resource lookup is unaffected. bundleForClass: and
  # Bundle(for:) then return the main bundle, and [CP] Copy Pods Resources
  # puts fe_ar_assets.bundle there.
  s.static_framework = true

  # Classes/*_shim.c pull in ../src: fe_ar_core.c, fe_tag.c (board
  # AprilTags + planar PnP) and fe_apriltag_unity.c (the vendored AprilTag 3
  # detector, src/third_party/apriltag, BSD-2-Clause: its LICENSE.md must be
  # reproduced in the app's acknowledgements / licences screen).
  s.source_files        = 'Classes/**/*.{h,m,mm,c,swift}'
  s.public_header_files = 'Classes/FeArCore.h', 'Classes/FeArRenderer.h'
  # Compiled Filament materials (tool/compile_materials.sh writes them here).
  s.resource_bundles    = { 'fe_ar_assets' => ['Assets/*.filamat'] }

  s.dependency 'Flutter'
  # Must stay on the same MATERIAL_VERSION as the matc that compiled
  # Assets/*.filamat (1.72.1, the version SceneView uses on Android:
  # android/build.gradle feArFilamentVersion). 1.72.1 was never published to
  # CocoaPods trunk (checked 2026-09-27: newest is 1.72.0), so iOS pins
  # 1.72.0; both have MATERIAL_VERSION 72 (libs/filabridge MaterialEnums.h),
  # so the same .filamat loads on both. FeArRenderer.mm syntax-checks clean
  # against the 1.72.0 pod's headers. Bump all three together.
  s.dependency 'Filament/filament', '1.72.0'
  s.dependency 'Filament/gltfio_core', '1.72.0'

  s.frameworks = 'ARKit', 'Vision', 'Metal', 'MetalKit', 'CoreImage', 'CoreVideo', 'AVFoundation'
  s.libraries  = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu99',
    # The vendored AprilTag detector (../src/third_party/apriltag, BSD-2-Clause)
    # includes "common/..." from its own root. Its sources come in through a
    # Classes shim like the core's: #include "../../src/fe_tag.c" and
    # #include "../../src/fe_apriltag_unity.c" (see ../src/fe_tag.h).
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/../src/third_party/apriltag"',
    # Filament's prebuilt libraries are device + simulator xcframeworks, but
    # Metal-backed AR can't run in the simulator; don't try to link i386.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
