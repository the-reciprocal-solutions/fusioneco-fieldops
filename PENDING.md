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

Next number: **P-014**

## Open

### P-013 · Permit to Work (PTW): never run on a device, no live API run
- **Status:** needs verification · **Priority:** P2 · **Area:** Permit to Work (`lib/domain/permit.dart`, `lib/core/permit/permit_gas.dart`, `lib/data/permit_repository.dart`, `lib/state/permit_controller.dart`, `lib/features/permits/**`)
- **Found:** 2026-09-26 (PTW wiring, tests and docs pass); analyze/test run added 2026-09-27
- **Done so far:** notification/push routing fixed to match the server's actual `entityType: "PermitToWork"` stamp (both `core/utils/notification_route.dart` and `_routeForPushData` in `core/push/push_service.dart`, keeping the plain `'Permit'` spelling too); the scanner's `/permit-check/<token>` handling (`scanner_screen.dart`, `permitCheckTokenFromScan` in `core/permit/permit_gas.dart`) was already wired in ahead of this pass. Pure-Dart tests written: `test/permit_model_test.dart`, `test/permit_gas_test.dart`, `test/permit_routes_test.dart` (47 tests total). `docs/permit-to-work.md` written. **2026-09-27:** the slim Flutter 3.47.5 SDK was bootstrapped into the session scratchpad (disk allowed it this time, ~11 GB free) and this is a **real Flutter ≥ 3.44 run**: `flutter pub get --enforce-lockfile` (lockfile unchanged), `flutter analyze` (0 errors anywhere in the project; only pre-existing infos/warnings in unrelated files remain — `lib/features/permits/**`, `lib/domain/permit.dart`, `lib/core/permit/**`, `lib/data/permit_repository.dart`, `lib/state/permit_controller.dart`, `lib/theme/fe_permit_colors.dart` and the router/push/notification/scanner edits all have zero errors and zero warnings), `flutter test test/permit_model_test.dart test/permit_gas_test.dart test/permit_routes_test.dart` (47/47 pass). Getting there also required fixing: one real warning (`permits_hub_screen.dart`'s unused `permit_visuals.dart` import) and two test bugs of my own (a timezone-dependent assertion in `permit_model_test.dart`, and a `listFromJson` call shaped like a full nested envelope rather than the bare items list `PermitRepository.mine` actually passes it) — and, incidentally, two compile-blocking bugs in the unrelated `bim_viewer` module that were blocking `flutter analyze`/`test` project-wide (see P-011).
- **Left:** a device run of every screen and sheet (hub, detail, resolve, sign-on, gas test, isolation, stop-work) in EN and AR; a real server round trip for every write in §4 of the doc, including the offline-queue path and the inline-data-URL signature/photo encoding; widget tests for the screens/sheets themselves (only the pure model/gas/route logic has tests so far — `permit_detail_screen.dart` and the sheets have none); confirming `GET /api/auth/config` gates PTW visibility if/when the server adds one (none exists yet, so the module is unconditionally visible).
- **Why deferred:** no device, emulator, or reachable server in this session.
- **Where:** [docs/permit-to-work.md §6](docs/permit-to-work.md#6-verification-be-honest)
- **Next step:** widget tests for the hub/detail/sheets, then a device run.

### P-012 · AR overlay renders but is not registered to the room
- **Status:** in progress · **Priority:** P1 · **Area:** AR alignment (Dart fit ↔ fe_ar)
- **Found:** 2026-09-26 (first Android device run, demo bedroom model)
- **Diagnosis:** the Dart fit and native maths agree (same yaw sign, column-major, board normals face the room on both sides). The "random" position was the model drawn **before any fit**: tiles loaded on download, native root at identity = the session origin. Accuracy limits after a lock: one board's yaw comes from a noisy wall normal (5° ≈ 26 cm at 3 m), height came from board centres, boards are placed from the plan not measured, PnP assumes a 115 mm QR.
- **Done (2026-09-26, Android):** model hidden until the first `setModelTransform`; native `floor` event + floor-anchored height in `AlignmentEstimator.fit` (horizontal residuals, `verticalErrorsM`); green needs ≥ 2 references ≥ 1.5 m apart agreeing within 2 cm (`greenResidualM`), else amber with "add a corner or a 2nd board"; `[ar-fit]` debug log per refit (`adb logcat -s flutter`).
- **Left:** device check in the demo room with the log; iOS mirror of the hide-until-placed rule and the `floor` event (`ios/Classes/FeArController.swift`); a print-size check for PnP-only boards; make "corners first, then leave a board" the default setup path for rooms without surveyed boards.
- **Where:** `packages/fe_ar/android/src/main/kotlin/com/fusionapps/fe_ar/` (`FeArController.kt`, `TileRenderer.kt`), `lib/core/ar/alignment_estimator.dart`, `lib/state/ar_session_controller.dart`
- **Also done (2026-09-26, later):** corner snaps get an ARCore anchor (`anchorAt`), sticky largest floor plane + 12 cm agreement gate, inside corners ranked first and shape-checked on the first snap, corner plan shown on phones, camera config by largest GPU texture (1920×1080), `fe_feature.filamat` compiled (matc 1.72.1) and bundled, discipline tints + ghosted slabs.
- **Resolved 2026-09-27:** the "screen-locked overlay" was not the camera: the `camera check` debug log showed Filament's camera equal to ARCore's pose to the millimetre over ~2 m of walking. It was the model drawn at the session origin before placement (now hidden until placed). Plain painted walls still force `floorTap` corners (rough heading): prefer boards or two corners there.
- **Also done 2026-09-27:** discipline legend + filters, element card (derived facts + IFC props: Tag, Status, SiteNote, Manufacturer), Drill check (`lib/core/ar/drill_check.dart`), rough-placement warning; server sends element props with features.
- **Next step:** align in the demo room (tap the right corner on the plan, snap, Use) and measure the loft/door offsets; re-run "Prepare for AR" so the bedroom build carries props.

### P-011 · Model viewer (2D/3D): Dart side never analyzed, tested or run on a device
- **Status:** needs verification · **Priority:** P2 · **Area:** model viewer (`lib/core/bim_viewer`, `lib/features/bim_viewer`, `lib/state/bim_viewer_*`, `assets/bim_viewer`, viewer scope in `ar_repository.dart` / `offline_db.dart`)
- **Found:** 2026-09-26 (V1 build; the user said not to test this pass)
- **Done so far:** the viewer page ran in headless Chromium against real server-built tiles, 22/22 checks (`tool/bim_viewer/e2e.mjs`); `viewer_math.js` 11/11 (`node --test tool/bim_viewer/viewer_math.test.mjs`); server side 325/325 vitest. The Dart tests are written: `test/bim_view_wire_test.dart`, `bim_plan_view_math_test.dart`, `viewer_asset_server_test.dart`, `bim_viewer_controller_test.dart`, `bim_viewer_screen_test.dart`, and the viewer group in `ar_repository_test.dart` (its memory store is now scope-aware). **2026-09-27 (incidental, from an unrelated PTW pass that needed `flutter analyze`/`test` to run at all):** the slim 3.47.5 SDK found the module had **never actually compiled** — `flutter analyze`/`test` were blocked project-wide by two real bugs here, not lint noise: `lib/state/bim_viewer_controller.dart:699,718` referenced an undefined `_features` (the field is `state.features`), and the `BimViewLayout` switches in `lib/features/bim_viewer/bim_viewer_screen.dart` (`_panes`, the toolbar icon) never handled `BimViewLayout.pip`, so both were non-exhaustive. Both are fixed (`state.features`; a plain static bottom-end/medium-size PIP overlay in `_panes`, `LucideIcons.pictureInPicture2` for the icon — the `layout_pip` i18n key already existed in both locale files). With those two fixes, `flutter analyze` is error-clean project-wide (only pre-existing infos/warnings remain) and `bim_viewer_controller_test.dart` passes 13/13. `bim_viewer_screen_test.dart` now *loads* for the first time and fails 2/13 with a real `RenderFlex overflow` in `_PlanPane`'s `TechEmptyState` at the 360×239 test viewport (`lib/widgets/common.dart:67`) — a genuine, previously-uncaught bug, left as this item's problem, not fixed as part of the PTW pass.
- **Left:** `flutter pub get --enforce-lockfile` (done 2026-09-27, lockfile unchanged), `flutter analyze` (done 2026-09-27, clean) `flutter test test/bim_* test/viewer_asset_server_test.dart test/ar_repository_test.dart` on ≥ 3.44 — only `bim_viewer_controller_test.dart` and `bim_viewer_screen_test.dart` have actually been run so far (the other files in this list are still unverified); fix the `_PlanPane`/`TechEmptyState` overflow above. On a device: Android WebView (WebGL2, `EagerGestureRecognizer` over split view, loopback cleartext) and iOS WKWebView; frame rate on a large floor (60+ tiles); walk joystick in RTL; a Demo-mode walk-through. The server's `?layers=` needs a DB where `applyArGeometryTables.ts --apply` has run, plus a rebuild (server P-030). The `pip` layout is also only a static default placement — no drag gesture and no read-back of `BimViewerPrefs.pipCorner`/`pipSize`, even though the prefs model already has both plus a `cornerNearest` helper for exactly this.
- **Why deferred:** the user asked for no testing this pass (2026-09-26); the 2026-09-27 fixes were a drive-by unblock for an unrelated task, not this item's planned verification pass.
- **Where:** [docs/bim-viewer.md §8](docs/bim-viewer.md#8-verification-be-honest), `lib/state/bim_viewer_controller.dart:699,718`, `lib/features/bim_viewer/bim_viewer_screen.dart` (`_panes`, `_Toolbar`)
- **Next step:** run the remaining untested files in the list above, then fix the `_PlanPane` overflow at small widths.

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
