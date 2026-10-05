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
| `capabilities` | — | `{supported: bool, depth: bool, lidar: bool, recording: bool, platform: "android"\|"ios", reason: String?}` plus extras `arcore` (Android availability name), `featureMaterial: bool`, `cameraMaterial: bool` (iOS), `torch: bool` (the back camera has a torch `setTorch` can switch; absent = false), `mesh: bool` (iOS LiDAR scene mesh), `scanOverlay: bool` (`setScanOverlay` draws: iOS when `fe_scan.filamat` is bundled, Android always) |
| `startSession` | optional `{depth: bool = true, progressEvents: bool = false, recordTo: path?, playbackFrom: path?}` | `null`. Starts tracking. Android: asks the Play Store for Google Play Services for AR when missing (then emits `error arcore-install-requested`); `recordTo`/`playbackFrom` use ARCore Recording & Playback (MP4); a `playbackFrom` that differs from the previous start rebuilds the ARCore session, and playback keeps the recording's camera config. Keys are sent only when set (debug rig: [docs/ar-recording-playback.md](../../docs/ar-recording-playback.md)). iOS: `recordTo`/`playbackFrom` emit `recording-unsupported` / `playback-unsupported` |
| `loadTiles` | `{tiles: [{hash: String, path: String}]}` | `{loaded: [hash], failed: [{hash, reason}]}` once every tile is decoded. Tiles upload **in the order sent** (send focus tiles first). The file's SHA-256 is compared with `hash`; a mismatch loads anyway and emits `error tile-hash-mismatch` |
| `unloadTiles` | `{hashes: [String]}` | `null` |
| `setModelTransform` | `{arFromTile: [16], easeMs: int = 300}` (`matrix` accepted as an alias) | `null`. Eases over `easeMs` (yaw along the shortest arc, translation linearly, smoothstep); `easeMs <= 0` or a non-4-DoF matrix applies at once. Native never computes a transform. **Until the first call after `startSession`/`stop`, the model (tiles, grid, pins) is loaded but hidden**, and the first call applies at once: the identity root would put the model at the session origin |
| `setFeatureState` | `{rgba: Uint8List, width: int, buildId: String?}` | `null`. One RGBA8 texel per feature id, row-major, `width` per row (`feature_state.dart`). **RGB** tint, `0,0,0` = none. **A** = display mode `round(a / 85)`: 0 hidden · 1 ghost · 2 normal · 3 highlight (drawn through walls, outlined, pulsing). Optional `buildId` scopes the texture to one build (feature ids are dense *per build*); without it the texture applies to every build that has no texture of its own |
| `setLayers` | `{mep: bool, structure: bool, architecture: bool, opacity: 0..1, sectionY: double?, grid: bool?}` | `null`. `sectionY` is a tile-frame height: geometry above it is clipped. `grid` (extra, default true) toggles the grid overlay; `contrast` (extra, default false) is Sunlight mode: opaque MEP, white architecture edges, stronger structure |
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
| `refocus` | — | `bool`. Restarts autofocus (FIXED→AUTO on Android, autofocus off→on on iOS); there is no focus-at-point on either platform |
| `setDepth` | `{on: bool}` | `bool`. Depth sensing (and on iOS the scene mesh) on or off; Dart turns it off once placed and on for setup (power) |
| `installArCore` | — | Android: `true` when Google Play Services for AR is installed after asking. iOS: `false` |
| `pickMany` | `{points: [[x, y], …]}` logical px | `[pick map \| null, …]`, one per point, in order (the `pick` result shape). For the lasso (one call instead of ~120). Dart falls back to sequential `pick` when the method is missing |
| `depthPointAt` | `{x, y}` logical px | `{posAr: [3], normalAr: [3] \| null, confidence: 0..1, method: "rawDepth" \| "plane" \| "depth"}` or `null`; extras `samples: int`, `distanceM`. The measured surface point under the screen point, for Dart's wall-taps corner and long-baseline tap. Cascade: **rawDepth** (Android: `acquireRawDepthImage16Bits` + `acquireRawDepthConfidenceImage` in a 9×9 window; pixels with confidence ≥ 128/255 within 3 % (min 30 mm) of the window's median; point = ray through the exact pixel at the median depth; `confidence` = kept share × mean confidence) → **plane** (tracked plane hit, 0.9) → **depth** (smoothed depth image, same window, ≤ 0.5). `normalAr` is the kept pixels' plane normal (smallest principal axis, only when the patch is flat), facing the camera. iOS mirror: LiDAR `sceneDepth` + `confidenceMap` (`rawDepth`), raycast to an estimated/existing plane (`plane`); `null` when neither |
| `setTorch` | `{on: bool}` | `bool`: applied now. Android: `Config.FlashMode.TORCH`/`OFF` through `session.configure` (kept across SceneView reconfigures; off during playback; reset by `startSession`/`stop`). Error `torch-failed` if ARCore refuses |
| `startRecording` | `{path: String}` | `bool`. Records the running session to an MP4 (ARCore Recording & Playback, auto-stops on pause); before a session exists it starts when one resumes. Debug rig only. iOS: `false` |
| `stopRecording` | — | the MP4's path, or `null` when nothing was recording. `stop` also finishes a recording |
| `setScanOverlay` | `{on: bool, contrast: bool = false}` | `bool`: the overlay can draw. The room-scan overlay for setup. **iOS:** with LiDAR (scene reconstruction), the live `ARMeshAnchor` mesh as unshared triangles tinted by face classification (wall cyan, floor green, ceiling violet, door amber, window blue, furniture pink, unclassified slate), a thin glowing wireframe that paints in as ARKit reports each surface, with a band sweeping out from the camera every ~2 s (`materials/fe_scan.mat`); without LiDAR the tracked planes as a world-space 25 cm grid. Uploads at most 5 Hz, ≤ 6 changed anchors a tick, ≤ 120k faces. Fades in 0.4 s / out 0.8 s; the scene mesh keeps running until the fade ends. `contrast` = Sunlight look. **Android:** SceneView's plane grid on the tracked planes. Off after `stop`. Also starts `scan` events |
| `pulseAt` | `{posAr: [3], normalAr: [3]?, tone: "ok" \| "warn" \| "info"}` | `bool`. **iOS:** two expanding rings (1.2 s, 0.35 s apart) in the plane facing `normalAr` (default up), green / amber / blue; drawn over everything, then removed. **Android:** not implemented (`notImplemented`; Dart answers `false`) |

## Events

Maps on `fusioneco/ar/events`. Never per frame.

| `type` | Fields | When |
|---|---|---|
| `tracking` | `state`: `initializing \| tracking \| limited \| paused \| stopped \| notAvailable`; `reason`: `initializing \| excessiveMotion \| insufficientFeatures \| insufficientLight \| relocalizing \| cameraUnavailable \| badState \| interrupted \|` an error code `\| null` | on change |
| `marker` | `rawPayload: String, anchorId: String, centreAr: [3], normalAr: [3], method: tag\|lidar\|plane\|depth\|pnp, spreadMm, distanceM, viewAngleDeg, qrEdgeMm: double?`; extension `surfaceResidualMm: double?` (below) | once per accepted board (below) |
| `corner` | `posAr: [3]` (on the floor), `faceAAr: [nx, nz], faceBAr: [nx, nz]` (unit, both facing the camera, ordered so `a.x*b.z - a.z*b.x >= 0`), `angleDeg` (90 for any square corner), `kind: inside\|outside\|column`, `method: lidar\|planes\|floorTap`; extras `spanA, spanB, rmsM`. (Dart also builds corners with `method: depthTaps` from `depthPointAt` wall taps, `lib/core/ar/wall_fit.dart`; never on the wire) | returned by `detectCornerAt`; reserved as an event for native-initiated snaps (auto re-snap, AR-46), not emitted yet |
| `anchor` | `anchorId, posAr: [3]` | a marker anchor moved over 1 mm, at most 2 Hz |
| `pose` | `arFromCamera: [16]` (camera looks down its −Z; display-oriented on both: Android `displayOrientedPose`, iOS `viewMatrix(for: interfaceOrientation)⁻¹`) | 5 Hz while tracking |
| `targetScreen` | `x, y` (logical px), `onScreen: bool` | 10 Hz while a target is set and resident. Behind the camera, `x, y` are mirrored so an edge arrow still points the way to turn |
| `error` | `code, detail` | see codes |
| `floor` | `yAr: double, areaM2: double` | **extension**: the largest tracked upward plane ≥ 0.25 m², 0.8–2.3 m below the camera (Dart ignores it when it disagrees by > 12 cm with the floor the observations imply). At most 1 Hz, only when it moves by 1 cm. Dart fixes the model's height from it (floor on floor); boards and corners then set only yaw and horizontal position |
| `thermal` | `status: int, level: none\|light\|moderate\|severe\|critical\|emergency\|shutdown` | **extension**: Android PowerManager thermal status (API 29+), iOS ProcessInfo thermal state mapped onto it (nominal → none, fair → light, serious → moderate, critical → critical: an iPhone running LiDAR reaches `serious` in normal use); Dart pauses AR at `severe`+ |
| `scan` | `source: mesh\|planes, surfaces, walls, floors, floorM2, wallM2, ceilingM2, otherM2` | **extension**, while `setScanOverlay(on)`: what the room scan has found, at most 1 Hz and only when it changed. `walls`/`floors` count tracked planes; the areas come from the classified LiDAR mesh (`source: mesh`) or from plane extents. Dart: `lib/core/ar/scan_overlay.dart` (`ScanProgress`) |
| `markerProgress` | `rawPayload, samples, needed: 15 (20 while locking on tags), distanceM, viewAngleDeg, gate: ok\|tooClose\|tooFar\|angle` | **extension**, only after `startSession({progressEvents: true})`: one per QR sample while a board locks, for the M3 Lock ring and its coaching chips. Dart ignores unknown types, so it's safe either way |

### How a `marker` is accepted (docs/ar-bim-overlay.md §4.2)

1. QR decode (ML Kit / Vision) at ~5 Hz idle, back-to-back while a code is locking. The QR identifies the board; the rest of this list is about its pose.
2. **tag** (boards printed from 2026-09-27; Android now, iOS later). The same camera image's Y plane is searched, in a region around the QR, for the board's four AprilTag tag36h11 fiducials (one per frame corner: A4 22 mm at ±71.25 mm from the QR centre, A3 32 mm at ±105 mm; ids in [src/fe_tag.h](src/fe_tag.h)). A tag counts only when its id is in the payload's group **and** it sits at one of that QR's frame corners in the image, so a shared group between two boards is harmless. With **2 or more** of them, a planar PnP over their corners (the C core: homography, both planar solutions refined by Levenberg–Marquardt, reprojection RMS ≤ 1.5 px) gives the board centre and normal in camera space, moved to world space by that frame's camera pose. Tag samples are kept apart from QR samples.
3. Otherwise, a ray through the QR centre, from the camera pose of the frame it was read in. Hit cascade: **lidar** (iOS scene depth, a plane fitted under the QR) → **plane** (tracked vertical plane) → **depth** (ARCore Depth point / ARKit estimated plane) → **pnp** (the square's own pose, assuming the A4 board's 115 mm QR; Dart doubles its sigma).
4. Gates: tracking, distance 0.5–2.0 m (3.0 m when the measured QR is ≥ 150 mm, an A3 board), view within 35° of square-on. Tag samples: 0.3–2.0 m (3.0 m for an A3 board, known from the tag ids), within 40°.
5. QR samples: 15 accepted → per-axis median centre, normalised mean normal, RMS spread; spread > 15 mm → `error marker-unstable` ("hold still") and the older half is dropped. Tag samples: **20 accepted** (a window of the latest 30) → the same statistics, spread gate **10 mm**. Either way, a native anchor at the median and **one** `marker` event; the same payload is ignored for 4 s. The label is the weakest method among the samples; a tag lock is all `tag`.
6. `qrEdgeMm` (print-scale check) only for depth-measured boards (`lidar`, Android `depth`, and `tag` when an ARCore Depth point lies on the tag-centre ray: nominal QR edge × ARCore distance ÷ tag distance); `null` otherwise.
7. A tag pose trusts the printed size. When ARCore also measures the wall on the tag-centre ray (plane or depth), the ratio is the print scale; if its median over the lock is off by more than **4 %**, that board's tags are ignored for the rest of the session and it locks by step 3 (no event; the QR path's own `qrEdgeMm` then reports the scale where it can).

Every QR payload is reported raw (asset tags too); Dart decides what is a marker (`MarkerCode.fromScan`). Boards without tags (printed before 2026-09-27, or with `tags: false`) lock exactly as before.

### Method and sigma (for the Methods / sigma note, CONTRACT C2)

| `method` | Centre from | Expected σ of the observed centre | Dart `ArSigma.forMarker` (proposal) |
|---|---|---|---|
| `tag` | AprilTag PnP, 16 corners over ~150 mm, median of 20–30 frames | ~2–5 mm at 0.3–1.5 m (synthetic 1080p: ≤ 0.5 mm per frame noise-free; real blur and intrinsics dominate) | `max(surveyed, class × 0.7)`: better than `plane`, never better than a surveyed board's own position |
| `lidar` | iOS LiDAR plane under the QR | ~5 mm | class σ |
| `plane` | tracked vertical plane | ~1–2 cm | class σ |
| `depth` | ARCore Depth point | ~1–3 cm | class σ |
| `pnp` | QR corners only (A4 assumed) | several cm | class σ × 2 |

### LiDAR surface check (`surfaceResidualMm`, iOS)

On LiDAR devices the accepted board's centre, and each corner `detectCornerAt` returns, are checked against the depth sensor (`FeArDepthProbe.surfaceResidual`): the point is projected into the current frame's `smoothedSceneDepth` (else `sceneDepth`), and the median of the medium/high-confidence pixels in a 5×5 window is compared with the point's own depth along the view ray. `surfaceResidualMm` = measured − expected (+ = the real surface is behind the point). Corners are checked on the corner line 0.4, 0.9 and 1.4 m above the floor (median; outside corners and columns read the nearest pixel, the edge, not the wall behind it). Absent or `null` without LiDAR depth (Android, non-LiDAR iPhones, depth switched off). Dart: within 30 mm = `ok` (green ring), beyond = `warn` (amber ring and a "re-snap" hint), none = `info` (`SurfaceCheck`). It never changes the fit or the σ.

## Error codes

| Code | Meaning / next step for the UI |
|---|---|
| `device-not-supported` | no ARCore / ARKit world tracking: tier C, floor plan instead |
| `arcore-missing`, `arcore-checking`, `arcore-unknown` | Android: Google Play Services for AR missing, still being checked, or unknown (`installArCore`, or retry) |
| `arcore-install-requested` | the Play Store was opened; call `startSession` again on return |
| `camera-denied` | no camera permission: ask with permission_handler, then retry |
| `camera-unavailable`, `session-failed`, `renderer-failed` | the session or renderer couldn't start; `detail` has the platform message |
| `recording-failed`, `recording-unsupported`, `playback-unsupported` | test recording (AR-4 site walks; debug rig) |
| `torch-failed` | `setTorch` could not reconfigure the session |
| `tile-hash-mismatch` | a tile's bytes don't hash to its name (loaded anyway); re-download |
| `tile-upload-failed` | Filament rejected a tile (decode fine, GPU asset not created) |
| `marker-unstable` | "Hold still": the centre moved over 15 mm across the samples |
| `anchor-failed` | the tracker refused an anchor (tracking lost at that moment) |
| `corner-not-tracking` | tracking not ready yet |
| `corner-no-surface` | nothing measured under the pin: "Sweep slowly across both walls" |
| `corner-no-floor` | no floor plane yet: "Point at the floor for a moment" |
| `corner-no-walls` | fewer than two walls tracked and depth (if any) found no corner either: plain painted walls. Dart offers wall taps (`depthPointAt`). Sent with or without depth since 2026-09-27 (before, only without depth, so depth phones only ever heard `corner-not-found`) |
| `corner-not-found` | walls and floor known, but no corner under the pin |

## Platform view

- Creation params (Android): `{surface: "texture" | "surface"}`. `texture` (default) renders SceneView into a `TextureView`, which composes under Flutter in every platform-view mode, including the default `AndroidView` (texture-layer hybrid composition). `surface` uses a `SurfaceView` (faster) and then needs **Hybrid Composition** on the Dart side (`PlatformViewLink` + `PlatformViewsService.initExpensiveAndroidView`). Slice 0 (AR-3) measures both.
- iOS takes no params. The view is a `CAMetalLayer` for Filament; if `fe_camera_feed.filamat` isn't bundled, a Core Image `MTKView` draws the camera beneath a transparent Filament layer.
- The view is headless: it never draws text, buttons or permission prompts. Touches belong to Flutter (`pick`, `detectCornerAt`).

## Lifecycle

- Android: the session runs only while `startSession` has been called, Dart hasn't paused, the activity is resumed and the view exists (SceneView pauses ARCore on the view's lifecycle). Backgrounding pauses; returning resumes.
- iOS: `ARSession` runs from `startSession` until `pause`/`stop`; the system interrupts it in the background (`tracking paused interrupted`) and ARKit relocalises on return.
- `stop` resets everything (see Commands). Detaching the plugin (engine teardown) stops the session and frees all native memory.
