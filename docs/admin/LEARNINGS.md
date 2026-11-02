# LEARNINGS — admin_portal

> Carried over from the separate admin_portal app (2026-10-31). Paths are relative to `lib/admin/` now; item numbers are A- (they were P- there). New admin lessons go into the root [LEARNINGS.md](../../LEARNINGS.md).

Non-obvious lessons, newest last. Same format as technician_portal's LEARNINGS.md: what happened, the cause, the fix, what to watch, the date, and the project state.

## 2026-10-30 — go_router: a catalog change doesn't re-guard a pushed screen

**What happened.** The `config:changed` widget test switched Plant Room off while `/m/plant_room` was open (opened with `router.push`). The router's `refreshListenable` fired, but the screen stayed.

**Cause.** go_router re-runs the top-level `redirect` for the base location only. Imperatively pushed matches are not re-checked on refresh.

**Fix.** `ModuleScreen` calls `catalogRedirect()` itself on every build (it watches `loadedCatalogProvider`). When the result isn't null, it shows `UnavailableScreen`.

**Watch.** Any future pushed screen that depends on the catalog (Efficiency pages, alert detail from a push tap) must re-check the guard the same way. Don't rely on the router redirect alone. Example: an alert detail opened from a notification, and the Alert Center then switched off.

**State.** 0.1–0.3 are built and 23 tests pass.

## 2026-10-30 — Socket token outlives the access token

**What happened.** FieldOps passes the login token to `setAuth` once. Admin access tokens last 1 h, so a reconnect after an hour would be refused.

**Fix.** `SocketService` re-reads the token from secure storage on `onDisconnect`, and sets `socket.auth`, before the library retries. On a `connect_error` containing "Authentication error", it renews through `ApiClient.renewSession()` once and reconnects.

**Watch.** The server's refusal text is exactly `Authentication error: Invalid token` (checked live on 2026-10-30). If the server's wording changes, update the match.

## 2026-10-30 — Testing on the phone

- The phone (CPH2667) uses mobile data, so it can't reach the PC's LAN IP. Use `adb reverse tcp:5002 tcp:5002` and build with `API_BASE_URL=http://localhost:5002`.
- Android blocks `http://` by default. The **debug** manifest sets `usesCleartextTraffic`; release builds stay https-only.
- `pm clear` is refused on this Oppo build (SecurityException). Log out in the app instead.

## 2026-10-30 — Phase 3a: one spec per module, not one screen per module

**What.** 15 FM modules plus Home, all "summary tiles + list + detail + light actions". Each one is a `ModuleSpec` (lib/features/modules/fm_specs.dart) drawn by two generic screens (`ModuleSummaryScreen`, `RecordDetailScreen`). A new module is a spec plus i18n keys, and no new screen. Registry: lib/features/modules/specs.dart. A module without a spec still opens the "coming soon" placeholder.

**Watch.**
- **The FM endpoints have four envelope shapes:** `{data:[..]}`, `{data:{items,total}}`, `{documents,total}`, and a bare object (PM analytics). Counts sometimes arrive as strings (`"count":"35"`). Always read through `rowsOf` / `totalOf` / `dataOf` / `n()`, never `as List`.
- **Probe the live endpoint before writing a spec.** `limit` alone did nothing on Preventive, which pages only when `page` AND `limit` are both sent. Reactive and Assets had no paging at all (142 KB and 645 KB), so the server got `utils/optionalPaging.ts`.
- **Git Bash rewrites `/fm/x` arguments into `C:/Program Files/Git/fm/x`** when they contain no `?`. Run probes with `MSYS_NO_PATHCONV=1`.
- **Bug: a text dialog whose controller is disposed right after `showDialog` returns crashes** ("TextEditingController was used after being disposed") during the close animation. The alert note dialog had it too. Use `promptText()` (lib/widgets/text_prompt.dart): the dialog's own State owns and disposes the controller.
- **Detail screens:** `RowGroup` brings its own 16px inset. Give the ListView no side padding and wrap the header + buttons in 16px, or the cards don't line up (fixed twice now: alert detail, record detail).
- **`dashboard-v3` needs `?env=`.** The web derives it from brand switches (useUtilitySubsites `proxyEnv`). The server now sends `prefs.dashboardEnv` in the bootstrap, so the app doesn't copy that rule.

## 2026-10-30 — Phase 3b: utilities read the building system, not the old provider feeds

**What.** Every web utility page defaults to the BACnet/MSC ("msc") variant (`hooks/useFuPageVariant.ts`). The phone reads the same two proxy calls the web's Facility Utilities dashboard uses: `/api/proxy/bacnet/api/devices` and `/history/devices/latest`. Each takes `utility_tag` repeated for several utilities at once. Catalog module id → master code is in `utilityTags` (lib/features/modules/utility_screens.dart). The readings are the web's Dashboard tab, so they show only while `is<Utility>_Dashboard` is in the catalog `tabs`.

**Watch.**
- `latest` returns `points` as a map `{"DEV-01/PointName": value}`. Join it to `devices` by `device_id`. `devices` carries the online/offline status, and `latest` has none.
- Dio sends a `List` query value as a repeated param (`ListFormat.multi`), which is what the proxy wants.
- **Point names:** port the web's `humanizePoint` instead of writing your own. The first home-made version gave "Run Hours" / "Space Temp" where the web shows "Run hours" / "Space temp", and it missed the web's expansions ("Comp1Hp1Fault" → "Compressor 1 high-pressure 1 fault", "co2" → "CO₂"). Use one rule in both apps, marked CHANGE BOTH.
- **Shell escaping ate regex backslashes:** `node -e '…'` with a JS template literal turned Dart `\d` into `d`, `\s` into `s`, and `\b` into a raw backspace (0x08). It compiled, and only a test caught it ("Run hour"). Put Dart source in its own file, or use the editor; never pass regexes through `node -e` / heredocs. Scan with node for `[\x00-\x08]` afterwards (`grep -P` doesn't work in this Git Bash locale).
- **More screen:** the server's catalog group "Account" (Notifications) made a second ACCOUNT header next to the screen's own. Modules in that group now render inside the local Account section.

## 2026-10-30 — Phase 3c: pages, web-only modules, chat

**What.** 17 more specs (lib/features/modules/ops_specs.dart). Facility Ops is a module made of pages. A page has its own spec under `module:page` (`specKey()`), keeps `?page=` in its record path (`recordPath(…, page:)`), and the guard checks the page there too. Modules the plan only asks to "view" (Timeline) get `WebOnlyScreen`. Every summary header has an "open on web" button (`Env.webBaseUrl + module.webPath`). *(2026-11-02: replaced by a summary + `DesktopNote`, PENDING A-025.)* Ask FlowAI uses the web's non-streaming `POST /api/utility/ai/chat-v2 {message, sessionId, env}` with a client-minted v4 session id, as the web does.

**Watch.**
- **Any screen opened with `Navigator.push`** (the chat) must re-check the catalog itself, the same as go_router-pushed screens.
- **Server fallback text is not an app bug.** Intelligence returned "Not available right now" for every capability on a cold call (8 s). The next call had real headlines. Check the endpoint before "fixing" the app.
- **Cards need a name the server owns.** The overview sent only `id`, so the server now adds `name` from its `CAPABILITIES` (additive field). The phone falls back to the id on an older server.
- **Raw status words** (`checked_in`) read badly in chips. `chipLabel()` turns `_` / `-` into spaces.
- **The theme's FAB is a pale container:** set `backgroundColor`/`foregroundColor` when the label is white.
- **Tokens from `scripts/mint-token.mjs` are short-lived.** A 401 in a probe after a few hours means re-mint, not a broken route.
- **A `node -e` replace script that throws halfway leaves the earlier files written.** After a throw, check which edits landed before re-running.

## 2026-10-30 — Building Efficiency: 16 pages over one summary

**What.** `GET /api/fm/hvac-efficiency/summary?connectionId&site&days` (48–54 KB live) feeds 13 of the 16 pages, as the web's `useHvacData` does. Fix tracker reads `/actions`, Site settings reads `/settings`, and Trends opens the web. Each page is the spec `efficiency:<page>` → `EffPageScreen` (lib/features/efficiency/). The site picked is remembered as `connectionId|site` under `hvac-eff:last-site` (SessionStore, cleared on sign-out). The summary refreshes every 2 min while a page is open.

**Watch.**
- **A site is a pair:** the summary needs `connectionId` as well as `site`. `site` alone answers 400 "Pick a BMS site first".
- **Findings carry `pillar`** (comfort / energy / equipment / power / safety / data), so each area page filters the same list. A finding's `impact` is optional.
- **Raise WO needs a `requestId`:** the server replays it instead of creating a second WO. Mint it once per detail screen, not per tap.
- **The finding detail is pushed with Navigator:** it re-checks that its page (and `fix`, for the Raise button) is still in the catalog.
- **Live values had tiers and categories the first list missed** (`controls`; `equipment`, `carbon`). Print the distinct values from a live response before writing an i18n table for them.
- **A dropdown next to a 3-segment button squeezed the site name to "ba…"** on a 360 dp phone, so the site picker now sits on its own line.

## 2026-10-30 — Plant Room: rooms and live cards

**What.** lib/features/plant_room/. The room list is `GET /api/fm/plant-layouts?scope=all` and one room is `GET /:id`. Each placed machine is a card, with live values from `GET /live?assetIds=` polled every 30 s while the room is open. The 3D studio opens on the web (`/facility-utilities/plant-room/<id>`). The `plant_room` spec renders `PlantRoomListScreen`.

**Watch.**
- **Three kinds of machine.** `assetId` → read from `/live`. `binding` only → the web studio reads that device straight from the BMS proxy (`energy_dashboard/list_utilities_info_by_subsite_id`); the phone says "Live readings on the web". Neither → the web *animates a demo*; the phone says "Not connected" rather than show made-up numbers.
- **Alarm is narrower than the web's.** The web's severity comes from each machine type's `normalize()` (22 types, with their own thresholds). The phone only marks a card critical when an alarm/fault/trip/fire/smoke/leak point reads alarm with the ported `toAlarmState` (CHANGE BOTH). It has no `warn` level.
- **`/live` is small but slow:** 11 KB for 60 assets, yet about 20 s even for 8 assets (PENDING A-017). The app gives it a 60 s timeout (`ApiClient.get(timeout:)`) and never starts a poll while one is still running.
- **No rooms exist on this server** (`plant_layouts` is empty), so the screens were checked against fakes only.
- **`FeHeader`'s back button calls go_router's `pop`.** A widget test without a GoRouter must pop the Navigator directly.

## 2026-10-30 — Photo Twin: snags, scans, report issue

**What.** lib/features/photo_twin/. The screen shows snag counts (`/api/snags/summary`), the open snags (`/api/snags?view=list&status=open,in-progress,ready`) and each building's photo scans: the `metadata.kind == 'splat'` rows of `/api/fm/bs/3d-models`, kept only for buildings in `/api/snags/locations/buildings`. A scan opens the web viewer at `/digital-twin/realistic?b=<buildingId>&m=<modelId>` (viewState.ts). Snag moves live in `snagActions()` and are shared with the Snags module. Report issue posts a reactive ticket, built like the web's `buildReactivePayload`.

**Watch.**
- **Actions can now need a photo:** `RecordAction.photoRun` → the detail screen picks (`photoPickerProvider`, overridden in tests), uploads (`ApiClient.uploadFile` → `/api/upload/file`, `data.url`), then runs. "Mark fixed" sends the URL as `evidence: [{kind:'photo', stage:'after', url}]` on the `ready` transition; the server refuses `ready` without one (422).
- **Evidence URLs must be absolute http(s):** the server drops anything else.
- **Snag photos come from the file server's own address** (`http://localhost:9002/...` on this setup). A phone on `adb reverse tcp:5002` can't reach it, so every image has an `errorBuilder` tile. Scan thumbnails are files of the web app (`/twin-assets/...` → `Env.webBaseUrl`) and did load.
- **`/3d-models` lists every model**, BIM designs included. Only `kind == 'splat'` is a photo scan. The saved viewpoints are on the BIM models (Digital Twin), not on scans.
- **Reactive duplicate check:** a 409 means a similar ticket is open. Ask, then resend with `duplicateAck: true`, as the web does.
- **Snag "Raise work order" needs a `requestId`.** It is kept per snag id in memory, so a retry links the same work order.
- **Widget tests:** a lazy `ListView` doesn't build off-screen children, so use `scrollUntilVisible`, not `ensureVisible`. Screens that read `authControllerProvider` need `sessionStoreProvider` overridden.
- **SegmentedButton labels clip** ("Mediu") at 360 dp. Wrap them in `FittedBox(fit: BoxFit.scaleDown)`.

## 2026-10-30 — Push notifications

**What.** `lib/core/push/`: `initFirebase()` in main, `PushService.init()` when the signed-in shell opens (registers the FCM token), `unregister()` on manual sign-out (before the tokens are cleared, while the session still works). Android pushes are data-only, so `firebaseMessagingBackgroundHandler` draws them (`LocalNotifications.show`). Taps go through `pushTargetOf()`: `alertKey` (the fan-out) or `link /alerts?alert=` (routing's bell push) → `alertPath`; anything else → Notifications. More → Alert notifications saves `mobilePushAlerts` / `mobilePushMinSeverity` to the user's own config.

**Watch.**
- **No `google-services.json` for `com.fusionapps.admin` yet** (FieldOps' file lists only its own packages). The Google Services Gradle plugin fails the build when the package isn't in the file, so it is applied only if the file exists, and `Firebase.initializeApp()` is wrapped: the app runs with push off.
- **flutter_local_notifications needs core library desugaring** on Android (`isCoreLibraryDesugaringEnabled` + `desugar_jdk_libs`).
- **The background isolate has no app state:** it reads the language from flutter_localization's own prefs key (`translator_locale_key`) for the channel names.
- **Tiles in a `TechCard` need their own `Material`** (a test assertion caught it again: "ListTile background color or ink splashes may be invisible").
- **Record equality compares a map by identity.** In tests, compare `$1` and `$2` separately.

## 2026-10-30 — 0.6: web pages inside the app, signed in

**What.** *(2026-11-02: only the alert's new-work-order form still opens this way; the rest show a summary + `DesktopNote`, PENDING A-025.)* `lib/features/web/web_screen.dart`. Every `openOnWeb()` (header buttons, 3D views, Trends, the efficiency PDF report, Plant Room 3D, Photo Twin scans, Timeline) now opens the web page inside the app. The screen loads the web's `/login`, writes the localStorage keys the web's sign-in writes (`webSessionEntries`, app/login/page.tsx), then loads the page. It reuses FieldOps' TwinScreen recipe. Downloads: an injected hook turns an `<a download href="blob:">` click (reportPdf.ts `saveBlob`) into a `FeDownload` channel message; the app writes the file to temp and opens the share sheet (share_plus).

**Watch.**
- **The token goes in once.** The web can't renew the app's token (1 h for mobile users). `ApiClient.freshToken()` renews it first if it ends within 2 min. If the page signs itself out later (lands on /login), the screen re-seeds and re-asks, capped at 3 tries.
- **Only same-origin pages load in the view.** Files and other sites go to the phone's browser, so the view never strands the user (FieldOps' rule).
- **Test builds need the web app on a URL the phone can reach and on the same backend as `API_BASE_URL`**, or the seeded token means nothing to it. `WEB_BASE_URL` defaults to the deployed dev site. For the local server, run the client and build with `--dart-define=WEB_BASE_URL=http://localhost:3000` plus `adb reverse tcp:3000 tcp:3000`.
- **The web page still shows its own side nav/header.** FieldOps hides them with injected CSS on the twin page only; the admin pages are not stripped (yet).

## 2026-10-30 — Four parked bugs fixed (A-001, A-002, A-011, A-014) + 0.6 checked

**What.**
- **A-001:** language saved with `POST /api/auth/config {language}`; the catalog applies the server's language only when the server value changes.
- **A-002:** socket renewal retried with backoff when unreachable; reconnect on resume.
- **A-011, A-014:** chip colours for condition, severity and extra status words.

All four, and the in-app web view with PDF share, were checked on the phone.

**Watch.**
- **A handy live-channel test:** `POST /api/auth/config {"language":"ar"}` with a token for the phone's user. The phone switches language within seconds over `config:changed` (it changes nothing but the language; set it back after). Cutting the phone off for an "offline" test: `adb reverse --remove tcp:5002`, then add it back.
- **The deployed dev web site accepts the local server's token** (same JWT secret / DB), so the in-app web view works against it without a local client.
- **The web's side rail is the `<aside>` with `transition-[width]`.** It covered most of a phone screen until it was hidden by injected CSS.
- **The More screen keeps its scroll position across tab switches.** Scripted taps on it need a scroll-to-top first.
