# Pending

Work this repo still owes: unfinished, partly done, blocked, or built but never verified. Companion to [LEARNINGS.md](LEARNINGS.md). LEARNINGS records what we learned and only grows. This file is a live list: items leave it when they are done.

**The 2026-09-25 audit findings stay in [docs/improvements.md](docs/improvements.md)** with their own `#` numbers. Don't copy them here; mark them done there when fixed. This file holds everything else: session leftovers, deferred work, things not verified.

- **Add** an item before ending any turn that leaves work owed. Take the number from "Next number" below and bump it. Never reuse a number.
- **Close** an item by moving it to Closed as one line: date, how it was resolved, and its LEARNINGS entry.
- **Status:** `not started` · `partial` · `blocked` · `needs verification` (built, but `flutter analyze`/`flutter test` on Flutter ≥ 3.44 or a device run not done)
- **Priority:** P1 loses field work or shows the technician something false · P2 real feature gap · P3 cleanup
- **Cross-repo:** the item lives in the repo that owns the fix. The other repo gets a one-line pointer.
- **Sweep and re-verify everything:** run `/pending-sweep` from the workspace root.

<!-- Entry template
### P-000 · <one-line title>
- **Status:** not started · **Priority:** P2 · **Area:** <module>
- **Found:** YYYY-MM-DD (<source: LEARNINGS entry, doc, session>)
- **Done so far:** <what exists already, or —>
- **Left:** <what is still owed>
- **Why deferred:** <out of scope / blocked on X / needs decision>
- **Where:** <path:line, path:line>
- **Next step:** <the first concrete action>
-->

Next number: **P-013**

## Open

### P-012 · AR overlay renders but is not registered to the room
- **Status:** not started · **Priority:** P1 · **Area:** AR alignment (Dart fit ↔ fe_ar)
- **Found:** 2026-09-26 (first Android device run, demo bedroom model)
- **Done so far:** fe_ar builds and runs on Android: camera, ARCore tracking and Filament drawing the downloaded tiles all work.
- **Left:** the model appears at an arbitrary place in the camera view instead of on the room. Trace the chain board detection (QR pose from `MarkerDetector`) → observation → Dart 4-DoF fit → `setModelTransform` → Filament root transform: frames (ARCore world Y-up vs tile frame), the marker pose convention (normal, up), board size/physical scale, and whether a transform is applied before the first lock.
- **Where:** `packages/fe_ar/android/src/main/kotlin/com/fusionapps/fe_ar/` (`MarkerDetector.kt`, `FeArController.kt`, `TileRenderer.kt`), `lib/core/ar/`, `lib/state/ar_session_controller.dart`
- **Next step:** log the marker observation and the applied transform on device while scanning one board of the demo bedroom, compare with the board's `posTile`/normal from the web plan.

### P-011 · Model viewer (2D/3D): Dart side never analyzed, tested or run on a device
- **Status:** needs verification · **Priority:** P2 · **Area:** model viewer (`lib/core/bim_viewer`, `lib/features/bim_viewer`, `lib/state/bim_viewer_*`, `assets/bim_viewer`, viewer scope in `ar_repository.dart` / `offline_db.dart`)
- **Found:** 2026-09-26 (V1 build; the user said not to test this pass)
- **Done so far:** the viewer page ran in headless Chromium against real server-built tiles, 22/22 checks (`tool/bim_viewer/e2e.mjs`); `viewer_math.js` 11/11 (`node --test tool/bim_viewer/viewer_math.test.mjs`); server side 325/325 vitest. The Dart tests are written: `test/bim_view_wire_test.dart`, `bim_plan_view_math_test.dart`, `viewer_asset_server_test.dart`, `bim_viewer_controller_test.dart`, `bim_viewer_screen_test.dart`, and the viewer group in `ar_repository_test.dart` (its memory store is now scope-aware).
- **Left:** `flutter pub get --enforce-lockfile`, `flutter analyze`, `flutter test test/bim_* test/viewer_asset_server_test.dart test/ar_repository_test.dart` on ≥ 3.44, then fix what they report. On a device: Android WebView (WebGL2, `EagerGestureRecognizer` over split view, loopback cleartext) and iOS WKWebView; frame rate on a large floor (60+ tiles); walk joystick in RTL; a Demo-mode walk-through. The server's `?layers=` needs a DB where `applyArGeometryTables.ts --apply` has run, plus a rebuild (server P-030).
- **Why deferred:** the user asked for no testing this pass; no device on this Mac.
- **Where:** [docs/bim-viewer.md §8](docs/bim-viewer.md#8-verification-be-honest)
- **Next step:** bootstrap the slim 3.47.5 SDK (LEARNINGS → Platform) and run analyze plus the test files above.

### P-004 · AR (FieldOps): never analyzed or tested on Flutter ≥ 3.44, never run on a device
- **Status:** needs verification · **Priority:** P2 · **Area:** AR (`lib/core/ar`, `lib/state/ar_*`, `lib/features/ar`, `lib/data/ar_repository.dart`, OfflineDb v10)
- **Found:** 2026-09-26 (AR v1 build + fieldops-verify)
- **Done so far:** type check of all of `lib/` and `test/ar_*` on the Flutter **3.19** analyzer over a scratch copy, clean apart from known old-toolchain noise; 193 pure-Dart AR tests pass on Dart 3.3.1 (LEARNINGS → Platform, "No-download type check"); i18n script shows 528 `ar.*` keys in both files; channel keys cross-read against Kotlin/Swift. See [docs/ar-implementation.md §9](docs/ar-implementation.md#9-verification-status-be-honest).
- **Left:** `flutter pub get --enforce-lockfile`, `flutter analyze`, `flutter test test/ar_*_test.dart` on ≥ 3.44 (the `ChannelArEngine` group has never run); v9 → v10 migration on a device with a populated DB; Demo mode walked at runtime on a phone (360 px) and a tablet (≥ 900 px), in EN and AR (RTL rails); `LiveArGateway` → `ArRepository` against a server (ETag/304, tile bytes, auth on the raw Dio client, queued replays).
- **Why deferred:** no Flutter ≥ 3.44, device or emulator on this Mac this session; downloads were not allowed.
- **Where:** [docs/ar-implementation.md](docs/ar-implementation.md)
- **Next step:** bootstrap the slim 3.47.5 SDK (LEARNINGS → Platform) and run the three commands; fix what flutter_lints 6 reports.

### P-005 · `packages/fe_ar` native plugin: slice 0 (build it on devices)
- **Status:** in progress · **Priority:** P2 · **Area:** AR native (`packages/fe_ar`)
- **Found:** 2026-09-26 (fe_ar build)
- **Done so far:** path dependency added; app and plugin compile against API 37 (`android-37.0`); Android build runs on a OnePlus 7 Pro with camera, ARCore and Filament rendering (two device crashes fixed, see LEARNINGS "fe_ar first device build"). The C core passes 131 checks under ASan/UBSan.
- **Left:** overlay registration (P-012); compile `materials/*.mat` with matc 1.72.1 and commit the `.filamat` outputs; resolve the remaining `TODO(slice-0)` markers; iOS build on a LiDAR iPad (CocoaPods, Filament pod); extend `NSCameraUsageDescription`; revisit the portrait lock for tablet AR; measure QR lock time and the performance budgets.
- **Where:** [packages/fe_ar/README.md](packages/fe_ar/README.md), [CHANNEL.md](packages/fe_ar/CHANNEL.md)
- **Next step:** P-012, then materials.

### P-006 · AR hand-offs don't carry the AR context into Verify and Snags
- **Status:** not started · **Priority:** P2 · **Area:** AR ↔ field verification / Snag Assistant
- **Found:** 2026-09-26 (fieldops-ui)
- **Done so far:** the Verify mode sends `ar*` query params (`arCheck`, `arOffsetM`, `arToleranceM`, `arTagMatches`, `arBuildId`, `arGlobalId`, `arFeatureId`, `arFitMethod`, `arMaxResidualMm`, `arQuality`, `arMapping`, `arPhoto`) to `/verify/:assetId`; the Snags mode opens `Routes.snagNew` with asset, floor, building and work order.
- **Left:** the `/verify` route builder and `FieldVerificationScreen` must read those params and submit them as `arContext` (docs/ar-bim-overlay.md §8); `Routes.snagNew`/`SnagRaiseScreen` should accept the element GlobalId, the AR capture photo path and the camera pose (AR-47).
- **Why deferred:** those screens were outside the AR build's file ownership.
- **Where:** [ar_mode_panel.dart](lib/features/ar/workspace/ar_mode_panel.dart), [router.dart](lib/app/router.dart) `/verify/:assetId`, `lib/features/field_verification/field_verification_screen.dart`
- **Next step:** parse the `ar*` params in the `/verify` builder and pre-fill the form's location check.

### P-007 · AR entry points are not gated by `isArView` / `isArInstall`
- **Status:** not started · **Priority:** P2 · **Area:** AR / permissions
- **Found:** 2026-09-26 (fieldops-ui)
- **Done so far:** the server's settings schema has `isArView` (default **on**) and `isArInstall` (default **off**) (`../fusion-eco-server/src/common/redis.ts`). The app reads neither.
- **Left:** add both to `Permissions` (`session_store.dart`, `auth_repository.fetchPermissions`); hide `ArDashboardCard` and "Show in AR" when `isArView == false`; gate the install list, the dashboard install tile and spare binding on `isArInstall` (ar-markers-and-qr.md §3.3 open decision 3). Check `GET /api/auth/config` actually returns them.
- **Why deferred:** `session_store.dart` wasn't in the AR build's ownership.
- **Where:** [ar_entry_widgets.dart](lib/features/ar/widgets/ar_entry_widgets.dart), `lib/core/storage/session_store.dart`
- **Next step:** confirm the auth-config payload, then add the two flags like `isDigitalTwin`.

### P-008 · AR offline gaps: spares, queued four-eyes rejections, tile GC, building name, ghost-spot clearance
- **Status:** partial · **Priority:** P1 for (2), P2 for the rest · **Area:** AR data (`ar_repository.dart`, `ar_gateway_live.dart`)
- **Found:** 2026-09-26 (fieldops-core, fieldops-ui)
- **Done so far:** local-first resolve, ETag manifests, verified tile store, queued writes with rollback on online rejection.
- **Left:**
  - (1) the manifest carries no spare codes (C5 `ManifestMarker` excludes spares), so a spare scanned offline and outside a locked session resolves as `NEEDS_SIGNAL`; either add the building's spare codes to the manifest (server) or keep treating a valid unknown code as "New board" while locked.
  - (2) a queued `setProgress` replays inside a 200 whose `rejected[]` (four-eyes) the phone never sees. The local row shows the refused status (e.g. "verified") until the next `fetchProgress` after the queue drains, which then lets the server copy win. Call `fetchProgress` when the queue flushes an `ArProgress` entity, and tell the user what was refused.
  - (3) `gcTiles` (1 GB cap) is never triggered; call it after downloads or from a storage screen.
  - (4) no `ArRepository.buildingName(buildingId)`, so the install-list eyebrow and M2 subtitle can be blank before a board resolve.
  - (5) the live `GhostSpotFinder` call gets no `FloorPlan`, so door and equipment clearance isn't applied.
- **Why deferred:** contract gaps found while building in parallel.
- **Where:** [ar_repository.dart](lib/data/ar_repository.dart), [ar_gateway_live.dart](lib/state/ar_gateway_live.dart)
- **Next step:** (2) first: it can show a technician a "verified" the server refused.

### P-009 · AR tests owed, and one sample dataset for Demo mode
- **Status:** not started · **Priority:** P3 · **Area:** AR tests
- **Found:** 2026-09-26 (fieldops-ui, fieldops-verify)
- **Done so far:** 13 pure test files for `lib/core/ar`, the models and the repository.
- **Left:** tests for `ArSetupController` (corner A/B match, ambiguity, too close, board lock, register), `ArWorkspaceController` (four-eyes blockers, lasso sampling, **per-build feature state**, measure), `ArInstallController`, `DemoArGateway`/`LiveArGateway` mapping (fake `ArRepository` via `withSeams`), widget smoke tests of every AR route at 360 px and ≥ 900 px in EN and AR. Merge `ArDemoScenario` (core) and `DemoArGateway` (UI) into one sample floor so the fake's scripted story and the screens agree.
- **Why deferred:** no Flutter ≥ 3.44 to run widget tests.
- **Where:** `test/`, [fake_ar_engine.dart](lib/core/ar/fake_ar_engine.dart), [ar_demo_gateway.dart](lib/state/ar_demo_gateway.dart)
- **Next step:** controller tests with `FakeArEngine` + `DemoArGateway` (both pure).

### P-010 · AR extras not wired yet
- **Status:** not started · **Priority:** P3 · **Area:** AR UX
- **Found:** 2026-09-26 (fieldops-ui, fe_ar)
- **Done so far:** shown disabled with "Coming in a later update" where they appear in the UI.
- **Left:** torch (needs `setTorch` in C8 + fe_ar); a batched `pickMany` for lasso (today up to ~120 sequential `pick` calls); `startSession({progressEvents: true})` + `markerProgress` events to drive the M3 lock ring from real samples; `projectTile` for Flutter-drawn pin labels and grid bubbles; Android App Links / iOS universal links for `/m/<code>` so a phone-camera scan opens the app instead of the web landing; Save view (AR-61) and Share view (AR-52); a Phase filter (needs phase data).
- **Why deferred:** outside v1 scope or needing a contract change.
- **Where:** [ar_menu_panel.dart](lib/features/ar/workspace/ar_menu_panel.dart), [ar_session_controller.dart](lib/state/ar_session_controller.dart), [CHANNEL.md](packages/fe_ar/CHANNEL.md)
- **Next step:** `progressEvents` (no contract change: fe_ar already emits it).


### P-003 · Three existing tests fail on unmodified HEAD
- **Status:** not started · **Priority:** P3 · **Area:** tests
- **Found:** 2026-09-26 (first real `flutter test` run on Flutter 3.47.5; reproduced on a `git archive HEAD` copy)
- **Done so far:** reproduced on unmodified HEAD, so these failures come from the existing code, not from the Snag Assistant.
- **Left:**
  - (1) `dates_test` "isOverdueDate ignores earlier today" fails when run just after midnight, so it depends on the clock.
  - (2) `qr_payload_test` "one of our own public pages is offered as a record" fails and needs a look at its `Env.webBaseUrl` assumption.
  - (3) every `order_detail_test` "per-type headings" case hangs until its 10-minute timeout inside `_localizedContext` (`FlutterLocalization.ensureInitialized()` with no `SharedPreferences.setMockInitialValues`). This alone adds about 40 minutes to a full run.
- **Why deferred:** outside the Snag Assistant's scope.
- **Where:** [test/dates_test.dart](test/dates_test.dart), [test/qr_payload_test.dart](test/qr_payload_test.dart), [test/order_detail_test.dart:25](test/order_detail_test.dart#L25)
- **Next step:** add `SharedPreferences.setMockInitialValues({})` to `_localizedContext` and re-run (3). Pin a fixed `now` in (1).

### P-001 · Snag Assistant: never run on a device
- **Status:** needs verification · **Priority:** P2 · **Area:** Snag Assistant (`lib/features/snags/`)
- **Found:** 2026-09-26 (Snag Assistant build)
- **Done so far:** the full module, shown in [docs/snag-assistant.md](docs/snag-assistant.md). `dart analyze` is clean, and `flutter test` passes for the 39 snag tests (rules, model, widgets, and hub/detail/survey screens in EN and AR at 360 px). Both ran on Flutter 3.47.5, bootstrapped into the session scratchpad (LEARNINGS → Platform).
- **Left:** a device run of walk mode (live `CameraController` across 30+ shots, torch, backgrounding), the ghost camera, voice notes, the room picker on a real building tree, and offline → online replay of a full walk against a server with `findings:promote` applied. Walk, raise, verify and ghost-camera screens have no widget tests, because they need the camera plugin.
- **Why deferred:** there is no Android device or emulator on this Mac, and the server migration is not applied (server PENDING P-010).
- **Where:** [snag_walk_screen.dart](lib/features/snags/snag_walk_screen.dart), [ghost_camera_screen.dart](lib/features/snags/ghost_camera_screen.dart), [snag_repository.dart](lib/data/snag_repository.dart)
- **Next step:** apply server P-010, then run a 20-snag walk in airplane mode, go online, and check the Sync Center drains and the hub loses its "On device" badges.

### P-002 · Snag Assistant: logout wipes unsynced snags, like the queue
- **Status:** not started · **Priority:** P1 · **Area:** Snag Assistant / offline
- **Found:** 2026-09-26 (Snag Assistant build)
- **Done so far:** `OfflineDb.wipe()` clears `snags` and `snag_surveys` together with the queue, which is consistent with improvements.md's queue-wipe P1.
- **Left:** fix together with that P1. A surveyor whose 24h session expires mid-walk loses every snag not yet synced (the photo files under `snag_media/own/` survive, but nothing points at them).
- **Why deferred:** the fix belongs to the platform-wide queue-wipe item, not to this module.
- **Where:** [offline_db.dart](lib/core/offline/offline_db.dart) `wipe()`
- **Next step:** when improvements.md's logout P1 is fixed, keep `local_only=1` snag rows and their surveys through a re-login by the same user.


## Closed

_None yet._
