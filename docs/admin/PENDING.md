# PENDING — admin side (`lib/admin/`)

Carried over from the separate `D:e_portalsdmin_portal` app when it moved into FieldOps on 2026-10-31 (see [../admin-side.md](../admin-side.md)). Its numbers were P-001…P-021 there; they are **A-** here so they never clash with FieldOps' own PENDING numbers. File paths below are relative to `lib/admin/` now, and "the app" means the admin side. Things still owed: unfinished, known bugs, or built but not verified. Same convention as the root PENDING.md: when an item is closed, move it to **Closed** with the date and a pointer to its LEARNINGS entry.

Next number: A-022

## Open

### A-005 — Alerts list shows the first 50 only (2026-10-30)
The live site has 1,056 open alerts. The list asks for `size=50` (42 KB), and a "Showing 50 of N" line tells the user to narrow the filters. Add infinite scroll (`page=2…`) in Phase 4 ("paginate long lists"). The building filter from the plan is not on the phone yet either.

### A-006 — Alert actions not run against live data (2026-10-30)
- **2026-10-31: slow card fixed.** Timed live: action 1.5 s, detail 1.0 s, list 1.2 s. The phone now shows the alert the action returned at once (`alertPatchesProvider`, list + detail) and drops it when a fetch that started later lands (test/admin/alert_patch_test.dart).
- **2026-10-30, run on the phone with live data:** acknowledge, then resolve, on a simulator alert (SIM-MVV868CO-5FV, building "test") worked; the server shows acknowledged + resolved by Ragul. The card took about 10 s to refresh after each action (the "done" message comes first). Note, take, reopen and bulk were not run live.
Acknowledge, resolve, reopen, take, note and bulk are covered by widget tests against a fake server. On the live server only the GETs were run (list 200, detail 200), because every action writes to real alerts. The owner should try one on the phone (e.g. acknowledge a simulator alert).

### A-007 — Web-only alert actions not on the phone
`work_order` (link or create a WO), `assign` to someone else, and `snooze` are not offered yet. The plan lists "create work order" for v1: it needs the work-order picker or create flow (Phase 3a).

### A-008 — Phase 3a actions not run against live data (2026-10-30)
- **2026-10-30:** a work order comment from the phone worked (WO-762 "RM: Test Electrical", saved as a `comment` log). **Gap:** the phone's WO screen doesn't list comments/logs, so you only see it on the web. Start / complete / hold, permits, quotes and invoices were not run live.
Work order start / complete / hold / comment, permit approve / reject, quote accept / reject and invoice approve are covered by widget and unit tests against a fake server (test/modules_test.dart). On the live server only the GETs were run. Every action writes a real record, so the owner tries one first (for example, a comment on a test work order).

### A-009 — Phase 3a gaps vs FE-mobile.md (2026-10-30)
- **Work order photo:** the plan says comment + photo. Only the text comment is in. Needs `image_picker` + `/api/upload/file`, then `attachments` on `POST /:id/comments`.
- **Assets QR scan:** not in. Needs `mobile_scanner` (FieldOps has it) and a lookup by `assetReferenceId` (the list already takes `search=`).
- **Snags, Preventive, Reactive, Annual, Inspections, Documents, Audit log** are read-only on the phone. The plan asks only for a summary there, except snag transitions (in the plan under Photo Twin, Phase 2).
- **PM compliance:** shows the PM analytics figures (compliance %, adherence, monthly trend). The web's per-building compliance report needs `buildingId` + `year`; it isn't on the phone.
- **Documents list** isn't paged: the endpoint ignores `page`/`limit` (34 KB for 40 docs today, so it's fine for now).

### A-013 — Phase 3b gaps (2026-10-30)
- **Floor Plan** (image view) has no spec yet, so it opens the placeholder.
- **Solar, Intrusion, CCTV:** the building system reports 0 devices for SOLAR / INTRUSION / CCTV here, so the phone shows "No devices connected". The web falls back to the legacy SustainSphere pages for these (`?variant=legacy`), which the phone does not read.
- **Utility tabs:** only the Dashboard tab (live readings) is on the phone. Trends, Logbook and Alerts tabs are honoured as switches but have no phone view yet.
- **Device names:** the web maps points through Device Mapping (`getUtilityDisplayCached`, mappedAliases). The phone shows the raw point name made readable with the web's own `humanizePoint` rules, so a mapped alias can differ.
- **Checked on the phone:** Facility Utilities overview, DG, Feel Temperature, Access Control. **Not checked on the phone:** Building Energy, Energy Analytics, Occupancy (not in Ragul's catalog), AC / AHU / Ductable AC, Utility Explorer. Each endpoint was called live, and widget or unit tests cover each screen.
- **First load can be slow:** the building system's first `devices` call took about 4 to 7 s; later calls take under 1 s.

### A-015 — Phase 3c gaps (2026-10-30)
- **2026-10-30:** visitor approve and check-out from the phone both worked on a test walk-in ("TEST visitor (mobile app check)", V-2026-10-30-001, host Ragul; it stays in the history). Server fix: `checkIn`/`checkOut`/`preRegister` crashed on a request with no body (`req.body.notes` on the multer route) and now use `req.body?.`.
- **Visitor approve → done 2026-10-30:** the server already had it: `POST /api/ops/visitors/:id/pre-register` stamps `hostApprovedAt`, the same call as the web's Approve button. The phone shows **Approve** on a `pending_host_approval` visitor. Not pressed live: no visitor was pending, and making one would add a fake record. Covered by test/ops_test.dart.
- **Phase 3c actions not run on live data:** visitor check-in / check-out and notification "mark read" write real records, so they were run only against fakes (test/ops_test.dart).
- **Ask FlowAI:** the session list was checked on the phone, but no message was sent live (each one calls the paid LLM). Answers show as plain text (no markdown yet), there's no streaming (`/chat-v2/stream`), and no image or "create asset / report" modes.
- **AMC:** the web page reads the full schedule calendar (341 KB). The phone shows the schedule-management summary + a paged list instead, with no calendar view.
- **Timeline Revisit** opens the web page. **Digital Twin** lists the buildings, and the 3D view is on the web (the header button). **Construction Progress** has no data on this server (`/api/construction/schedules` is empty), so its list is unverified.
- **Reports:** saved report definitions are listed. Running or downloading one stays on the web (header button).
- **Opening the web** relies on the browser's own login: the token is not handed over (plan 0.6's seeded WebView is not built).
- **Not opened on the phone:** AMC, Digital Twin, Handover, Construction Progress, Reports, Carbon, Flow Agents, Bookings, Service Schedules, RFQs, Purchase Orders. Their endpoints were called live and the parsing is unit-tested. **Checked on the phone:** Facility Ops pages, Visitors (list + detail), Notifications, Intelligence, Ask FlowAI sessions.

### A-016 — Building Efficiency gaps (2026-10-30)
- **2026-10-31: real cause found (server/DB, not the phone).** The preview (read-only) matched a technician (Anita Raghavan), so it is NOT `TECHNICIAN_NEEDED`. It matched no asset, so `createHvacWorkOrder` saves `relatedAssetId: null`; the model allows that (`allowNull: true`) but the live `work_orders."relatedAssetId"` column is `NOT NULL` (schema drift), so the insert fails and the server answers 502 "The work order couldn't be prepared". The web fails the same way (its dialog offers "No asset (location only)"), and so does snag "Raise work order" (`snagEstimateActions.ts` saves `relatedAssetId: null`). **Fix needs the owner's OK:** `ALTER TABLE work_orders ALTER COLUMN "relatedAssetId" DROP NOT NULL` on the shared DB.
- **2026-10-30: Raise work order failed on the phone** (FCU corridor L5 finding): the button went back to "Raise work order" and no WO was created. Likely cause: the server answers 422 `TECHNICIAN_NEEDED` when it can't match a technician (the web has a picker; the phone doesn't), but this wasn't confirmed because the API server stopped mid-check. Also seen once: Open issues loaded blank until pulled to refresh (app now keeps loading instead of settling on "no data").
- **Raise work order** (`POST /api/fm/hvac-efficiency/work-order`, with a `requestId` so a retry doesn't make a second WO) was run only against a fake (test/efficiency_test.dart). It creates a real work order, so the owner tries it first.
- **Ask AI** (`/explain`, on Building health) is not on the phone: each call uses the paid LLM.
- **Web-only for now:** Trends (picking points), the 3D views (AI overview, Live building) and the PDF report open the web page. The token is not handed over (plan 0.6 WebView).
- **Energy & power** shows the plant ΔT figures only. On this BMS site `energy` and `power` are null, so the meter view is untested with real meter data.
- **Checks & limits** lists the checks that found something and those that can't run here (`skipped`). The full rule catalogue with limits is web-only.
- **Checked on the phone:** Efficiency list, Building health, Open issues, finding detail. **Not opened on the phone:** the other 13 pages. Each one reads the same live summary (probed: 48–54 KB, 1–2 s), and the bodies are widget/unit-tested.
- **Site names** are the raw BMS gateway names (`bacnet_gw_02`), the same as the web.

### A-018 — Plant Room gaps (2026-10-30)
- **Not seen on the phone with real data:** `plant_layouts` is empty on this server. On the phone only the empty list was seen (2026-10-30). The room and poll are covered by test/plant_room_test.dart only. Build a room in Plant Studio on the web, then open it on the phone.
- **Alarm only, no warning:** cards go red for alarm/trip points. The web's per-type thresholds (`normalize()` severity, `warn`) are not on the phone.
- **Device-bound machines** (BMS binding, no FM asset) show "Live readings on the web": the phone doesn't call the BMS proxy batch endpoint.
- **3D** opens the web page in the browser (plan: read-only WebView, 0.6). The token is not handed over.

### A-019 — Photo Twin gaps (2026-10-30)
- **2026-10-30:** a snag comment from the phone worked (SN-00008 TEST-ALL); it shows in the snag's Activity at once.
- **Actions not run on live data:** start, mark fixed (after photo), verify, reject, reopen, waive, comment, add photo, raise WO and Report issue all write real records. They were run against fakes only (test/photo_twin_test.dart). On the phone: the home screen, a snag's detail (moves, photo, thread) and the empty Report form were checked.
- **Snag photos don't show on the phone here:** the evidence URLs point at `http://localhost:9002` (the file server), which the phone can't reach over `adb reverse`. On a deployed server with a public file URL they should load. Check after deploy.
- **No 3D on the phone:** scans open the web viewer in the browser (plan 0.6 WebView not built; the token is not handed over).
- **Report issue** sends a reactive ticket only. Raising a *snag* stays with FieldOps (walk, AI assist). There is no 3D spot or nearest asset (the phone has no viewer), so the location is the building plus a typed "where".
- **Waive** is shown to every user. The server refuses non-Admins (403 WAIVE_FORBIDDEN), and the app shows that message.
- **Raw words** in snag facts (trade `finishes`) are shown as the server sends them (same as A-011/A-014).

### A-020 — Push not verified end to end (2026-10-30)
- **Firebase: solved by the move (2026-10-31).** The admin side now ships inside `com.fusionapps.fieldops`, which already has `android/app/google-services.json`, so no new Firebase app is needed. (Before the move this needed `com.fusionapps.admin` registered in `fusion-eco-technician`.)
- **Not verified end to end** (plan verification 4): raise a simulator alert as super admin → the phone gets a push → tapping it opens the alert → acknowledging it updates the web. It needs step 1 first.
- **Settings not saved live:** choosing a severity writes the user's real config, so it was run against a fake only (test/push_test.dart).
- **Not built:** notification buttons (acknowledge from the tray), an iOS Notification Service Extension (photos), and a "test push" button.
- **2026-10-31: critical channel fixed.** Routing's bell push for a critical alert carries `type: error` and no `severity`, so it went to `fe_alerts`; `channelIdFor` now treats `type == error` on an alert as critical.
- **Default is high + critical.** Medium/low alerts (most simulator ones) don't push unless the user picks them, while routing's own "Assigned to you" bell pushes always arrive.

## Closed

### A-004 — Live `config:changed` on the phone → done 2026-10-30
Checked end to end on the phone (CPH2667) with Ragul (super admin): `POST /api/auth/users/:id/config {data:{isPlantRoom:false}}`, the call the web's user-permissions page makes. **Within 5 s, without touching the phone:** the open Plant Room screen turned into "Not available", and Plant Room left More. Restored with `{isPlantRoom:null}` (it was *not set* before, so it is not forced on). Plant Room came back on its own, and the config reads "not set" again. Earlier the same day: a language change arrived over the socket, also after a 40 s offline spell (A-002).

### A-017 — Server: `/api/fm/plant-layouts/live` takes about 20 s (found 2026-10-30) → done 2026-10-30
Recommended fix applied: a 5-minute "no reading" memo (utilityReadings `isRecentMiss`/`markMiss`). The cache-first read skips the source for a binding that just came back empty; the 5-min cron and an explicit `fresh` refresh still ask it. Live: 8 assets 20.4 s → 0.04 s, 60 assets 20.1 s → 1.4 s (same data). Only the first read after a miss expires is slow.

### A-010 — Security: `GET /api/fm/assets` returns camera credentials (found 2026-10-30) → done 2026-10-30
Owner approved. Server: `Asset` defaultScope leaves out `cameraUsername`/`cameraPassword` on every read, and `toJSON` strips them from created/updated instances. `GET /api/fm/assets/:id` adds `cameraUsername` + `hasCameraPassword` (the edit form) via `Asset.scope("withCameraSecrets")`. An empty or missing password on `PUT` keeps the stored one. The public QR card reads through the same scope. Live check: 0 of 137 list rows and 0 of 50 paged rows carry the fields. Not checked live: `hasCameraPassword: true` (no asset on this DB has a camera password).

### A-003 — Decision: Home tab always shown (2026-10-30) → done 2026-10-30
Owner: always show Home, whatever the Dashboard switch. Home now always loads the dashboard tiles (the "Dashboard is off" state was removed). Seen on the phone for Ragul (switch off): tiles shown. test/home_test.dart.

### A-021 — 0.6 web pages in the app: not seen on the phone (2026-10-30) → done 2026-10-30
Checked on the phone against the deployed dev site (`WEB_BASE_URL` default): Intelligence and the Efficiency Daily report opened signed in, the side rail is hidden by injected CSS, and **Download PDF opened the share sheet with the 1.1 MB report**. Not yet run against a local web client.

### A-014 — Chip colours for other words (2026-10-30) → done 2026-10-30
Severity words (warning, major, minor, info…) in `priority()`, and whole-value status words (ok, warn, risk, info, checked in/out, approved, rejected…) in `status()`, after the shared web rules. Seen on the phone in Intelligence (ok green, warn amber, risk red, neutral grey).

### A-011 — Condition chips are grey (2026-10-30) → done 2026-10-30
Condition words (excellent / good / fair / poor) have their hues in `FeStatusColors.priority()`. Seen on the phone in Assets.

### A-002 — Bug: socket stays dead after an auth error during an offline renewal (found 2026-10-30) → done 2026-10-30
The socket retries the renewal with backoff (5 s → 60 s) when the server is unreachable, stops only when the renewal is refused, and `ensureConnected()` runs on app resume. Checked on the phone: cut off from the server for 40 s in the background, then resumed; a server-side config change reached the app over the socket. The token-expired-while-offline path (1 h) was not reproduced on the device.

### A-001 — Bug: in-app language choice reverts (found 2026-10-30) → done 2026-10-30
`LocaleController.choose()` saves `{language}` to the own config. The catalog follows the server only when the server value changes (`serverLanguageProvider`). Checked on the phone: switching to Arabic was saved (`ar`) and survived a background/resume; switched back to `en`. LEARNINGS 2026-10-30 "Four parked bugs".

### A-012 — Phase 3c not started → done 2026-10-30
Every catalog module now opens a phone screen except Dashboard / Efficiency / Alerts (their own tabs) and Plant Room / Photo Twin (Phase 2) / Floor Plan (A-013). test/ops_test.dart fails if a new catalog id has no screen. LEARNINGS 2026-10-30 "Phase 3c".
