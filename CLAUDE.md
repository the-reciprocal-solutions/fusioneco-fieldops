# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# FusionEco FieldOps — Claude Context

**Flutter (Dart ≥ 3.13) + Riverpod 2 + go_router + Dio + SQLCipher** mobile app for field technicians of the FusionEco facility-management platform. Pubspec name is `technician_portal` (older notes call it "the Flutter app" or `D:\fe_portals\technician_portal`). Android package is `com.fusionapps.fieldops`. **Offline-first**: technicians work in plant rooms with no signal. It does two jobs:

1. **Maintenance (CMMS):** work orders, invites, checklists with photo/voice/signature, downtime, close with RCA, inspections, and an AI Order Assistant.
2. **C2O field verification:** scan asset tags, verify against the handover register, walk downloaded route packs.

It is the mobile port of the web technician portal (`../fusion-eco-client/app/technician/*`) and calls the same API (`../fusion-eco-server`, Express on `:5002`). Comments that say "mirrors the web…" mean behaviour is deliberately kept in step with that portal.

Branches: `main` (active), `origin/dev`. Only Android ships. iOS is scaffolded but can't launch yet.

## Rules (always apply)

- **Communication mode**: caveman lite (compressed, no fluff). Off only on explicit `stop caveman`.
- **File refs**: cite as clickable `path:line`, e.g. [sync_client.dart:289](lib/core/offline/sync_client.dart#L289).
- **LEARNINGS**: append every non-obvious lesson to [LEARNINGS.md](LEARNINGS.md) before ending the turn, under the matching domain header. Include what happened, the cause, the fix, what to watch next time (with an example), the date, and the project state. Append; don't rewrite existing entries. Skip routine fixes. When a lesson upgrades a convention, update this file too.
- **PENDING**: before ending the turn, add to [PENDING.md](PENDING.md) anything left unfinished, partly done, skipped, blocked, or built-but-not-verified (analyze/tests not run on Flutter ≥ 3.44, never run on a device). Use the file's "Next number" and bump it. When you finish an item, move it to Closed with the date and a pointer to its LEARNINGS entry. Audit findings already in [docs/improvements.md](docs/improvements.md) stay there, don't copy them. LEARNINGS = what we learned; PENDING = what is still owed.
- **DOCUMENTATION**: on any significant or major-flow change, update or create the matching MD under [docs/](docs/), with a mermaid diagram. When you fix something listed in [docs/improvements.md](docs/improvements.md), mark it done there.
- **No git branch creation, no git push**, ever, including in auto/autonomous mode. Commit only when asked; commits stay local.
- **Subagents**: Sonnet for mechanical work (surveys, search, routine edits); Opus for reasoning and planning. Don't dispatch on your own judgment: use them when the user asks, or ask first and say why.
- **Verification honesty**: `flutter analyze` / `flutter test` results are only real if they ran on Flutter ≥ 3.44. As of 2026-09-25 the Mac's installed toolchain can't; a slim 3.47.5 SDK can be bootstrapped into the session scratchpad instead (recipe: LEARNINGS → Platform, 2026-09-26). Say which you used, or say it didn't run, rather than claiming green.
- **Touching the server?** `../fusion-eco-server/CLAUDE.md` rules apply there: shared Postgres (no destructive DB ops without confirmation), always free port 5002, and prompt-sync for LLM prompts. A contract change needs both sides updated in the same task.

## Commands

Full list, with dart-defines and the release checklist: [docs/build-release-and-platform.md §2–4](docs/build-release-and-platform.md#2-commands).

```bash
flutter pub get --enforce-lockfile          # never let pub rewrite pubspec.lock
flutter analyze
flutter test                                # all
flutter test test/flush_policy_test.dart    # one file
flutter test test/flush_policy_test.dart --plain-name "428 (location gate)"   # one test (substring)
flutter run --dart-define=API_BASE_URL=http://<lan-ip>:5002 --dart-define=WEB_BASE_URL=http://<lan-ip>:3000
flutter build appbundle --release --dart-define=API_BASE_URL=https://… --dart-define=WEB_BASE_URL=https://…
dart run flutter_launcher_icons
```

- **Always pass both hosts.** The committed defaults in [env.dart](lib/app/env.dart) are a developer's LAN IP over `http`. `API_BASE_URL` has no `/api` suffix.
- **Release signing:** a missing `android/key.properties` makes the release build **silently sign with the debug key** ([app/build.gradle.kts:60](android/app/build.gradle.kts#L60)). Verify with `jarsigner`, bump `+BUILD` on every Play upload, and record it in [VERSIONING.md](VERSIONING.md).

## Architecture (big picture)

Deep dive: [docs/architecture.md](docs/architecture.md).

**Layers:** `features/*` (screens) → `state/*` (hand-written Riverpod `Notifier`/`FutureProvider`, no codegen) → `data/*_repository.dart` (endpoints and JSON) → `core/offline/SyncClient` or `core/network/ApiClient` → server. `domain/*` models parse with the tolerant helpers in [envelope.dart](lib/core/network/envelope.dart): the API has four envelope shapes, and Sequelize DECIMALs arrive as strings.

**DI:** `main()` builds `SecureStore`, `SessionStore`, `OfflineDb` and `ApiClient`, and injects them with `ProviderScope` overrides. Their providers in [providers.dart](lib/state/providers.dart) throw by default. Tests and the background engine construct their own instances.

**The offline contract is chosen per repository:** taking `SyncClient` means offline-capable, taking only `ApiClient` means online-only (for example the AI chat and route release, both deliberately not queued).
- `syncGet`: network with write-through cache; on `NetworkFailure`, falls back to a non-expired cache entry (24h TTL).
- `syncRequest(method, url, label:, attachments:, entityType:, entityId:)`: on `NetworkFailure` (the **only** failure that queues) the write parks in `pending_mutations` and the UI shows `kOfflineQueuedMessage`. Photos, voice and signatures are `QueuedAttachment`s whose `__pending_*__` placeholder in the body is swapped for the uploaded URL at flush time. **Never inline base64 or upload directly** for a write that must survive offline.
- `flushQueue` replays oldest-first and stops at the first network failure. [flush_policy.dart](lib/core/offline/flush_policy.dart): **428/401 → stop run, keep everything**; other 4xx or 5 attempts → conflict log; 5xx → retry later.
- Triggers: 20s poll + connectivity + app resume + check-in + Sync Center + Android WorkManager (a separate engine; a `SyncLease` keeps it to one drainer).
- Every non-GET carries `X-Client-Mutation-Id`, minted once and reused on replay. The server caches **2xx only** for 24h, so a replayed failure runs again, and uploads are never de-duplicated.

**Local DB** ([offline_db.dart](lib/core/offline/offline_db.dart), SQLCipher, schema **v10**): queue, GET cache, meta/lease, conflicts, C2O asset cache, tag-issue reports, capture drafts, route packs, Snag Assistant snags + surveys, AR floor packs (`ar_*` tables, `ArPackStore`; tile GLBs are files under `<appSupport>/ar/tiles/`). For a schema change, bump `version`, add the DDL to `onCreate`, add an `if (oldVersion < N)` step, and keep reading old queued-row shapes. The passphrase lives in the keystore. The background engine must never mint one or close the DB.

**Session and gates:** 24h client-side session. Permission flags come from `GET /api/auth/config` (`isAiAgent`, `isCreateAsset`, `isAssetReport` opt-in; `isDigitalTwin` nullable, opt-out). Partner (non-in-house) accounts are refused at login. A stale GPS fix makes the server answer 428 on writes. [LocationCheckInGate](lib/widgets/location_checkin_gate.dart) wraps **every route** and blocks until `POST /api/fm/technicians/me/location` succeeds, then resumes the flush.

**Push and realtime:** FCM messages are **data-only** `{title, link, entityId, entityType}`, so [LocalNotifications](lib/core/push/local_notifications.dart) draws each one (a channel's sound is fixed when the channel is created). Socket.io `new_notification` works only while the app runs. Tap routing exists **twice** (`notification_route.dart` and `_routeForPushData` in `push_service.dart`); change both.

**Requirement IDs** (`FR-1…5.x`, `SR-x`, `NFR-1`) in comments come from the C2O field-verification spec, which is not in this repo. The ID → meaning → file map is in [docs/c2o-field-verification.md](docs/c2o-field-verification.md#requirement-map).

## Invariants and traps

- **Router:** switch to the 5 bottom-nav branches (`dashboard/overview/orders/invites/profile`) with `context.go`, **never `push`**: that crashes with `!keyReservation.contains(key)` ([router.dart:108](lib/app/router.dart#L108)). Only strings cross the router (path and query params through the `Routes.*` helpers, never `extra`). Paths mirror the web `/technician/*` routes minus the prefix, so server links map 1:1.
- **Locale:** only [LocaleController](lib/state/locale_controller.dart) calls `FlutterLocalization.translate`, and widgets watch it; never read the package singleton. Every string is `'ns.key'.getString(context)` with the key added to **both** `assets/i18n/en.json` and `ar.json`. Arabic is RTL.
- **UI kit:** `AppText.*`, `TechCard`, `TechChip`, `FeHeader`, `FeColors` and the `context.*` theme tokens ([theme_extensions.dart](lib/theme/theme_extensions.dart)); no raw `Color(0x…)` outside `lib/theme/`. Inside modal sheets use `showTechPopup`, not a SnackBar.
- **Order types:** paths come from a hard-coded table in [maintenance_record.dart](lib/domain/maintenance_record.dart). Work orders use plural `work-orders` for RCA and downtime only. Priority casing, done-status and technician field differ per type, so normalise. **The server removed the reactive and annual write routes and the annual technician list** (2026-09-12). Lists already show only work orders. Before touching RM/AMC flows, read [docs/maintenance-orders.md §1.1](docs/maintenance-orders.md).
- **Close flow:** signature → RCA → downtime → complete, each via `syncRequest`. The server's `422 missing[]` (`checklist | signature | session | rootCause`) decides, and client checks are UX only. [checklist_status.dart](lib/core/utils/checklist_status.dart) ports web `lib/checklist-status.ts` and server `checklistCloseGuard.ts`; change all three together.
- **C2O scans** run the c2o parser and the offline `c2o_assets` cache *before* the general QR scheme. Tag tokens are server HMACs, never computed on the device. A tokenless uncached tag must fall through (never call `/public/verify`). Put C2O logic in the pure, fake-tested classes in `lib/core/c2o/`, not in the 900-line screens.
- **Tests** are pure functions plus hand-written `implements` fakes of `abstract interface class` seams. There is no mocking library, and widget tests use an in-memory `MapLocale` plus `SharedPreferences.setMockInitialValues`. `SyncClient.flushQueue` itself is untested.
- **Comment style:** this codebase records *why* in long doc comments (bug history, device quirks, server contracts). Read them before changing code, and add one when you make a non-obvious decision.
- **Known open risks — read before relying on the queue:** `logout()` (including 24h expiry and any 401) **wipes the offline queue**. A 5xx on one item lets later dependent items replay first. Details and 40 more items, prioritised: [docs/improvements.md](docs/improvements.md).

## Detail files (load on demand)

- [docs/architecture.md](docs/architecture.md): core engine (bootstrap, DI, network, offline sync, DB schema, session, location gate, push, routing, i18n). **Read before touching `lib/core/` or `lib/state/providers.dart`.**
- [docs/maintenance-orders.md](docs/maintenance-orders.md): order types and the routes the server still serves, lifecycle diagram, checklist write shapes, close flow, offline behaviour per action, endpoints, inspections logic, the Order Assistant.
- [docs/c2o-field-verification.md](docs/c2o-field-verification.md): scan payload formats, offline-first resolve, capture form, drafts and photo paths, route packs (download, refresh, release), requirement-ID map, endpoints.
- [docs/ar-bim-overlay.md](docs/ar-bim-overlay.md): planned AR BIM overlay, **v3**. Native on Android, iPhone and iPad; ARCore/ARKit for tracking, **Filament for rendering on both** (SceneView on Android); WebXR rejected (no Safari `immersive-ar`), RealityKit is the iOS fallback. Locate/Identify/Verify jobs, multi-marker 4-DoF fit, tiles with feature index in `TEXCOORD_1`, `packages/fe_ar` contract, Track I (iOS bring-up), Track W (xeokit removal). **v1 built 2026-09-26, never run on a device** (see ar-implementation.md); read §0, §2.4 and §11 before any AR work.
- [docs/ar-markers-and-qr.md](docs/ar-markers-and-qr.md): AR markers end to end: code + upper-case short-URL QR (version 2), scan → building/floor/current build resolution, web admin (Marker Studio, print, install tracker, health), FieldOps technician/installer/spare flows, tables, endpoints, MK-1…26. Designs: the private canvas linked at its top. **v1 built 2026-09-26** (server, web, FieldOps), not device-verified.
- [docs/ar-setup-and-gamma-parity.md](docs/ar-setup-and-gamma-parity.md): **the AR setup order** (2026-09-26): snap two corners first (markerless, GAMMA's proven method), then leave a spare board for one-scan repeat visits. Also GAMMA research with sources, use cases translated for FusionEco (progress tracking with four-eyes, snags and issue pins in AR, system trace), AR-39…53 and slice moves. Read before §4 of the overlay plan.
- [docs/ar-implementation.md](docs/ar-implementation.md): **what is built for AR** (2026-09-26): file map, how screens → controllers → `ArGateway`/`ArEngine` → `ArRepository`/`fe_ar` connect (mermaid), routes, offline behaviour, **Demo mode**, enabling `packages/fe_ar` on a device, deviations from contract v1, and what is still unverified. **Read first before changing any `lib/core/ar`, `lib/state/ar_*` or `lib/features/ar` file.** Channel wire contract: [packages/fe_ar/CHANNEL.md](packages/fe_ar/CHANNEL.md) (change Dart, Kotlin and Swift together).
- [docs/ar-implementation-status.md](docs/ar-implementation-status.md): **AR end-to-end status across server, web and FieldOps** (2026-09-26): whole-system mermaid, the cross-repo contract check (C1–C8, what ran and how), what is written but unverified, and **the ordered steps a person must do next** (commit, apply tables, marker host, first build, Flutter ≥ 3.44, fe_ar slice 0, app links).
- [docs/bim-viewer.md](docs/bim-viewer.md): **2D/3D model viewer** (built 2026-09-26, V1, Dalux-style split view). three.js 0.160.1 (MIT) in a WebView fed by a loopback server (`ViewerAssetServer`, token path, registered hashes only), behind the `BimViewEngine` seam. It reads the AR floor pack plus a `viewer`-scope pack of the server's opt-in `architecture_solid` tiles (`?layers=`). It sits **alongside** the xeokit `TwinScreen`; never remove that (user, 2026-09-26). Dart side got its first-ever compile 2026-09-27 (see P-011): two real bugs fixed (`state.features`, a missing `BimViewLayout.pip` case), `bim_viewer_controller_test.dart` passes, `bim_viewer_screen_test.dart` still has a real `RenderFlex` overflow at small widths. Most of the module remains unanalyzed/untested and never run on a device (P-011). Read before touching `lib/core/bim_viewer`, `lib/features/bim_viewer`, `assets/bim_viewer` or the `ar_manifests` scope rules.
- [docs/ios-testflight.md](docs/ios-testflight.md): **iOS → TestFlight via GitHub Actions + fastlane** (2026-09-27, never run yet): App ID, App Store Connect app, API key, Apple Distribution `.p12`, Firebase plist, the GitHub secrets, running `.github/workflows/ios-testflight.yml`, adding testers, common failures, what the first CI build must prove (min iOS 15.5, Filament pod 1.72.0).
- [docs/snag-assistant.md](docs/snag-assistant.md): **Snag Assistant** (built 2026-09-26): research, use cases UC-1…17, walk mode, duplicate guard, ghost camera, verify run, readiness. Local-first: the `snags` table is written before any network call, server writes go through `syncRequest(..., queueOnServerError: true)`. `lib/core/snag/snag_rules.dart` ports the server's `snagRules.ts`; change both. Server: `../fusion-eco-server/documentation/snag-assistant.md` (needs `findings:promote` applied once per DB).
- [docs/permit-to-work.md](docs/permit-to-work.md): **Permit to Work (PTW)** (built 2026-09-26): screens, routing (notification link + `entityType: "PermitToWork"`, the `/permit-check/<token>` scan → resolve screen), offline behaviour per action (unlike Snag Assistant, no local write-ahead state — `readiness` is never re-derived on the device; signatures/isolation photos travel as inline data URLs, not `QueuedAttachment`s), endpoints. `lib/core/permit/permit_gas.dart` is the one exception to "the server decides everything" — live gas colouring only, re-judged server-side on submit. Server: `../fusion-eco-server/documentation/permit-to-work.md`. `flutter analyze`/`flutter test test/permit_*` ran clean on Flutter 3.47.5 (2026-09-27); no widget tests for the screens/sheets yet and never run on a device (PENDING P-013).
- [docs/build-release-and-platform.md](docs/build-release-and-platform.md): toolchain, commands, dart-defines, release checklist, Android and iOS config, push and check-in flow, tests, UI/theme/i18n conventions.
- [docs/improvements.md](docs/improvements.md): audited findings and the prioritised backlog (P1–P3) with suggested order of work.
- [LEARNINGS.md](LEARNINGS.md): durable lessons, including server contracts carried over from the server and client LEARNINGS.
- [docs/fcm-backend-handoff.md](docs/fcm-backend-handoff.md): the server work FCM needed (its "unregister on logout" note is outdated).
- [RELEASE_INFO.md](RELEASE_INFO.md) and [VERSIONING.md](VERSIONING.md): last release build notes, signing and Firebase setup, and the build-number policy.
- Server-side references: `../fusion-eco-server/documentation/{c2o-route-assignment,technician-location-capture,fcm-push-notifications,order-assistant-media,technician-signature}.md`.
