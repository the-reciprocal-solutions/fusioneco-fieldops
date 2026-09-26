# fe_ar

The native half of FieldOps AR: the camera, tracking, marker and corner detection, drawing the BIM tiles, and picking. **Native executes, Dart decides** ([docs/ar-bim-overlay.md §6.1](../../docs/ar-bim-overlay.md)): every decision (where the model goes, which tiles are resident, what is highlighted, which observation to trust) is made in the app's pure Dart (`lib/core/ar/`), and every pixel of UI is Flutter's. This plugin is headless.

**Status (2026-09-26): Android builds and runs; iOS not built yet.** It is a path dependency of the app. On a OnePlus 7 Pro (Android 11) the camera, ARCore tracking and Filament tile drawing work; registering the model to the room is still open (app `PENDING.md` P-012), and the `.filamat` materials are not compiled yet. The app embeds the view with Hybrid Composition and `surface: 'surface'` (texture-layer mode broke the swap chain on resize). Remaining `TODO(slice-0)` markers still need confirming.

| | Android | iPhone / iPad |
|---|---|---|
| Tracking | ARCore 1.54 through SceneView 4.39 (`arsceneview`) | ARKit world tracking, LiDAR scene depth where present |
| Rendering | Filament 1.72.1 (SceneView's) | Filament 1.72.1 (CocoaPods), Metal, hello-ar structure |
| QR decode | ML Kit barcode (bundled model) | Vision `VNDetectBarcodesRequest` |
| Tiles, pick, corners, overlay | shared C core (`src/`), over JNI | shared C core, compiled into the pod |
| Host | `ComposeView` hosting SceneView's `ARSceneView` composable in a platform view | `UiKitView` on a `CAMetalLayer` |

The protocol, with every argument map, is in **[CHANNEL.md](CHANNEL.md)**.

## Layout

```
packages/fe_ar/
  pubspec.yaml            plugin: android com.fusionapps.fe_ar / FeArPlugin, ios FeArPlugin
  lib/fe_ar.dart          channel names and codes (the Dart engine lives in the app)
  CHANNEL.md              the wire contract
  src/                    shared C core: GLB + meshopt decode, pick, corners, overlay GLB
    test/                 laptop tests + fixtures made by the real meshopt encoder
  materials/              Filament materials (.mat sources; compile with matc)
  tool/                   compile_materials.sh, make_core_fixtures.mjs
  android/                Kotlin + JNI (CMake builds src/ into libfe_ar_core.so)
  ios/                    Swift + Objective-C++ (Filament) + the C core
```

## Enabling it in the app (slice 0)

1. **Dart.** In the app's `pubspec.yaml`:
   ```yaml
   dependencies:
     fe_ar:
       path: packages/fe_ar
   ```
   fe_ar depends on nothing but the Flutter SDK, so `pubspec.lock` gains only the path entry (run `flutter pub get` once with a toolchain that can rewrite the lock, then go back to `--enforce-lockfile`). The app already talks to it: `ChannelArEngine` and `ArView` use the channel and view names, and fall back to Demo mode when the plugin is missing.

2. **Android.**
   - `minSdk` 24 or higher (SceneView's floor). Check `flutter.minSdkVersion` in `android/app/build.gradle.kts`.
   - `compileSdk` 37: SceneView 4.34+ compiles against API 37, and its AndroidX dependencies may require the app to as well (the AAR-metadata check says so if needed). Done (2026-09-26): the app uses `compileSdk { version = release(37) { minorApiLevel = 0 } }`, because API 37 installs as `android-37.0` and a bare `37` does not resolve.
   - Kotlin: `android/build.gradle` applies `org.jetbrains.kotlin.plugin.compose` at **2.4.0**, which must equal the app's `org.jetbrains.kotlin.android` version in `android/settings.gradle.kts`. Bump both together.
   - Manifest: nothing to add. The plugin's manifest merges in `CAMERA` (the app has it), `android.hardware.camera.ar` **not required**, and `<meta-data android:name="com.google.ar.core" android:value="optional"/>`: AR is optional, so Play never blocks the install and tier-C devices get the floor plan. Don't set it to `required`.
   - The app's activity is locked to portrait (`android:screenOrientation="portrait"`); tablets will want landscape for the AR workspace (docs/ar-setup-and-gamma-parity.md §2.9).
   - NDK: the app pins every subproject to NDK 30.0.16138531 (`android/build.gradle.kts`); the C core builds with it.

3. **iOS.**
   - Deployment target 15.0 (the app's). ARKit, Vision and Metal are system frameworks.
   - `Info.plist`: `NSCameraUsageDescription` exists but talks only about photos. Extend it, for example: "Used for job photos, and to show the building model over the camera in AR."
   - Nothing like `UIRequiredDeviceCapabilities → arkit`: that would hide the app from devices without ARKit. AR is optional.
   - **CocoaPods.** Filament ships for iOS as a pod (or a tarball), not a Swift package, so fe_ar has a podspec and no `Package.swift`. The app builds its other plugins with Swift Package Manager; Flutter falls back to CocoaPods for fe_ar, and a `Podfile` appears in `ios/` on the first `flutter build ios`. The Filament pod is large (hundreds of MB of xcframeworks, device and simulator slices): expect a slow first `pod install`.
   - The simulator has no ARKit world tracking and Filament's Metal backend needs a real GPU: test on devices.

4. **Materials** (both platforms, once per Filament version bump): see below. Without them the app still runs; see the fallbacks.

5. **Permissions at runtime.** The plugin never prompts. The app asks for the camera (permission_handler, already a dependency); until it has it, `capabilities()` reports `supported: false, reason: camera-denied`.

## Filament materials

`materials/fe_feature.mat` is the one material every tile is drawn with, on both platforms: per-feature colour, ghost/normal/highlight modes, the section plane, x-ray drawing through walls with a pulse and a rim outline. `materials/fe_camera_feed.mat` draws the ARKit camera image on iOS (hello-ar's material, with exact sRGB decoding).

They must be compiled with the `matc` of **the same Filament version as the runtime** (1.72.1; `android/build.gradle` `feArFilamentVersion`, `ios/fe_ar.podspec`), from that version's desktop release (`filament-v1.72.1-mac.tgz` → `bin/matc`):

```bash
MATC=/path/to/filament/bin/matc packages/fe_ar/tool/compile_materials.sh
```

This writes `android/src/main/assets/fe_ar/fe_feature.filamat` and `ios/Assets/*.filamat` (`--api all --platform mobile`: one binary carries OpenGL ES, Vulkan and Metal). Commit the outputs with the version bump.

**Gradle alternative (CI):** pass `-PfeArMatc=/path/to/matc` (or `FE_AR_MATC=/path/to/matc`) to the Android build and `compileFeArMaterial` compiles `fe_feature.mat` into a generated assets folder before every build.

**Fallbacks when a compiled material is missing:**
- `fe_feature.filamat` missing: tiles are drawn with gltfio's stock material tinted per layer (MEP cyan, structure faint slate, architecture sky). No feature state (no progress colours, no hidden or highlighted elements), no section plane, no x-ray. `capabilities().featureMaterial` is `false`. Picking still works: it's CPU-side.
- `fe_camera_feed.filamat` missing (iOS): the Filament layer is transparent and the camera is drawn beneath it with Core Image. Slower, never black.

## Tile format expected (CONTRACT C7)

GLB, tile frame (Y up, metres), primitives grouped by layer and material, `EXT_meshopt_compression` + `KHR_mesh_quantization`, the local feature index in `TEXCOORD_1.x` as an unnormalised `UNSIGNED_SHORT`, architecture as `LINES`, and `extras.fe = {featureIds, layer, buildId}` on the scene. The file name is the SHA-256 of its bytes; fe_ar checks it.

Filament's gltfio decodes the tile for the GPU; the C core decodes it a second time for picking (gltfio exposes no vertex data to Java). The core's meshopt decoder is a port of meshoptimizer's own reference decoder and is tested against buffers from the real encoder driven through gltf-transform, the server's toolchain.

## Tests

The C core (tile decoding, meshopt vertex v0/v1 + index + sequence codecs and filters, ray casts with hidden-feature masks, corner fitting from points and from planes, plane fit, square pose, overlay GLB round trip, and a 3,000-case corruption fuzz) runs anywhere with a C compiler:

```bash
cd packages/fe_ar
cc -std=c99 -Wall -Wextra -O1 -g -fsanitize=address,undefined -I src \
   src/fe_ar_core.c src/test/fe_ar_core_test.c -lm -o /tmp/fe_ar_core_test
/tmp/fe_ar_core_test src/test/fixtures
```

Fixtures come from `tool/make_core_fixtures.mjs`, which borrows the server's `node_modules` (gltf-transform + meshoptimizer) so nothing is installed:

```bash
node tool/make_core_fixtures.mjs --node-modules ../../../fusion-eco-server/node_modules --out src/test/fixtures
```

The Kotlin, Swift and Objective-C++ halves can't be unit-tested meaningfully off-device (docs/ar-bim-overlay.md §10: "a written field checklist per release"). Slice 0 is where they get built.

## Slice 0 checklist

Build, then confirm each `TODO(slice-0)` in the source. The ones that decide architecture:

1. **SceneView 4.x in a Flutter platform view** (AR-3): the `ComposeView` + our lifecycle owner starts and pauses ARCore with the activity and with `pause`/`resume`; `texture` vs `surface` frame times and Flutter jank.
2. **Filament on iOS** (AR-37): the `Filament` pod at 1.72.1 resolves; `FeArRenderer.mm` compiles (C++20); the camera feed shows with `fe_camera_feed.filamat`; `setExternalImage` (deprecated overload) still works or moves to `ExternalImageHandleRef`; the mixed Swift/Objective-C pod builds under the app's Podfile.
3. **The material** (AR-2): `fe_feature.mat` compiles with matc 1.72.1; gltfio binds `TEXCOORD_1` (UV0 or UV1: the shader reads both) unnormalised; `getUserWorldPosition()` exists; x-ray draws through the ceiling; three instances per tile share one vertex buffer.
4. **Depth alignment on Android**: `acquireDepthImage16Bits` with `TEXTURE_NORMALIZED` coordinates and `textureIntrinsics` (the RawDepth sample's pairing) puts corner points where they belong.
5. **Disposal order**: the renderer is destroyed before SceneView destroys its engine (Compose forgets remembered objects in reverse order).
6. **Marker lock** (AR-4): about 15 samples in a second at 1080p CPU images; spread under 15 mm when held still; `qrEdgeMm` within 2% of 115 mm on a LiDAR iPad.

## Performance notes

- Tile uploads happen on the main thread one tile at a time, in Dart's order (focus tiles first); decoding for picks runs on a background thread.
- A tile costs one draw call per primitive for its solid pass; its ghost pass and x-ray pass are switched off unless the tile has features in those modes, so only tiles holding the target pay for x-ray.
- Feature state is gathered per tile into a 256-wide texture: a state change is a CPU loop over resident features plus one small upload per tile.
- Pick is brute force over resident triangles with a coarse per-64-triangle bounding-box skip (§6.4: "a BVH only if AR-21 profiling needs one").
- Events are throttled: pose 5 Hz, targetScreen 10 Hz, anchor refinements 2 Hz, coaching hints 1 per 1.5 s per code.
