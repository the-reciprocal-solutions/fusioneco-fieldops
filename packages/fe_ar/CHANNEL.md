# fe_ar channel protocol

The wire contract between the app's `ChannelArEngine` (`lib/core/ar/channel_ar_engine.dart`) and this plugin's two native halves (`android/…/FeArController.kt`, `ios/Classes/FeArController.swift`). It implements CONTRACT C8 and [docs/ar-bim-overlay.md §6.4](../../docs/ar-bim-overlay.md). **Change the Dart, Kotlin and Swift sides together.**

| Name | Kind | Direction |
|---|---|---|
| `fusioneco/ar` | `MethodChannel` (standard codec) | Dart → native commands. Method name = the `ArEngine` command name |
| `fusioneco/ar/events` | `EventChannel` | native → Dart events: maps with a `type` key |
| `fusioneco/ar/view` | platform view type | the AR surface (camera + model). Android `AndroidView`, iOS `UiKitView` |

## Conventions

- **Frames** (CONTRACT C2). *Tile frame*: the model, Y up, metres. *AR world*: the device session, Y up by gravity, metres. Nothing on the wire is Z-up.
- **Vectors** are `[x, y, z]` lists; floor-plane vectors are `[x, z]`. **Matrices** are 16 numbers, **column-major** (element (row r, col c) at `c * 4 + r`; translation at 12, 13, 14).
- **Screen points** (`x`, `y` in `pick`, `detectCornerAt`, `targetScreen`, `projectTile`) are **logical pixels** from the top-left of the AR view. Android multiplies by the display density; on iOS, points already are logical pixels.
- Numbers may arrive as int or double; both sides read them tolerantly. Unknown keys are ignored on both sides, which is how the extras below travel without breaking the contract.
- Every command answers on the platform (main) thread. Commands may arrive before the view exists: state is kept and replayed when the view (and its renderer) is created, and again if it is recreated.

## Commands

| Method | Arguments | Result |
|---|---|---|
| `capabilities` | — | `{supported: bool, depth: bool, lidar: bool, recording: bool, platform: "android"\|"ios", reason: String?}` plus extras `arcore` (Android availability name), `featureMaterial: bool`, `cameraMaterial: bool` (iOS) |
| `startSession` | optional `{depth: bool = true, progressEvents: bool = false, recordTo: path?, playbackFrom: path?}` | `null`. Starts tracking. Android: asks the Play Store for Google Play Services for AR when missing (then emits `error arcore-install-requested`); `recordTo`/`playbackFrom` use ARCore Recording & Playback (MP4). iOS: `recordTo`/`playbackFrom` emit `recording-unsupported` / `playback-unsupported` |
| `loadTiles` | `{tiles: [{hash: String, path: String}]}` | `{loaded: [hash], failed: [{hash, reason}]}` once every tile is decoded. Tiles upload **in the order sent** (send focus tiles first). The file's SHA-256 is compared with `hash`; a mismatch loads anyway and emits `error tile-hash-mismatch` |
| `unloadTiles` | `{hashes: [String]}` | `null` |
| `setModelTransform` | `{arFromTile: [16], easeMs: int = 300}` (`matrix` accepted as an alias) | `null`. Eases over `easeMs` (yaw along the shortest arc, translation linearly, smoothstep); `easeMs <= 0` or a non-4-DoF matrix applies at once. Native never computes a transform. **Until the first call after `startSession`/`stop`, the model (tiles, grid, pins) is loaded but hidden**, and the first call applies at once: the identity root would put the model at the session origin |
| `setFeatureState` | `{rgba: Uint8List, width: int, buildId: String?}` | `null`. One RGBA8 texel per feature id, row-major, `width` per row (`feature_state.dart`). **RGB** tint, `0,0,0` = none. **A** = display mode `round(a / 85)`: 0 hidden · 1 ghost · 2 normal · 3 highlight (drawn through walls, outlined, pulsing). Optional `buildId` scopes the texture to one build (feature ids are dense *per build*); without it the texture applies to every build that has no texture of its own |
| `setLayers` | `{mep: bool, structure: bool, architecture: bool, opacity: 0..1, sectionY: double?, grid: bool?}` | `null`. `sectionY` is a tile-frame height: geometry above it is clipped. `grid` (extra, default true) toggles the grid overlay |
| `setTarget` | `{featureIds: [int] \| null, buildId: String?}` | `null`. Turns on `targetScreen` events (10 Hz) for the union of those features' bounds; `null` clears. Highlighting itself comes from the feature state (alpha 255) |
| `setGridLines` | `{lines: [{name, p0: [x, z], p1: [x, z]}], floorY: double}` | `null`. Orange dash-dot lines on the plane `y = floorY + 1 cm` (tile frame), with a bubble beyond each end; they move with the model. Empty list clears |
| `setPins` | `{pins: [{id, posTile: [x,y,z], label, kind, colorRgb: int?, normalTile: [x,y,z]?}]}` | `null`. `kind` `snag \| finding \| clash \| measure` → a diamond on a stem; `board \| ghostBoard` → an A4 board facing `normalTile` (ghost: translucent). Default colours by kind: snag `#EF4444`, finding `#F59E0B`, clash `#A855F7`, ghostBoard `#38BDF8`, board `#22C55E`, measure `#F1F5F9`. Labels are Flutter's (see `projectTile`) |
| `detectCornerAt` | `{x, y}` | corner map (the `corner` event shape below, without being emitted) or `null`. On `null`, a throttled coaching `error` event says why (`corner-*` codes) |
| `pick` | `{x, y}` | `{featureId: int, buildId: String?, tileHash: String, localIndex: int, hitPointTile: [x,y,z], normalTile: [x,y,z], distanceM: double}` or `null`. Ray against the resident tiles' triangles (C core); hidden features (alpha 0) are see-through; edges (architecture lines) are not pickable; a triangle with no feature id returns `null` |
| `capture` | — | JPEG file path (camera + model, **no Flutter UI**) or `null` |
| `pause` / `resume` | — | `null`. Pause releases the camera; tracking may relocalise on resume |
| `stop` | — | `null`. Ends the session and resets **everything**: tiles unloaded, transform, feature state, layers, target, grid and pins cleared. The next `startSession` is a clean slate |

### Extensions (not in CONTRACT C8)

Additive; a Dart side that doesn't use them loses nothing.

| Method | Arguments | Result |
|---|---|---|
| `projectTile` | `{points: [[x,y,z]]}` tile frame | `[[x, y, onScreen] \| null]` in logical pixels, through the current (eased) model transform. For Flutter-drawn pin labels and grid bubbles |
| `anchorAt` | `{posAr: [x,y,z]}` | anchor id or `null`. A native anchor at a committed corner snap; it then reports `anchor` events like a board's, so Dart refits as the tracker corrects its map (corners had no anchor and the model slid in plain rooms) |
| `installArCore` | — | Android: `true` when Google Play Services for AR is installed after asking. iOS: `false` |

## Events

Maps on `fusioneco/ar/events`. Never per frame.

| `type` | Fields | When |
|---|---|---|
| `tracking` | `state`: `initializing \| tracking \| limited \| paused \| stopped \| notAvailable`; `reason`: `initializing \| excessiveMotion \| insufficientFeatures \| insufficientLight \| relocalizing \| cameraUnavailable \| badState \| interrupted \|` an error code `\| null` | on change |
| `marker` | `rawPayload: String, anchorId: String, centreAr: [3], normalAr: [3], method: lidar\|plane\|depth\|pnp, spreadMm, distanceM, viewAngleDeg, qrEdgeMm: double?` | once per accepted board (below) |
| `corner` | `posAr: [3]` (on the floor), `faceAAr: [nx, nz], faceBAr: [nx, nz]` (unit, both facing the camera, ordered so `a.x*b.z - a.z*b.x >= 0`), `angleDeg` (90 for any square corner), `kind: inside\|outside\|column`, `method: lidar\|planes\|floorTap`; extras `spanA, spanB, rmsM` | returned by `detectCornerAt`; reserved as an event for native-initiated snaps (auto re-snap, AR-46), not emitted yet |
| `anchor` | `anchorId, posAr: [3]` | a marker anchor moved over 1 mm, at most 2 Hz |
| `pose` | `arFromCamera: [16]` (camera looks down its −Z) | 5 Hz while tracking |
| `targetScreen` | `x, y` (logical px), `onScreen: bool` | 10 Hz while a target is set and resident. Behind the camera, `x, y` are mirrored so an edge arrow still points the way to turn |
| `error` | `code, detail` | see codes |
| `floor` | `yAr: double, areaM2: double` | **extension**: the largest tracked upward plane ≥ 0.25 m², 0.8–2.3 m below the camera (Dart ignores it when it disagrees by > 12 cm with the floor the observations imply). At most 1 Hz, only when it moves by 1 cm. Dart fixes the model's height from it (floor on floor); boards and corners then set only yaw and horizontal position |
| `markerProgress` | `rawPayload, samples, needed: 15, distanceM, viewAngleDeg, gate: ok\|tooClose\|tooFar\|angle` | **extension**, only after `startSession({progressEvents: true})`: one per QR sample while a board locks, for the M3 Lock ring and its coaching chips. Dart ignores unknown types, so it's safe either way |

### How a `marker` is accepted (docs/ar-bim-overlay.md §4.2)

1. QR decode (ML Kit / Vision) at ~5 Hz idle, back-to-back while a code is locking.
2. Ray through the QR centre, from the camera pose of the frame it was read in. Hit cascade: **lidar** (iOS scene depth, a plane fitted under the QR) → **plane** (tracked vertical plane) → **depth** (ARCore Depth point / ARKit estimated plane) → **pnp** (the square's own pose, assuming the A4 board's 115 mm QR; Dart doubles its sigma).
3. Gates: tracking, distance 0.5–2.0 m (3.0 m when the measured QR is ≥ 150 mm, an A3 board), view within 35° of square-on.
4. 15 accepted samples → per-axis median centre, normalised mean normal, RMS spread. Spread > 15 mm → `error marker-unstable` ("hold still") and the older half is dropped. Otherwise a native anchor at the median and **one** `marker` event; the same payload is ignored for 4 s. The label is the weakest method among the samples.
5. `qrEdgeMm` (print-scale check) only for depth-measured boards (`lidar`, Android `depth`); `null` otherwise.

Every QR payload is reported raw (asset tags too); Dart decides what is a marker (`MarkerCode.fromScan`).

## Error codes

| Code | Meaning / next step for the UI |
|---|---|
| `device-not-supported` | no ARCore / ARKit world tracking: tier C, floor plan instead |
| `arcore-missing`, `arcore-checking`, `arcore-unknown` | Android: Google Play Services for AR missing, still being checked, or unknown (`installArCore`, or retry) |
| `arcore-install-requested` | the Play Store was opened; call `startSession` again on return |
| `camera-denied` | no camera permission: ask with permission_handler, then retry |
| `camera-unavailable`, `session-failed`, `renderer-failed` | the session or renderer couldn't start; `detail` has the platform message |
| `recording-failed`, `recording-unsupported`, `playback-unsupported` | test recording (AR-4 site walks) |
| `tile-hash-mismatch` | a tile's bytes don't hash to its name (loaded anyway); re-download |
| `tile-upload-failed` | Filament rejected a tile (decode fine, GPU asset not created) |
| `marker-unstable` | "Hold still": the centre moved over 15 mm across the samples |
| `anchor-failed` | the tracker refused an anchor (tracking lost at that moment) |
| `corner-not-tracking` | tracking not ready yet |
| `corner-no-surface` | nothing measured under the pin: "Sweep slowly across both walls" |
| `corner-no-floor` | no floor plane yet: "Point at the floor for a moment" |
| `corner-no-walls` | fewer than two walls tracked and no depth sensor |
| `corner-not-found` | walls and floor known, but no corner under the pin |

## Platform view

- Creation params (Android): `{surface: "texture" | "surface"}`. `texture` (default) renders SceneView into a `TextureView`, which composes under Flutter in every platform-view mode, including the default `AndroidView` (texture-layer hybrid composition). `surface` uses a `SurfaceView` (faster) and then needs **Hybrid Composition** on the Dart side (`PlatformViewLink` + `PlatformViewsService.initExpensiveAndroidView`). Slice 0 (AR-3) measures both.
- iOS takes no params. The view is a `CAMetalLayer` for Filament; if `fe_camera_feed.filamat` isn't bundled, a Core Image `MTKView` draws the camera beneath a transparent Filament layer.
- The view is headless: it never draws text, buttons or permission prompts. Touches belong to Flutter (`pick`, `detectCornerAt`).

## Lifecycle

- Android: the session runs only while `startSession` has been called, Dart hasn't paused, the activity is resumed and the view exists (SceneView pauses ARCore on the view's lifecycle). Backgrounding pauses; returning resumes.
- iOS: `ARSession` runs from `startSession` until `pause`/`stop`; the system interrupts it in the background (`tracking paused interrupted`) and ARKit relocalises on return.
- `stop` resets everything (see Commands). Detaching the plugin (engine teardown) stops the session and frees all native memory.
