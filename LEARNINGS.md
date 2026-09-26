# LEARNINGS — FusionEco FieldOps

Durable lessons for this repo: bug patterns and their root causes, "don't do X because Y", contracts that aren't obvious from the code. **Append, don't rewrite.** Put each entry under its domain header, newest first. Format:

```
### <short title> (YYYY-MM-DD)
**What happened:** … **Cause:** … **Fix:** … **What to watch:** … (with a concrete example)
**Where:** file:line / commit · **Project state:** (when it matters)
```

Entries marked **Source:** were carried over on 2026-09-25 from `fusion-eco-server/LEARNINGS.md` and `fusion-eco-client/LEARNINGS.md`, because they bind this app. The originals hold the full story.

**Project state when this file was created (2026-09-25):** `main` @ `8b60a07`, version `1.0.1+3`, Android-only release (package `com.fusionapps.fieldops`). `flutter analyze` and `flutter test` were **not** run: this Mac's newest Flutter is 3.19.3 and the lockfile needs Flutter ≥ 3.44 / Dart ≥ 3.13.2. The prioritized open issues are in [docs/improvements.md](docs/improvements.md).

---

## Offline queue and sync

### Logging out deletes the unsynced queue (2026-09-25, open)
**What happened:** An audit found that `AuthController.logout()` calls `OfflineDb.wipe()`, which deletes `pending_mutations` and drafts. `logout()` runs on manual sign-out, the in-app 24h expiry timer, the session-expired dialog and **any 401**. **Cause:** the wipe has been there since the first scaffold (`82ab613`, 2026-09-07). Background sync (`8b60a07`) was later written on the assumption that "the queue is kept; it drains next sign-in". **Fix:** not fixed yet; see improvements #1. **What to watch:** a technician whose 24h session lapses while the app is open loses the whole shift's queued checks. If the session lapses while the app is *closed*, the queue survives and replays under whoever signs in next.
**Where:** `lib/state/auth_controller.dart:116-125`, `lib/core/offline/background_sync.dart:112`

### Replays are de-duplicated only for successes; uploads never are (2026-09-25)
**What happened:** The `X-Client-Mutation-Id` contract existed only in code on both sides. No doc recorded it. **Cause / contract:** the server's `middleware/idempotency.ts` caches **2xx** responses under `idem:<id>` for 24h and answers a repeat with the stored body plus `X-Idempotent-Replay: true`. Failures are not cached, so replaying a 4xx or 5xx runs the request again. There is no de-dupe if Redis is down, and every upload mints a new file. **Fix:** the app mints the id once at capture time and reuses it on every replay (`api_client.dart:36`, `sync_client.dart:185`). The flush lease keeps two engines from uploading the same photos. **What to watch:** never mint a fresh mutation id on retry. Never let two flushers run at once. A field that applies a change (stock, counters) is not safe to replay after a 4xx.
**Where:** `lib/core/network/api_client.dart:11-39`, server `src/middleware/idempotency.ts:22-61`

### Background engine: never mint a passphrase, never close the DB (2026-09-25)
**What happened:** WorkManager background sync (FR-4.4) runs `SyncClient` in a second Flutter engine that shares the SQLCipher file with the app. **Cause:** a background run creating its own passphrase would make the real DB unreadable. `db.close()` in one engine pulls the shared native connection out from under the other. **Fix:** use `readDbPassphrase()` (read-only), return early if there is no token or no passphrase, leave the DB open, and use a `SyncLease` in `sync_meta` (3-min TTL, renewed after each item) so only one engine drains. **What to watch:** anything else that ever runs headless (a push handler that writes to the DB, for example) must follow the same three rules.
**Where:** `lib/core/offline/background_sync.dart:108-143`, `lib/core/offline/flush_policy.dart:39-78`

### 428 and 401 during a flush must stop the run, not drop items (2026-09-23)
**What happened:** A stale GPS fix (428) or an expired session (401) would have failed every queued item in turn. Each one would have been classified as a 4xx and moved to "could not be saved". **Cause:** the server rejects every mutating request until something outside the queue changes. **Fix:** `classifyFlushFailure` returns `stopRun` for 428 and 401 and keeps the queue. `CheckInController.checkIn()` resumes the flush after a fix lands. **What to watch:** any new "precondition" status the server adds belongs in `stopRun`, not `drop`. Also see the open issue above: the 401 *also* triggers logout, which wipes the queue anyway.
**Where:** `lib/core/offline/flush_policy.dart:20-37`, `lib/core/offline/sync_client.dart:356-390`, `lib/state/checkin_controller.dart:67-71`

### Connectivity events are not a reliable wake-up (2026-09-23)
**What happened:** Tested on a device: the queue never drained after signal came back. **Cause:** `connectivity_plus` `onConnectivityChanged` can fail to emit a clean offline→online transition when a low-capability network (an IMS-only mobile radio) lingers through the outage. **Fix:** a 20s poll in `startAutoFlush` as a backstop, a flush on app resume, and WorkManager's network-constrained job. **What to watch:** don't remove the poll because "the stream handles it". `flushQueue` is cheap to no-op.
**Where:** `lib/core/offline/sync_client.dart:112-132`, `lib/features/shell/technician_shell.dart:71`

### Retrying one queued item must reuse the normal flush logic (2026-09-07)
**What happened:** Sync Center needed a per-item "Sync now". **Cause:** the web first wrote a separate `syncOne` that skipped ordering and locking. **Fix (here):** `flushQueue(stopAfterId:)` drains oldest-first *up to* that item, under the same lock and lease. **What to watch:** don't add a second replay path. Two paths drift, and a single-item replay that jumps the queue breaks RCA → downtime → complete ordering.
**Where:** `lib/core/offline/sync_client.dart:280-290`, `lib/features/sync/sync_center_screen.dart:39-45` · **Source:** client LEARNINGS "Offline-sync view all + per-item resync (2026-09-07)"

### One wording for every queued write (2026-09-08)
**What happened:** Each call site worded the offline toast differently ("Note saved offline…", "Photo saved offline…"). Technicians read them as different events. **Fix:** a single `kOfflineQueuedMessage`. **What to watch:** only show it when the write is actually in `pending_mutations`. The inspection form currently shows it for uploads held only in widget memory (improvements #6).
**Where:** `lib/core/offline/sync_client.dart:24`

### QueueBus must emit a fresh value every time (2026-09-07)
**What happened:** Queue-driven lists stopped refreshing after the first change. **Cause:** a stream of a constant value collapses into an equal `AsyncValue`, and Riverpod stops notifying dependents. **Fix:** emit an incrementing tick. **What to watch:** the same applies to any "something changed" stream feeding a `StreamProvider`.
**Where:** `lib/core/offline/queue_bus.dart:10-17`

### Background prefetch needs an in-flight flag, not just a timestamp (2026-08-31)
**What happened (web):** Opening a work order fired about 10 identical request batches. **Cause:** `prefetchOfflineBundle` checked a `lastPrefetchAt` it read asynchronously and wrote only after finishing, so two callers both passed the check. **Fix (web):** a module-level `prefetching` flag set before the first async read. **What to watch:** the Dart `prefetch.dart` has the **same timestamp-only guard** and can be called from the dashboard and from Profile. Add a flag if duplicate manifest calls show up.
**Where:** `lib/core/offline/prefetch.dart:35-42` · **Source:** client LEARNINGS "Offline prefetch fired duplicate request batches (2026-08-31)"

---

### `syncRequest` only queues on `NetworkFailure`, so an online 5xx loses the write (2026-09-26)
**What happened:** the Snag Assistant server answers `503 SNAG_ENGINE_NOT_ENABLED` until its migration has run. With plain `syncRequest`, that 503 is thrown to the screen while the device is online, and nothing is queued. A surveyor's walk would have been lost.
**Fix:** an opt-in `queueOnServerError: true` on `syncRequest` parks any 5xx exactly like a network failure. Snag writes use it. A 4xx still throws: it is the server saying no, and replaying it cannot help. Separately, the local `snags` table is written *before* the request, and `SnagRepository.resendStranded()` re-queues a create that ran out of retries once `GET /api/snags/engine` says the server is ready.
**What to watch:** any new write whose evidence must survive a server outage (not only no signal) should pass `queueOnServerError: true`. A queued 5xx still goes to the conflict log after `Env.maxMutationAttempts`, which is about 2 minutes at the 20s poll, so pair it with a local copy the user can re-send.
**Where:** [sync_client.dart](lib/core/offline/sync_client.dart) `syncRequest`, [snag_repository.dart](lib/data/snag_repository.dart) `_send`, `resendStranded`


## Auth, session and location gate

### Location check-in: login flag plus a 428 gate on writes only; there is no silent push (2026-09-15)
**What happened:** The first server design sent a 05:00 silent FCM push (`{type:"location_request"}`) that the app should answer with a GPS fix. The same day it was replaced by a login-time check. **Contract:** `POST /api/auth/technician-login` returns `requestLocation: true` when the last fix is missing or older than 24h. Every technician POST/PUT/PATCH/DELETE with a stale fix gets `428 {code:"LOCATION_REQUIRED"}`. GET and HEAD are never gated, and neither are routes using `optionalDecodeToken`. There are **three** exemptions: `POST /fm/technicians/me/location`, `POST /c2o/assets/:id/verify` and `POST /fm/assets/:id/tag-issue` (server `middleware/auth.ts:35-39`; the server doc lists only the first). **Fix (here):** `Session.requestLocation` → `CheckInController` → the full-screen `LocationCheckInGate` → `POST /api/fm/technicians/me/location {lat,lng}` → resume the flush. **What to watch:** don't build a `location_request` push handler; that server LEARNINGS note is obsolete. `LocalNotifications.show` draws *every* data message, so a reinstated silent push would appear as a blank "Fusion Eco" banner.
**Where:** `lib/state/checkin_controller.dart`, `lib/widgets/location_checkin_gate.dart`, `lib/core/network/api_client.dart:46` · **Source:** server LEARNINGS 2026-09-15 (and follow-ups 1–4)

### Settings flags come from one Redis schema; keys it doesn't list vanish (2026-09-09)
**What happened (server):** A flag saved OK but never came back. **Cause:** `ConfigSchema` (server `common/redis.ts`) silently drops keys it doesn't list, on both save and read. `GET /api/auth/config` returns that raw object, not wrapped in `data`. **What to watch:** every flag this app reads (`isAiAgent`, `isCreateAsset`, `isAssetReport`, `isDigitalTwin`, `currencyType`, `currencyRates`) must exist in that schema. `isDigitalTwin` is nullable and opt-out: only an explicit `false` hides 3D. `currencyType` is a symbol ("₹"), not an ISO code.
**Where:** `lib/core/storage/session_store.dart:111-162` · **Source:** server LEARNINGS 2026-06-11 and 2026-09-09

### An unapplied DB column breaks login on a fresh environment (2026-09-15)
**What happened (server):** `technician-login` threw `column "lastLocationLat" does not exist`. **Cause:** the server never auto-runs `npm run sync` (DB-safety rule). **What to watch:** if login or a screen suddenly returns 500 on one tenant after a server update, suspect a missing column (`lastLocation*`, `ai_chat_messages.audio`, `c2o_route_assignments`) before debugging the app.
**Source:** server LEARNINGS 2026-09-15 follow-up 4 and 2026-09-20

---

## Push and notifications

### Pushes are data-only, so the app must draw them itself (2026-09-08)
**What happened:** Nothing appeared and no sound played when a push arrived in the background. **Cause:** the server sends data-only messages `{title, link, entityId, entityType}` with no body, and the OS shows nothing for those. **Fix:** a top-level `@pragma('vm:entry-point')` background handler re-inits Firebase and `LocalNotifications.show()` posts the notification on channel `fcm_default_channel` with the `notification_ting` raw sound. **What to watch:** Android fixes a channel's sound when the channel is created, so a new sound needs a **new channel id**. The tray shows only the title; the full text lives in the in-app list. The device token is deliberately **not** unregistered on logout (phones are personally issued), so a signed-out phone still gets the last user's titles.
**Where:** `lib/core/push/push_service.dart:12-24`, `lib/core/push/local_notifications.dart:14-20` · **Source:** server LEARNINGS "FCM push (Flutter technician app) (2026-09-07)"

### A `link` wins over entity routing, and only `/technician/*` links resolve (2026-09-12)
**What happened (web):** A technician's SLA warning would have opened the admin page. **Cause:** notification routing returns `link` before checking `entityType`, and the server's `slaLink()` built an admin path. **Fix (server):** technician copies carry no `link` and route by `entityType`. **What to watch:** this app returns *no route* for a link outside `/technician`, so a server helper that adds an admin `link` makes the tap silently do nothing. The rules exist twice: `routeForNotification` and `_routeForPushData`. Change both.
**Where:** `lib/core/utils/notification_route.dart:10-42`, `lib/core/push/push_service.dart:99-131` · **Source:** client LEARNINGS "SLA v2 client — a link field silently overrides role-based routing (2026-09-12)"

### Invite notifications open the invites inbox, matched by exact title (2026-08-31)
**What happened (web):** Tapping "New assignment invite" opened the heavy detail page and caused a burst of API calls. **Fix:** route the exact title `"New assignment invite"` (the only title `assignmentInviteService.ts` uses) to the invites tab. **What to watch:** renaming that title on the server silently breaks routing here.
**Where:** `lib/core/utils/notification_route.dart:29-32` · **Source:** client LEARNINGS 2026-08-31

---

## Maintenance orders: checklists, close, invites, AI chat

### The server removed the reactive and annual write routes; the app still calls them (2026-09-12, open here)
**What happened (server):** Annual Maintenance became a read-only view of PM plans (`/analytics`, `/building-compliance`, `/`, `/:id` only). Reactive tickets now generate a work order (`sourceRmId`), and RM `/checklist`, `/time-tracking` and `/status` were deleted. **What to watch (here):** `OrderType.reactive`/`annual` still point `checklistPath`/`completePath` at those routes. Online they 404; offline they queue and are later dropped. `listInvites` still requests `/api/fm/annual-maintenance/technician/:id`, and the 404 is swallowed. Lists, dashboard and calendar already follow the change (work orders only). Before deleting a per-id screen, grep **every** inbound link: notification routing, push routing, QR payloads, invites.
**Where:** `lib/domain/maintenance_record.dart:30-50`, `lib/data/orders_repository.dart:39-67`, improvements #5 · **Source:** server LEARNINGS 2026-09-12 (both entries)

### The signature is a flagged checklist item, required on every close, and rides the queue (2026-09-09)
**Contract:** a signature is item `{id:"signature-<ts>", isOther:true, isSignature:true, isCompleted:true, signatureUrl, signerName, signedAt}` appended to `checklists`. The server's `checklistCloseGuard.ts` returns `422 missing:["signature"]` on every close without one. **Fix (here):** the PNG goes as a `QueuedAttachment` with a `__pending_signature_…__` placeholder inside a whole-record `PUT`, sent before the completion call. **What to watch:** don't "just upload" it directly, because that loses the offline guarantee. When reshaping any flagged item, carry every field (the web lost `isSignature` in five handlers). Whole-record PUTs built from the cached `record.raw['checklists']` can overwrite queued item writes on replay (improvements #3).
**Where:** `lib/data/checklist_repository.dart:263-357`, `lib/features/order_detail/close_sheet.dart:187-226` · **Source:** server/client LEARNINGS "Technician digital signature (2026-09-09)"

### Voice-only send was blocked by three separate checks (2026-09-09)
**What happened:** A voice note with no text couldn't be sent in the Order Assistant. **Cause:** the server returned 400 on an empty `message`. In Flutter, the send button enabled correctly on `hasContent`, but `_send()` re-checked `text.trim().isEmpty` and `ChatController.send()` re-checked `message.isEmpty`. **Fix:** the server accepts text OR audio OR images, and both Flutter checks were relaxed to `hasContent`. **What to watch:** a button that looks enabled can be dead if its handler re-derives a stricter check. Check every layer down to the network call. New attachment kinds must also come back from `GET /api/fm/ai/chat/history`, or they vanish on reopen.
**Where:** `lib/features/order_detail/order_chat_sheet.dart`, `lib/state/chat_controller.dart` · **Source:** server LEARNINGS 2026-09-09 (both voice entries)

### A reactive ticket's lowercase priority hid the root-cause field (pre-2026-09-25)
**What happened:** Critical reactive tickets got `422 rootCause` with no root-cause field on screen. **Cause:** RM stores priority lowercase and the others capitalise it, and the check compared strictly. **Fix:** a case-insensitive `rcaRequiredForPriority`. `_forceRcaVisible` also shows the field whenever the server names `rootCause`, because the server's 422 beats the client's guess. **What to watch:** field shapes differ by record type. Done is `Completed` for WO/RM and `completed` for PM. The technician field is `assignedTechnician` (an id) on WO and `technicianId` elsewhere (RM's `assignedTechnician` is a display name). Normalise case on every cross-type comparison.
**Where:** `lib/domain/downtime.dart:69-78`, `lib/features/order_detail/close_sheet.dart:90-98` · **Source:** server LEARNINGS "ENUM casing differs per table (2026-08-08)"

### A close that committed but answered 500 was reported as failed (pre-2026-09-25)
**What happened:** The technician was told the close failed, but the record was already closed. **Cause:** server `workOrderController.ts` completed the record, then threw on an undefined `status`. **Fix:** on a 5xx from complete, fetch the record and check `completedDate`/`status` before reporting a failure. A retry's 400 "already completed" counts as success (`HttpFailure.isAlreadyCompleted`). **What to watch:** "the request failed" doesn't mean "nothing was written". The flush path doesn't apply `isAlreadyCompleted` yet, so a replayed duplicate close lands in conflicts (improvements #4).
**Where:** `lib/state/close_controller.dart:158-169`, `lib/data/close_repository.dart:75-90`, `lib/core/network/api_exception.dart:40-45`

### Downtime was re-sent when a close was retried (pre-2026-09-25)
**What happened:** A 422 on complete followed by a retry sent the downtime PATCH twice. **Fix:** `_downtimeHandled` lives on the `CloseSubmitter`, one per open sheet, and a test pins it ("downtime is written once, even when the close is retried"). **What to watch:** creating a new `CloseSubmitter` per tap brings the bug back. Downtime is a single `PATCH /api/fm/downtime/:source/:id {startedAt, endedAt, impact}`. When pre-filling from `GET /api/fm/assets/:id/downtime`, match on `source`/`sourceId` and ignore rows with `derived: true`.
**Where:** `lib/state/close_controller.dart:88-97`, `lib/features/order_detail/close_sheet.dart:47` · **Source (contract):** server/client LEARNINGS "downtime_logs removed (2026-08-08)"

### A form field that gets locked must not be pre-filled from the cache (pre-2026-09-25)
**What happened:** The close sheet pre-filled and locked a downtime start from a window that had already been closed. **Cause:** downtime history was read through `syncGet`'s cache. **Fix:** read it with plain `ApiClient`, return `[]` on error, and make the provider `autoDispose`. **What to watch:** anything that *locks* a field must read live data.
**Where:** `lib/data/close_repository.dart:10-32`, `lib/state/close_controller.dart:199-205`

### A cached detail first undid offline writes, then blanked the checklist (pre-2026-09-25)
**What happened:** A cached refetch after an offline write replaced the local list and undid the write. The guard added for that then refused the cache on a cold start, so a real job showed "No checklist items". **Fix:** a cached detail may seed the list only when no local state exists yet. **What to watch:** any provider that mixes server truth with optimistic local patches (for example, an offline photo add followed by pull-to-refresh).
**Where:** `lib/state/checklist_controller.dart:61-84`

### "Other" checklist items need a unique `id` (2026-08-31)
**What happened (web):** Deleting one id-less "Other" item deleted all of them (`undefined !== undefined` is false). **Fix:** ids are `other-<ms>-<7 chars of uuid>`. **What to watch:** every item appended to `checklists` needs a unique id; `signature-<ms>` is unique only per millisecond. `sessions[]` is saved exactly as sent. Sending `faceCaptureUrl` with both `startTime` and `endTime` puts the image in the wrong slot.
**Where:** `lib/data/checklist_repository.dart:281-284` · **Source:** client LEARNINGS 2026-08-31, 2026-07-23

### Close checks answer with 422 `missing[]`; the client's checks are only UX (2026-08-07)
**Contract:** every completion path runs `assertCloseAllowed` and `checklistCloseGuard`, and returns `422 {missing:[…]}` with `checklist`, `signature`, `session` or `rootCause` (Critical/High, case-insensitive). `failureCodeId` is never produced; that feature never existed. The RCA endpoint is `POST /api/fm/{work-orders|preventive-maintenance|reactive-maintenance}/:id/rca {rootCause, rcaNotes}`. Note the **plural** `work-orders` here. **What to watch:** never show an error against a field that isn't on screen. Never wrap a new endpoint in an "empty list on error" fallback without confirming it exists; a swallowed 404 kept a dead failure-code picker alive through three audits.
**Where:** `lib/core/network/api_exception.dart:26-30`, `lib/state/close_controller.dart:66-73` · **Source:** server/client LEARNINGS 2026-08-07 and 2026-08-08

### Declining an invite passes the job along; PM invites must stay reachable (2026-09-02)
**Contract:** respond with `POST /api/fm/{work-order|preventive-maintenance|reactive-maintenance}/:id/assignment/respond {action, reason?}`. A decline moves the job to the next technician in `assignmentChain`, and only an exhausted chain returns to `pending`. The record is never cancelled. **What to watch:** don't treat a decline as final in local state. Preventive maintenance is hidden from the orders list but must stay in the invite fan-out, because its invite is the only way to reach a PM detail page.
**Where:** `lib/data/orders_repository.dart:47-67` · **Source:** server LEARNINGS 2026-09-01/02, client LEARNINGS 2026-08-31

### Work starts from checklist activity, not a button (2026-08-30)
**What happened (web):** A manual "Start Work" button was built and then removed within hours. **Cause:** the server sets In Progress when the first checklist timer starts, and `startedDate` is the earliest session start. **What to watch:** before building any start/stop UI, check what the server already derives. `core/utils/checklist_status.dart` is a port of web `lib/checklist-status.ts` and server `checklistCloseGuard.ts`; change all three together.
**Where:** `lib/core/utils/checklist_status.dart:6-7` · **Source:** client LEARNINGS 2026-08-30

---

## C2O field verification and routes

### The route release warning lives on the phone because the server can't see the queue (2026-09-25)
**What happened:** FR-5.8 wanted "don't hand a route over while the old technician still has unsent checks". Those checks exist only in this app's queue. **Fix:** the server exposes `lastUploadAt` per assignment. The release dialog counts this phone's queued checks ("3 checks still on this phone") and warns without blocking. Checks queue against the asset, not the route, so they still upload after a hand-off. **What to watch:** release is deliberately **not** queued: a release that lands hours late leaves the route unwalked and nobody knows. Flush first, then release online.
**Where:** `lib/features/routes/route_list_screen.dart:271-300`, `lib/data/route_assignment_repository.dart:20-31` · **Source:** server LEARNINGS 2026-09-25 (FR-5.8)

### C2O endpoints use two envelope shapes (2026-09-25)
**Contract:** `c2oRoutes` and the progress routes wrap `{success,data,message}`. `c2oExtendedRoutes` (route assignments, `/mine`) return bare bodies. Errors come back as `{success:false,message}`. **What to watch:** parse through `envelope.dart`'s `unwrap`/`unwrapMap`. "Everything pending, nothing moves" usually means an envelope mismatch.
**Source:** client LEARNINGS 2026-09-25

### A tokenless tag must never hit the public verify route (pre-2026-09-25)
**What happened:** A general Asset label or bare barcode sent to `/public/verify` gets a 403, which would show as a red "token mismatch". **Cause:** those formats never carry a token, and tag tokens are HMACs the server computes (`JWT_SECRET`, 16 hex characters); the phone never computes them. **Fix:** an uncached target with no token returns null and falls through to the general scanner. **What to watch:** "try the server for anything uncached" is the wrong rule for bare barcodes. The printed-tag format (`{web}/public/c2o-verify/{assetId}?t=…`) can't be reissued, so the parser and the server's `buildScanPayload` must stay in step.
**Where:** `lib/core/c2o/c2o_asset_resolver.dart:82-88`, `lib/core/c2o/c2o_scan_payload.dart` · **Source (format):** server LEARNINGS 2026-07-28

### Thin search rows must never be written into the scan cache (pre-2026-09-25)
**What happened:** Manual search builds cache-shaped rows from assigned work orders, which carry little data. Writing them into `c2o_assets` would permanently shadow real scan data, because the cached copy wins later merges. **Fix:** the detail screen fetches `GET /api/fm/assets/:id` instead. **What to watch:** "cache what we just opened" optimisations. `claims` must keep the `{asset:{id,…}, history, openFindings}` wrapper.
**Where:** `lib/features/c2o_search/c2o_asset_search_screen.dart:248-257`, `lib/core/c2o/assigned_assets.dart:38-48`

### BIM assets may carry only `aimData` codes for location (2026-09-20)
**Contract:** assets imported from BIM/AIM can have null `floorData`/`spaceData`, with location only in `aimData.buildingCode`/`levelCode`/`spaceCodeSource`. `locationPath` keeps a level when either its name or its code exists. The machine-readable type is `aimData.assetTypeCode`; `identity.assetType` is a display name. For 3D, `ifcGlobalId` is the asset's real element, while `twinGlobalId`/`isPresentation` describe a stand-in to show. The app reads neither yet. **What to watch:** a screen reading only `floorData?.floorName` is blank for BIM assets. Never zoom a technician to a stand-in without saying so.
**Where:** `lib/core/c2o/asset_detail.dart:46-50` · **Source:** client LEARNINGS 2026-09-20 (three entries)

### Indoor GPS at `.high` accuracy never settles (pre-2026-09-25)
**What happened:** Location capture kept timing out in plant rooms. **Cause:** `.high` waits for a GPS-grade fix. **Fix:** `.medium` with a 10s limit, then fall back to the last known position. A geocoding failure never loses the coordinates. The check-in uses the same sequence on purpose. **What to watch:** "better GPS" changes under FR-3.9.
**Where:** `lib/core/capture/capture_services.dart:209-230`, `lib/core/location/checkin_location.dart:18-52`

### The voice recorder and live speech recognition can't share the mic on Android (pre-2026-09-25)
**What happened:** Auto-transcribing while recording produced about 0.14s of audio for a 4s clip. **Cause:** Android gives the microphone almost exclusively to one listener, and the recognizer only works on a live stream. **Fix:** the voice note is recording-only and notes stay typed. **What to watch:** verify by pulling the recorded file, not by looking at the UI. Separately, the field-verification clip never reaches the submission today (improvements #7).
**Where:** `lib/features/field_verification/voice_note_capture.dart:13-31`

### Capture-form autosave never switched on for a brand-new form (pre-2026-09-25)
**What happened:** With no prior draft, edits were never saved. **Cause:** `_draftLoaded` was set only in the restore branch. **Fix:** also set it when there is no draft. `dispose` flushes a pending debounce instead of cancelling it. **What to watch:** any early return or throw in `_loadDraft` (for example, `byName` on a renamed enum in an old draft) leaves autosave off.
**Where:** `lib/features/field_verification/field_verification_screen.dart:97-122`

### Nameplate OCR took "Number" as the serial (pre-2026-09-25)
**Cause:** overlapping labels were tried shortest-first, so "SERIAL" matched inside "Serial Number". **Fix:** try labels longest-first and stop after the first match. A test pins it. **What to watch:** adding short labels like "NO".
**Where:** `lib/core/ocr/nameplate_ocr.dart:58-78`, `test/nameplate_ocr_test.dart:62`

---

## Flutter, UI and i18n

### Never `push` a bottom-nav branch route (2026-09-07)
**What happened:** The app crashed with `!keyReservation.contains(key)`. **Cause:** pushing a `StatefulShellRoute` branch path onto the root navigator reserves that branch's navigator key a second time. **Fix:** switch branches (`dashboard`, `overview`, `orders`, `invites`, `profile`) with `context.go`. `Routes.isShellBranch()` exists for this check. **What to watch:** notification or deep-link handlers that `push` a route they got from the server.
**Where:** `lib/app/router.dart:108-121`

### The language reverted to English after switching tabs (2026-09-09)
**What happened:** Arabic reverted to English after moving between bottom-nav tabs. **Cause:** screens read `FlutterLocalization.instance.currentLocale` directly. The package's delegate freezes its string table at construction, and the shell's indexed-stack rebuilds let it drift from `currentLocale`. **Fix:** `LocaleController` is the only caller of `translate()`, and every widget watches it. `Directionality` is pinned explicitly in `app.dart`. **What to watch:** never read or set the locale through the package singleton.
**Where:** `lib/state/locale_controller.dart:6-62`, `lib/app/app.dart:73`

### An i18n key can be missing from both files at once (2026-09-25, open)
**What happened:** `common.pull_down_to_retry` is used in three screens but exists in neither `en.json` nor `ar.json`. **Cause:** only en and ar were compared with each other (both have 595 keys and match). **Fix:** not fixed. Add the key, plus a test that checks every `'x.y'.getString` literal in `lib/` against `en.json`. **What to watch:** key-parity checks alone can't catch this.
**Where:** `lib/features/profile/profile_screen.dart:130`, `lib/features/invites/invites_screen.dart:101`, `lib/features/notifications/notifications_screen.dart:88`

### Device-specific Flutter traps (pre-2026-09-25)
- **`PopupMenuButton` pops the whole screen on OPPO Android 16:** the system injects `KEYCODE_BACK` when the menu opens. Use an `IconButton` plus a confirm dialog instead (`lib/features/routes/route_list_screen.dart:429-433`).
- **A horizontal `ListView` inside a `Row` paints nothing, with no error dialog:** it gets unbounded width. Wrap it in `Expanded` plus a fixed-height `SizedBox` (`lib/features/scanner/scanner_screen.dart:903-907`).
- **`InteractiveViewer` defaults make large floor plans unreachable:** use `constrained: false` at native size, fit on the first frame, and draw the pin as a screen-space overlay (`lib/features/floor_plan/floor_plan_screen.dart:217-284`).
- **A proxy 502/504 HTML page must not become the error text:** `mapDioException` drops markup bodies (`lib/core/network/api_exception.dart:83-89`).

---

### `TechCard` is a `DecoratedBox`, so a `ListTile` or `ExpansionTile` inside it asserts (2026-09-26)
**What happened:** the snag survey and raise screens put `ListTile`s straight inside `TechCard`. A widget test failed with "ListTile background color or ink splashes may be invisible". On a device the ripple silently doesn't show.
**Fix:** wrap the card's content in `Material(type: MaterialType.transparency)`.
**What to watch:** any tile-style widget (ListTile, ExpansionTile, CheckboxListTile) inside `TechCard`. The sheets are fine because `showModalBottomSheet` provides a Material.
**Where:** [snag_survey_screen.dart](lib/features/snags/snag_survey_screen.dart), [snag_raise_screen.dart](lib/features/snags/snag_raise_screen.dart)

### Widget tests at 320–360 px in Arabic find overflows that English hides (2026-09-26)
**What happened:** the Snag hub passed in English and overflowed by 13 px in Arabic. The cause was a section-title `Row` whose text had no `Flexible`. The test font draws every glyph as a full em square, so it is harsher than Montserrat, and that is useful: it stands in for large system font sizes. A fixed-height walk card and the waiting-card strip overflowed the same way.
**Fix:** `Flexible` plus ellipsis on titles in rows, `minHeight` instead of `height` on cards holding text, and taller horizontal strips.
**What to watch:** `tester.takeException()` gives only the one-line summary. To find the culprit, temporarily point `FlutterError.onError` at `print` in a scratch copy of the test. The details include "The relevant error-causing widget was: Row file:///…:586". Screen tests should scroll lazily built lists (`scrollUntilVisible(..., scrollable: find.byType(Scrollable).first)`), or rows below the fold are never built or checked.
**Where:** [test/snag_screens_test.dart](test/snag_screens_test.dart), [snag_hub_screen.dart](lib/features/snags/snag_hub_screen.dart) `_SectionTitle`

### Round-tripping the i18n JSON through a parser reformats other people's lines (2026-09-26)
**What happened:** adding keys with `json.load` → `json.dump` removed the blank-line grouping in `en.json`/`ar.json` and produced a 72-line diff in strings nobody touched.
**Fix:** append new keys to the file as text before the closing `}`, then re-parse only to validate.
**What to watch:** check `git diff --stat assets/i18n/` after any scripted key addition. Only your own lines, plus one comma, should change.


## Platform, build and release

### The committed default API host is a developer's LAN IP (2026-09-21 → 2026-09-25, open)
**What happened:** `env.dart`'s default moved from the dev host to `http://192.168.0.x:5002` and changed four times in five days (`a776fd3`, `8abd825`, `cacb3d1`, `0623005`). **Cause:** the default was edited instead of passing `--dart-define`. **What to watch:** a plain `flutter build appbundle` ships a private-IP `http` host, and cleartext is allowed app-wide (`AndroidManifest.xml:22`). Always pass `API_BASE_URL` **and** `WEB_BASE_URL` (no `/api` suffix). The login screen's server override changes only the API host and applies after a restart; it is also visible in release builds.
**Where:** `lib/app/env.dart:4-19`, `lib/features/login/login_screen.dart:449-460`

### A release build without a keystore silently signs with the debug key (pre-2026-09-25)
**What happened:** With no `android/key.properties`, `bundleRelease` still succeeds, signed with the debug key. The macOS checkout has neither `key.properties` nor the `.jks`, which live on the Windows machine. **What to watch:** always run `jarsigner -verify` on the AAB. Bump the `+BUILD` part of `pubspec.yaml` on every Play upload and record it in `VERSIONING.md`, which currently stops at build 2 while pubspec is at `+3`. New Firebase SHA fingerprints are needed per keystore, or FCM fails on release builds.
**Where:** `android/app/build.gradle.kts:60-66`, [VERSIONING.md](VERSIONING.md), [RELEASE_INFO.md](RELEASE_INFO.md)

### Windows-only Gradle workarounds came along to macOS (pre-2026-09-25)
**What happened:** Every Android subproject is pinned to NDK `30.0.16138531`, with `kotlin.incremental=false` and an 8 GB heap. `build.gradle.kts.bak` is the file from before the pin. **Cause:** the Windows machine had a partial newer NDK download and failing Kotlin cache closes. **What to watch:** the first Mac Android build needs that NDK installed (only 26.x is present) or the pin re-evaluated.
**Where:** `android/build.gradle.kts:18-28`, `android/gradle.properties`

### This Mac can't run the toolchain yet (2026-09-25)
**What happened:** `flutter pub get` fails the SDK constraint. **Cause:** the zsh `flutter` alias points to a path that doesn't exist (`~/.zshrc:131-132`), and `~/.zshrc:6` has a PATH entry missing its leading `/`. The newest SDK installed is 3.19.3, while `pubspec.lock` needs Flutter ≥ 3.44.0 / Dart ≥ 3.13.2. **What to watch:** any "analyze clean / tests pass" claim made from this Mac right now is unverified. Install Flutter 3.44+ first.

---

### A working Flutter toolchain can be bootstrapped in the session scratchpad (2026-09-26)
**What happened:** the Mac's installed SDKs are too old for `pubspec.lock`, and the disk is nearly full, so a full install isn't possible. The Snag Assistant still needed `flutter analyze` and `flutter test`.
**Fix:** download `flutter_macos_arm64_3.47.5-stable.zip` (Dart 3.13.4) into the scratchpad, then `unzip -x` everything not needed: `.git`, `.pub-preload-cache`, `dev/`, `examples/`, `flutter_web_sdk`, and every engine artifact except `darwin-x64` and `common`. That leaves about 1.1 GB. Then:
1. `git init -b stable` plus an empty commit, tagged `3.47.5`, with origin set to the GitHub URL. The tool refuses to run without a git checkout.
2. `mkdir dev examples`. `flutter analyze` lists them.
3. Export `FLUTTER_PREBUILT_ENGINE_VERSION=<bin/cache/engine-dart-sdk.stamp>`. Without it, the fake repo changes the computed engine hash and the tool moves `dart-sdk` aside to re-download it.
4. Export `PUB_CACHE=<scratchpad>/pub-cache`, so nothing is written to `~`.

`flutter pub get --enforce-lockfile` left `pubspec.lock` unchanged. `dart analyze` and `flutter test --no-pub` then work.
**What to watch:** extract selectively. Keeping the zip and doing a full unzip together filled the disk. macOS has no `timeout` command; use the tool's own timeout, and never run two `flutter test` processes at once, because they fight over the startup lock and both appear hung. It is session-only: the scratchpad is wiped afterwards.
**State:** results obtained this way count as real Flutter ≥ 3.44 runs for the CLAUDE.md verification rule.

### No-download type check and pure tests when even the slim SDK can't be fetched (2026-09-26)
**What happened:** the AR build ran under a no-downloads, no-installs rule (about 4 GB free), so the slim 3.47.5 recipe above was off the table. Three agents still needed their Dart checked.
**Fix:** two scratch-only harnesses, both offline:
1. **Type check of all of `lib/` and `test/`** with the installed Flutter 3.19.3 analyzer. Put a copy of `lib/` and the tests in a scratch package named `technician_portal`. Use the real `flutter_riverpod` 2.6.1, `go_router` 14.6.2, `dio` 5.9.0 and `uuid` 4.5.1 (all already in `~/.pub-cache`) and `flutter pub get --offline`. Every other plugin gets a path stub. `flutter_localization` 0.4.x needs Dart ≥ 3.5, so stub `getString`. Generate a `LucideIcons` stub from the locked 3.1.17 icon list. Stub `flutter_test` as `export 'package:test/test.dart'` plus `TestWidgetsFlutterBinding` and `TestDefaultBinaryMessengerBinding`, with the real signatures. Rewrite Dart 3.8 null-aware elements (`?x`, `'k': ?x`, inline `[a, ?b]`) to `if ((x) != null) (x)!` with a bracket-aware scanner. A line regex misses the inline forms. Then filter out the known noise: `Color.withValues`, `Switch.activeThumbColor`, duplicate wildcard `_` params (Dart 3.7), and the rewrite's own `unnecessary_non_null_assertion`.
2. **Pure tests** with the Dart 3.3.1 in `/Users/kavin/flutterr/flutter/bin/cache/dart-sdk`: swap `flutter_test` for `package:test` 1.24.9 and strip the groups that need a Flutter binding.
It caught real bugs: a missing method, unused imports, and an `unnecessary_import` of `dart:typed_data` (Flutter's `services.dart` re-exports `Uint8List`).
**What to watch:** this is **not** a Flutter ≥ 3.44 run. It checks types and pure logic only: no widget tests, no flutter_lints 6 rules, Dart 3.3 language. Report it as "type check on 3.19" and keep the PENDING item open until a real run.
**Where:** session scratchpad `fvcheck/run.sh`, `fvcheck/downgrade2.py`, `fieldops-core/dartcheck/sync.sh` (wiped with the session).


## AR BIM overlay (v1 built 2026-09-26; first Android device run 2026-09-26)

Full plan: [docs/ar-bim-overlay.md](docs/ar-bim-overlay.md). These are the findings from the 2026-09-25 design pass that would otherwise have to be rediscovered.

### fe_ar on a real room: what broke alignment and visibility, and what fixed it (2026-09-26)
**What happened:** after the first build ran, a day of device tests in a plain painted bedroom (OnePlus 7 Pro, no depth sensor) found, in order:
1. **Platform view mode.** Hybrid Composition (`PlatformViewLink` + `initExpensiveAndroidView`) does NOT work with SceneView: HC merges Flutter's raster thread into the main thread, which then owns the GL context each frame, and ARCore's `session.update` throws `MissingGlContextException` (black camera). HC + SurfaceView was black too (the surface sits behind the window). Keep `AndroidView` (texture-layer) + fe_ar `TextureView`; the `EGL_BAD_ALLOC … already connected` logged on a window resize there did not stop rendering.
2. **Model drawn before it was placed.** The native root starts at identity = the session origin; tiles loaded on download, so the model appeared "somewhere random". Now hidden until the first `setModelTransform` (TileRenderer `placed`).
3. **Wrong first corner.** The default target was the top-ranked candidate — a structural column's *outside* corner — and `firstCorner` never compared shapes. Inside corners now rank first and a mismatched snap switches to the best candidate of the same shape; phones show the plan on the corner-1 card (every inside corner of a rectangular room looks alike).
4. **Floor height.** "Lowest horizontal plane" picked false planes 27 cm under the floor; "largest" then flipped between two planes ~10 cm apart. Now: largest, sticky (switch only for 1.5× area), and Dart ignores a plane > 12 cm from the floor the observations imply.
5. **Drift.** Corner snaps had no native anchor, so ARCore map corrections slid the model. `anchorAt` pins each committed corner; `anchor` events refit like boards.
6. **Plain walls.** ARCore finds no vertical planes on an evenly painted wall; corner snaps fall back to `floorTap` (crosshair on the floor + one nearby vertical surface for heading — maybe a cabinet). One such corner is only a rough placement: use two corners ≥ 3 m apart (heading from positions) or printed boards.
7. **Pale, single-colour model.** `fe_feature.filamat` wasn't compiled (fallback overwrote the tiles' per-discipline colours with one layer cyan), and slabs drew solid over the ceiling. matc 1.72.1 from `filament-v1.72.1-mac.tgz` (47 MB) compiles both materials in seconds; Dart now tints MEP per discipline and ghosts slabs/roofs/coverings/footings.
8. **Blurry camera.** The camera config was chosen by CPU image size; choose by GPU texture size (what's drawn), then CPU.
**Still open:** the overlay looked screen-locked on device (P-012); a per-2 s `camera check` debug log (Filament camera vs ARCore pose) was added to prove or rule it out.
**Where:** `packages/fe_ar/android/.../{FeArController,TileRenderer,MarkerDetector,FeArPlatformView}.kt`, `lib/state/ar_session_controller.dart`, `lib/state/ar_setup_controller.dart`, `lib/core/ar/corner_matcher.dart`

### fe_ar first device build: four blockers, none of them in our AR logic (2026-09-26)
**What happened:** enabling `packages/fe_ar` and building on a OnePlus 7 Pro (Android 11, ARCore 1.56) hit four failures in a row before the camera showed a model.
1. `Failed to find target with hash string 'android-37'`. **Cause:** API 37 installs as `platforms/android-37.0` (minor API levels), so the bare `compileSdk 37` hash does not resolve. **Fix:** plugin `compileSdkVersion "android-37.0"`; app `compileSdk { version = release(37) { minorApiLevel = 0 } }` (AGP 9 DSL).
2. `checkDebugAarMetadata`: 11 issues. **Cause:** SceneView 4.39 and its Compose/AndroidX artifacts require every consumer to compile against 37; the app was on `flutter.compileSdkVersion` (36). **Fix:** the app DSL above. `minSdk`/`targetSdk` stay Flutter's.
3. Crash on opening AR: `ViewTreeLifecycleOwner not found from io.flutter.embedding.android.FlutterView`. **Cause:** setting the lifecycle/saved-state owners on our `ComposeView` is not enough. Compose installs a *window recomposer* on the window's content root, which under Flutter is `FlutterView`, and looks up the lifecycle there. **Fix:** give the ComposeView its own `Recomposer` on `AndroidUiDispatcher.CurrentThread` and `setParentCompositionContext(recomposer)`; cancel both in `dispose()`.
4. `eglCreateWindowSurface … already connected to another API` / `EGL_BAD_ALLOC` on every window resize (navigation bar, app switch). **Cause:** `AndroidView` uses texture-layer hybrid composition, which moves the platform view onto a new Surface on resize; Filament could not reattach its swap chain. **Fix:** Android now uses `PlatformViewLink` + `initExpensiveAndroidView` (Hybrid Composition) with fe_ar `surface: 'surface'` (a real SurfaceView).
**What to watch:**
- The build pulls ~280 MB of native libs into the debug APK (Filament, gltfio, ARCore, ML Kit); install over wireless adb takes ~100 s and the Mac needs a few GB free (the disk filled mid-session).
- ARCore logs are noisy and harmless: `API key … could not be obtained` (cloud anchors only), `feature_track_ml_depth_provider` errors (depth warm-up), `No usable local profile`, online-recalibration file missing.
- Without `fe_feature.filamat` (needs Filament 1.72.1 `matc`) tiles draw with gltfio materials tinted per layer: no progress colours, x-ray or section. The log says so once per session (`W/fe_ar`).
- `flutter run` over wireless adb often loses the VM service after install ("Lost connection"); the app keeps running. `adb install -r` + `adb shell monkey -p com.fusionapps.fieldops 1` and `adb logcat` are more reliable for device checks.
**Where:** [FeArPlatformView.kt](packages/fe_ar/android/src/main/kotlin/com/fusionapps/fe_ar/FeArPlatformView.kt), [ar_view.dart](lib/core/ar/ar_view.dart), [packages/fe_ar/android/build.gradle](packages/fe_ar/android/build.gradle), [android/app/build.gradle.kts](android/app/build.gradle.kts)
**Project state:** camera + model overlay render on Android; the overlay is **not yet registered to the room** (it appears at an arbitrary place). PENDING P-012.

### Demo mode must be switchable from the dashboard, not only from failure screens (2026-09-26)
**What happened:** a tester with the build (no fe_ar) could not find Demo. The Demo offer lived only on the AR-unavailable view and at the bottom of the building list, and a checked-in technician's "Floor" goes straight to the site's floors (the "no floors" state even passed `showDemo: false`).
**Fix:** a Demo pill on the dashboard AR card (`ar.dashboard.demo`), and the no-floors state offers Demo too.
**What to watch:** any mode switch reachable only from an error or empty state is invisible to the people most likely to need it. Put it on the entry surface.
**Where:** [ar_entry_widgets.dart](lib/features/ar/widgets/ar_entry_widgets.dart) `_DemoToggle`, [ar_models_screen.dart](lib/features/ar/ar_models_screen.dart)

### A demo room IFC that passes the real AR pipeline (2026-09-26)
**What happened:** there was no small model to test the whole flow in a real room. A stdlib-only generator now writes an IFC4 bedroom (structure, walls/door/window, built-in lofts, concealed electrical, plumbing, refrigerant, fire) and it passes the server's `buildTilesFromIfc` + QA gate locally (85/85 elements meshed, 6 tiles, 3 inside corners, 1 board suggestion).
**What to watch (authoring rules the pipeline enforces):** storey `Name` must equal the FusionEco floor name (or link it on AR Markers); `IfcFurniture` is skipped by AR, so fixed joinery the user should align against goes in as `IfcBuildingElementProxy` (drawn as edges); keep window sills above the 1.01 m plan cut; STEP strings must be ASCII (`\X2\hhhh\X0\` for anything else); GlobalIds deterministic (uuid5) so re-uploads keep boards and progress.
**Where:** `../IFC Models/FusionEco_Demo_Bedroom/` (generator, IFC, README walkthrough — outside the repos)

### `bim_elements` carries no geometry, so the server has no mesh to send (2026-09-25)
**What happened:** the AR plan assumed the existing IFC pipeline could feed an overlay. It can't. `ifcExtractor.ts` imports `web-ifc` but uses only its attribute APIs — `bim_elements` stores property sets, containment and classifications, and `hadRepresentation` is a **boolean**, not a mesh. `building_3d_models.fileUrl` points at the raw IFC, not at anything a phone can draw. **What to watch:** any "we already have the model" claim about BIM features. Tessellation, glTF authoring, chunking and a `nodeIndex → globalId` map are all new work (AR-5 … AR-8). The identity model is the part that already exists.
**Where:** `../fusion-eco-server/src/services/bim/ifcExtractor.ts:1`, `../fusion-eco-server/src/model/bim-element.ts:19`

### The two obvious ARCore features are both the wrong tool here (2026-09-25)
**What happened:** ARCore offers Cloud Anchors (persistent shared alignment) and Augmented Images (marker tracking). Both look like the answer and both were rejected. **Cause:** Cloud Anchors needs a Google Cloud project and **a network round trip to resolve** — FieldOps exists because plant rooms have no signal, so a hosted anchor service is an architectural contradiction, not just a quota question. Augmented Images wants feature-rich, non-repeating artwork and scores QR codes poorly; it also needs a pre-built image database, so adding a marker on site would need an app release. **The fix:** take the four corner points the platform barcode detector already returns (ML Kit on Android, Vision on iOS), and solve the planar pose in our own Dart. One code path, any marker, no database, no network.
**Where:** [docs/ar-bim-overlay.md §2.2, §4.2](docs/ar-bim-overlay.md)

### Only four degrees of freedom are unknown, and two of them must be thrown away (2026-09-25)
**What happened:** the BIM→world transform looks like a 6-DoF problem and is really 4-DoF: ARCore/ARKit build a gravity-aligned world frame and IFC is Z-up, so the accelerometer supplies pitch and roll. That is why a single marker suffices. **What to watch:** a planar PnP solve returns all six, and its pitch/roll are the noisy components at oblique viewing angles. Keep the yaw, take pitch and roll from gravity, re-orthonormalise. Skipping that step is the difference between an overlay that sits still and one that visibly swims. Yaw error is also the dominant accuracy term because it pivots the model about the marker — 1° is 17 mm at 1 m but 350 mm at 20 m, which is why the design wants many markers rather than one good one.
**Where:** [docs/ar-bim-overlay.md §3.1, §4.2, §5](docs/ar-bim-overlay.md)

### Re-centring the model on export silently breaks every stored coordinate (2026-09-25)
**What happened:** real models sit at site eastings/northings in the hundreds of thousands, which destroys float32 precision in a renderer, so exporters re-centre near the origin. **What to watch:** if marker poses, element centroids or camera poses are not shifted by that **same** offset, the overlay lands kilometres away and it looks like an AR tracking bug. Rule adopted: resolve `IfcMapConversion`/`IfcSite` once at export, write the offset to `building_3d_models.metadata`, and serve everything in that re-centred frame thereafter. One conversion, one place.
**Where:** [docs/ar-bim-overlay.md §3.3](docs/ar-bim-overlay.md), `../fusion-eco-server/src/model/building-3d-model.ts:10`

### AR packs make two open queue/cache bugs load-bearing (2026-09-25)
**What happened:** the AR pack is a route pack with geometry in it, so it inherits `route_download_service`'s behaviour — including improvements.md **#14**, where `If-None-Match` is never sent and a download REPLACEs rather than merges. At route-pack size that is wasteful; at 60 MB a storey it is unusable. Likewise **#1**, where logout (any 401) wipes the queue: an AR finding is the most expensive capture to lose, because reproducing it means walking back to the spot. **What to watch:** fix #14 before AR-14 ships and #1 before AR-19 ships. Also: GLB chunks go on disk referenced by path, never base64 in a SQLite row — that habit already costs the Sync Center an O(n²) decode (#12).
**Where:** [docs/improvements.md](docs/improvements.md) #1, #12, #14; [docs/ar-bim-overlay.md §8](docs/ar-bim-overlay.md)

### v2 revision: yaw comes from marker *positions*, not marker orientation (2026-09-25, supersedes part of an entry above)
**What happened:** v1 of the AR plan (and the entry above, "Only four degrees of freedom are unknown…") took yaw from each marker's own orientation, and replaced the transform whenever a new marker was scanned. On review, that orientation is the noisiest quantity measured: about 0.5–2° from a 200 mm target, which is 175–700 mm at 20 m. **Fix adopted in v2:** keep every marker seen in the tracking session as a native anchor, and fit yaw and translation by closed-form 4-DoF weighted least squares on their **positions**. Error falls roughly as `σ_p / (r_rms·√n)`: two markers 5 m apart give about 0.16°, and four around a room about 0.05°. A single marker's yaw comes from the tracked wall-plane normal, and PnP is used only as a down-weighted fallback. **What to watch:** "re-anchor to the nearest marker" throws information away, so combine observations instead. Residuals then give *measured* quality and catch a moved marker automatically. The gravity point in the entry above still holds.
**Where:** [docs/ar-bim-overlay.md §4.3–4.4](docs/ar-bim-overlay.md)

### The web twin FieldOps embeds runs on AGPL-3.0 code (2026-09-25, open)
**What happened:** checking whether AR could reuse the web twin's geometry turned up `@xeokit/xeokit-sdk` 2.6.109 (package licence **AGPL-3.0**) in at least 11 client components, and `@xeokit/xeokit-convert` (AGPL-3.0 LICENSE file) run by `app/api/digital-twin/convert-ifc/route.ts`. The technician twin page that `twin_screen.dart:57` opens in a WebView is one of those components. **What to watch:** it conflicts with the no-licence requirement unless a commercial xeokit licence is held. That is a licensing-owner decision (Track W, W-1), not an engineering fix. Until it's decided, never build new features on XKT or `convert2xkt`. AR builds from source IFC with web-ifc (MPL-2.0), so models that exist **only** as `.xkt` can't be used in AR until someone uploads their IFC.
**Where:** `../fusion-eco-client/package.json`, `../fusion-eco-client/components/digital-twin/TwinLiteViewer.tsx`, [docs/ar-bim-overlay.md §2.3](docs/ar-bim-overlay.md)

### The app has no IFC GlobalId, and the server's asset ↔ element join has a confidence (2026-09-25)
**What happened:** v1 assumed tap-to-identify and "show this asset" could rely on the element ↔ asset join as fact. Nothing in `lib/` mentions a GlobalId, and route-pack assets don't carry one (`route_pack.dart:41`). On the server the join is `assets.ifcGlobalId` plus `asset_mappings` with `confidence` and `method: auto | human | imported`. **What to watch:** highlighting a low-confidence automatic match as *the* asset sends a technician to the wrong valve. Show confidence, list candidates, and turn an aligned field identification into a human confirmation. Any feature that needs the join on the device first needs an additive field on route-pack assets (AR-12).
**Where:** `../fusion-eco-server/src/model/asset.ts:105`, `../fusion-eco-server/src/model/asset-mapping.ts:10`

### IFC → glTF needs an axis swap as well as a re-centre, and web-ifc already does the re-centre (2026-09-25)
**What happened:** v1 covered the far-from-origin re-centring but not the axis swap. IFC is Z-up; glTF and ARCore/ARKit are Y-up. `(x, y, z) → (x, z, −y)` must happen exactly once, at export. The installed web-ifc 0.0.77 already has `COORDINATE_TO_ORIGIN` and `GetCoordinationMatrix()`, so the re-centring offset comes from the library rather than hand-written maths. `ifcExtractor.ts:186` calls `OpenModel` with default settings (attributes only), so the geometry build must open the model with its own settings. **What to watch:** keep one golden-vector JSON that both the TypeScript and Dart tests assert, so the server and the app can't disagree about frames without a test failing.
**Where:** [docs/ar-bim-overlay.md §3](docs/ar-bim-overlay.md), `../fusion-eco-server/src/services/bim/ifcExtractor.ts:186`

### One scene node per BIM element doesn't scale on a phone (2026-09-25)
**What happened:** v1 planned a `nodeIndex → globalId` map with one node per element. A single storey can hold tens of thousands of elements, which means tens of thousands of draw calls, against about 100–200 a mobile GPU manages. **Fix adopted:** spatial tiles merged by material, a per-vertex `_FEATURE_ID_0` (EXT_mesh_features), and a feature-state texture for highlight and visibility, so identity survives the merge and a highlight costs one texture upload. Architecture is drawn as edges only, which also works as a live alignment check. Whether Filament reads the custom attribute and extensions in this setup is unverified until AR-2, and §5.4 lists the fallback.
**Where:** [docs/ar-bim-overlay.md §5.3–5.4](docs/ar-bim-overlay.md)

### xeokit decision: remove it, open source only (2026-09-25)
**Decision:** the user ruled out a commercial xeokit licence. The web twin moves to three.js (MIT) on the shared glTF tiles (Track W, W-1…W-4 in [docs/ar-bim-overlay.md §11](docs/ar-bim-overlay.md)). This settles the open question in the entry "The web twin FieldOps embeds runs on AGPL-3.0 code" above. **What to watch:** only permissive licences (MIT, Apache-2.0, BSD; MPL-2.0 for web-ifc). Add a CI licence scan so no AGPL or GPL package comes back in through a transitive dependency.

### Filament's glTF loader doesn't read EXT_mesh_features or EXT_mesh_gpu_instancing (2026-09-25)
**What happened:** v2 of the AR plan put per-vertex feature IDs in `_FEATURE_ID_0` (EXT_mesh_features) and relied on EXT_mesh_gpu_instancing. Checked against the Filament README: gltfio supports KHR_mesh_quantization and EXT_meshopt_compression (plus Draco and the KHR material extensions), and **neither of those two**. **Fix adopted in v3:** a tile-local feature index in `TEXCOORD_1` (an unsigned 16-bit integer through KHR_mesh_quantization, excluded from gltf-transform's quantize step so it stays exact) plus a per-tile index → `featureId` table. Repeated geometry is expanded at export, with Filament's `InstanceBuffer` API as the later option. **What to watch:** before choosing any glTF extension for the tiles, check it against Filament's supported list, and remember three.js must read the same file for the web twin.
**Where:** [docs/ar-bim-overlay.md §5.4](docs/ar-bim-overlay.md)

### iPad support rules out WebXR; AR is native, with Filament on both platforms (2026-09-25, decision)
**What happened:** the user made iPhone and iPad first-class targets for a product with no licences. Researched in September 2026: Chrome on Android has full WebXR AR (hit-test, anchors, depth, DOM overlay, raw camera access since Chrome 107), but **Safari on iPhone and iPad has no `immersive-ar`** and no public timeline, and **Android WebView has no WebXR** either, so a web page can't do AR inside FieldOps. RealityKit loads **only USDZ, not glTF** (GLTFKit2, MIT, converts), so it would need a second material and a second tile path. **Decision:** ARCore and ARKit for tracking, **Filament for rendering on both** (Android through SceneView, which is actively released; Sceneform was archived in March 2026; iOS follows Google's official `ios/samples/hello-ar`). RealityKit + GLTFKit2 is the iOS fallback if AR-37 fails. **What to watch:** FieldOps doesn't launch on iOS yet (Track I). LiDAR iPads get the best hit-tests on plain walls.
**Where:** [docs/ar-bim-overlay.md §0, §2.4, §11](docs/ar-bim-overlay.md)

### Marker QR: an upper-case short URL keeps it at version 2, and A4 can't hold a 200 mm QR (2026-09-26)
**What happened:** designing the printed marker board showed two sizing errors in the earlier AR plan. (1) A4 portrait is 210 mm wide, so a 200 mm QR plus a textured frame can't fit. The real A4 board is a **115 mm QR inside a 170 mm frame**; A3 takes 170 mm. (2) The payload decides the module count. At error-correction level M, a version 2 QR (25 × 25) holds 38 characters in **alphanumeric** mode but only 26 in byte mode. An **upper-case** URL (`HTTPS://<HOST>/M/7K3QX9-M`) stays alphanumeric, which gives 4.6 mm modules at 115 mm, readable from about 2 m. **What to watch:** keep the printed host to 19 characters or fewer. Match `/M/<code>` without regard to case on the server. Keep the check character inside the base32 alphabet (Crockford's own check symbols `~` and `=` aren't QR-alphanumeric). Choose the host before the first print run; boards last for years.
**Where:** [docs/ar-markers-and-qr.md §2](docs/ar-markers-and-qr.md)

### Store marker poses in project coordinates; FusionEco floors already solve federated levels (2026-09-26)
**What happened:** a marker pose stored in tile coordinates would break on every new model build, because re-centring and tiling can change. **Rule:** store the pose in project (IFC world) coordinates, derive the tile-frame pose for each build, and flag a marker `needs-review` only when its host wall or column actually moved. Separately, the "which level is this" problem across architectural and MEP IFCs is **already solved**: `bim_spaces` matches storeys and spaces to FusionEco `floorId` / `spaceId` (`../fusion-eco-server/src/model/bim-space.ts:30`). Key markers, manifests and route scopes on `floorId`, not on storey GlobalIds, which differ between models of the same building.
**Where:** [docs/ar-markers-and-qr.md §3](docs/ar-markers-and-qr.md)

### GAMMA's QR codes are registered after a corner alignment, not planned in the office (2026-09-26)
**What happened:** the AR plan assumed, as GAMMA was first described, that alignment starts from QR markers planned on the model and installed before anyone scans. GAMMA's own help centre, blog and FAQ say otherwise. The primary method is **corner alignment**: a pin that auto-snaps to real wall and column corners and edges, with LiDAR finding hidden corners. A QR code is "registered" **after** a successful corner or gridline alignment, as a sticker whose position is captured on site. **Fix adopted:** markerless-first. Snap two corners (one corner already gives position and heading), then "leave a board": a spare board bound to the current fit. Office-planned networks become optional. **What to watch:** don't make preparation a precondition for a first AR session; that's the friction GAMMA avoided. Prefer structural corners (columns, load-bearing and external walls), because drywall moves in fit-outs. Take height from the floor plane plus a per-floor finish offset, never a manual vertical nudge.
**Where:** [docs/ar-setup-and-gamma-parity.md §1–2](docs/ar-setup-and-gamma-parity.md)

### Feature ids are dense per build: every feature-state texture and target must name its build (2026-09-26)
**What happened:** the first workspace sent one feature-state texture and `setTarget(ids)` with no build. With architecture and MEP both loaded, id 12 is a wall in one build and a pipe in the other. `fe_ar` applies an unscoped texture to every build without one of its own, so switching pipes off hid architecture element 12 too. The target's off-screen arrow also pointed at the union of both builds' boxes. The native side already accepted `buildId`; C8 had never named it.
**Fix:** `ArEngine.setFeatureState(rgba, width, {buildId})` and `setTarget(ids, {buildId})` were added (additive, and `ChannelArEngine` sends the key only when it is set). The workspace pushes **one texture per build**. The Layers panel's SHOW switches (pipes, ducts, trays, equipment) now skip architecture and structure elements, because per-build textures would otherwise hide every wall when "Equipment" is off.
**What to watch:** anything keyed by `featureId` alone (pick results, snag pins, selections, progress colours) must carry `buildId`. Compare `(buildId, featureId)` pairs, never ids.
**Where:** [ar_engine.dart](lib/core/ar/ar_engine.dart), [ar_workspace_controller.dart](lib/state/ar_workspace_controller.dart) `_pushFeatureState`, [CHANNEL.md](packages/fe_ar/CHANNEL.md)

### A corner's face normals must be turned toward the camera before pairing (2026-09-26)
**What happened:** a detector normal that points into the wall gives a heading that is self-consistent but **exactly 90° off**. Tested: 120° instead of 30°. A check that the two faces' headings agree can't catch it. The Demo engine hit the same bug when its scripted camera wandered to the far side of a corner.
**Fix:** `CornerMatcher.firstCorner`/`observe` orient both detected normals toward `cameraAr` (the last `CameraPoseEvent` position) and only then pick the face pairing. Every corner snap passes `cameraAr`, and the demo camera stands on the visible side.
**Where:** [corner_matcher.dart](lib/core/ar/corner_matcher.dart), [ar_setup_controller.dart](lib/state/ar_setup_controller.dart)

### Dio makes a 304 look like an empty 200; the manifest fetch must test it first (2026-09-26)
**What happened:** `validateStatus` accepts anything under 400, so `If-None-Match` → 304 comes back as a success with no body. Parsing it would save an empty manifest and wipe the floor pack.
**Fix:** `DioArTransport` returns `status: 304` with no body, and `fetchManifest` checks it before parsing. If a 304 arrives for a copy that has since been wiped, the fetch is repeated without the tag.
**Where:** [ar_repository.dart](lib/data/ar_repository.dart) `fetchManifest`, `DioArTransport.getJson`

### Engine coaching codes are not errors (2026-09-26)
**What happened:** setup polls `detectCornerAt` every 600 ms while the user aims. Each empty snap makes `fe_ar` emit a throttled `corner-no-surface` / `corner-no-floor` / `corner-not-found` error event, and `marker-unstable` means "hold still". The session showed each one as a red "AR hiccup (corner-no-surface)" toast mid-aim.
**Fix:** `ArSessionController._coachKeyFor` maps those codes to coaching toasts (`ar.corner.coach`, `ar.coach.floor`, `ar.coach.tracking`, `ar.lock.hold_still`). Only unknown codes stay errors.
**What to watch:** when `fe_ar` gains a code, add it to CHANNEL.md's table **and** decide here whether it's coaching or a fault.
**Where:** [ar_session_controller.dart](lib/state/ar_session_controller.dart) `_onEvent`

### Match the server's wire names exactly: `ar_install_request`, `MODEL_OLDER_THAN_LATEST_UPLOAD` (2026-09-26)
**What happened:** the app, written in parallel with the server from contract v1, guessed `ArInstallRequest` as the push entity type and `older-build` as the resolve badge. The server sends `ar_install_request` (`installRequestService.ts`) and `MODEL_OLDER_THAN_LATEST_UPLOAD` (`resolveService.ts RESOLVE_BADGE`). The push link still routed correctly, but a link-less push would have gone nowhere, and the "model is older than the latest upload" hint never showed.
**Fix:** both notification routers and the scan sheet accept the server spelling; the guessed spelling is kept as a fallback.
**What to watch:** for any string the contract doesn't spell out, grep the server before writing the client side.
**Where:** [notification_route.dart](lib/core/utils/notification_route.dart), [push_service.dart](lib/core/push/push_service.dart), [ar_marker_screen.dart](lib/features/ar/ar_marker_screen.dart)

### Riverpod: a session restart never shows as a direct floor A → floor B change (2026-09-26)
**What happened:** `ArSessionController.start()` passes through a state with `floor == null`, so a listener check like `prev.floor != null && next.floor != null && !identical(...)` never fired after a Demo toggle or a retry. Setup and workspace kept stale state. Separately, the saved "Demo on" flag is read asynchronously, so a session that read `prefs.demo` synchronously started live on the first run.
**Fix:** listeners track the last floor object they saw. The session awaits `ArPrefsController.ready`, a `Completer`, before choosing `FakeArEngine` or `ChannelArEngine`.
**Where:** [ar_setup_controller.dart](lib/state/ar_setup_controller.dart), [ar_workspace_controller.dart](lib/state/ar_workspace_controller.dart), [ar_prefs_controller.dart](lib/state/ar_prefs_controller.dart)

### `fe_ar` native: what only a laptop can test, and the hosting traps (2026-09-26)
**What happened:** building the native plugin with no Android or iOS toolchain showed several constraints. SceneView 4.x (4.39) is Compose-only, and FlutterActivity is not a ComponentActivity, so `ARSceneView` is hosted in a `ComposeView` with a hand-made lifecycle, saved-state and view-model owner. Flutter's default `AndroidView` (texture-layer hybrid composition) can't show a `SurfaceView`, so SceneView uses `SurfaceType.TextureSurface`. Filament's Java gltfio exposes no vertex data, so CPU picking decodes the `EXT_meshopt_compression` tiles again in a shared C99 core. That core is the one part testable on a laptop: 131 checks under ASan/UBSan, with fixtures made by the server's real meshopt encoder. meshopt's index codec may rotate a triangle's vertices, so compare index buffers up to rotation.
**What to watch:** Swift can be type-checked with `swiftc -typecheck -import-objc-header` and small ARKit/Flutter/UIKit stubs; it found a real `simd_float4x4 * simd_float4x4 * SIMD4` grouping bug. Compile `.m` files with `clang -fobjc-arc` separately: swiftc-driven harnesses build them without ARC and they crash.
**Where:** [packages/fe_ar/README.md](packages/fe_ar/README.md), [CHANNEL.md](packages/fe_ar/CHANNEL.md)

## Snag Assistant

Design: [docs/snag-assistant.md](docs/snag-assistant.md). Server: `../fusion-eco-server/documentation/snag-assistant.md`.

### Duplicate guard: "same floor" must not link two different rooms (2026-09-26)
**What happened:** the first `SnagDuplicateFinder` gave +0.1 for the same floor whenever the rooms differed. Two identical-sounding snags in rooms 101 and 109 ("cracked socket faceplate") then scored 0.75 and were offered as duplicates. A unit test caught it.
**Fix:** when both sides have a room and the rooms differ, only the same asset (a riser, a duct run) can link them. The same-floor bonus applies only when one side was raised at floor level.
**What to watch:** a false positive costs one "Different" tap, but a noisy guard gets ignored and then it stops catching the real duplicates. Room plus trade alone (0.55) is deliberately below the 0.6 bar, because two electrical snags in one room are usually two defects.
**Where:** [snag_rules.dart](lib/core/snag/snag_rules.dart) `SnagDuplicateFinder.find`, [test/snag_rules_test.dart](test/snag_rules_test.dart)

### Snags are local-first, and actions stay locked until the server knows the snag (2026-09-26)
**What happened:** a transition on a snag the server has never seen would 404 if it replayed before its create (improvements.md's 5xx-reordering P1), which drops it to the conflict log.
**Fix:** a `localOnly` snag shows no actions and cannot take a "+1". The create itself is idempotent on the client id. On a fetch, the server copy replaces the local one unless the snag still has a queued write; while it does, the device is ahead.
**What to watch:** `pendingEntityIds('Snag')` is the "device is ahead" test. Keep `entityType: 'Snag'` on every snag `syncRequest`, or a fetch can overwrite an optimistic change that is still queued.
**Where:** [snag_repository.dart](lib/data/snag_repository.dart) `refresh`, [snag_detail_screen.dart](lib/features/snags/snag_detail_screen.dart)

### GAMMA's alignment UI: what to copy and what to fix (2026-09-26)
**What happened:** screenshots from GAMMA's alignment video showed four details worth taking. (1) A method chooser, where Corner is "Recommended". (2) Structural gridlines drawn on the slab while aligning. (3) QR sheets with **four checkerboard corner targets**, which give far more precise corners than a QR code's own. (4) An "Unregistered QR code" prompt that appears when an unknown sheet is scanned. It also showed two things to fix: a flat 13-item menu, and a jargon prompt ("Do you want to edit QR codes?"). **Adopted:** a context-recommended chooser with "remember per floor"; `IfcGrid` gridlines as a guide and a snap target; corner targets on our boards; a grouped menu with a separate Layers panel; and plain-language, single-decision prompts. **What to watch:** keep one set of widgets with two layouts (iPad rails with labels, phone tabs plus a bottom sheet) rather than two apps.
**Where:** [docs/ar-setup-and-gamma-parity.md §2.9](docs/ar-setup-and-gamma-parity.md)

## Model viewer (2D / 3D)

### A camera-free 3D view doesn't fit `fe_ar`: three.js in a WebView behind a seam (2026-09-26)
**What happened:** the Dalux-style viewer needed a non-AR 3D camera. The plan was a second mode in `packages/fe_ar`, but its Android renderer is SceneView's `ARSceneView`, which an ARCore session owns, and the plugin isn't wired into the app (P-005). **Fix:** `assets/bim_viewer/viewer.js` (three.js 0.160.1, MIT, vendored from the web client's `node_modules` with the `'three'` imports rewritten to relative paths, so no import map is needed) runs in a WebView behind `BimViewEngine`. It reads the same C7 tiles: `KHR_mesh_quantization` + `EXT_meshopt_compression` work through `GLTFLoader.setMeshoptDecoder`; `TEXCOORD_1` arrives as the attribute `uv1`; scene extras land in `gltf.scene.userData.fe`. **Watch:** keep every viewer rule in `viewer_math.js` (pure) so Node tests it, and rerun `tool/bim_viewer/e2e.mjs` on real server tiles after any `viewer.js` change. Headless Chromium draws WebGL2 with `--use-angle=swiftshader --enable-unsafe-swiftshader`. **State:** V1 built; page verified in a browser; Dart unverified (P-011).

### Feed a WebView from disk with a loopback server, not a channel or `file://` (2026-09-26)
**What happened:** the page must load 60+ GLB tiles (MBs) from `<appSupport>/ar/tiles/`. Base64 over a JavaScript channel adds 33 % and a UI-isolate copy per tile. Android WebView blocks `fetch()` of `file://` from a `file://` page. **Fix:** `ViewerAssetServer` on `InternetAddress.loopbackIPv4:0`, with a random 128-bit token as the first path segment, a GET-only allow list for page files, and tiles served only by registered hash (a hash never becomes a path). **Watch:** Dart must queue commands until the page's `ready` event; before that, `runJavaScript` runs in whatever document is loading and the command is lost. Example: `setTiles` sent right after `loadRequest` did nothing.

### A second pack on the same floor id must not own the floor's side tables (2026-09-26)
**What happened:** the viewer's solid-wall pack is stored in `ar_manifests` with scope `viewer` and the floor id as `scope_id`. `saveArManifest` deleted and rewrote corners, grid lines and markers for `scope_id` whatever the scope, so saving the viewer pack would have wiped the floor's corners and boards. `floorsForBuilding` keyed stored manifests by `scopeId` alone, so the viewer pack would have overwritten the floor's entry. **Fix:** `saveArManifest` returns after the manifest row when `scope != 'floor'` (the same way `deleteArManifest` already did), and both floor listings filter `scope == 'floor'`. **Watch:** any new pack scope (route packs are planned) inherits this. Tile GC counts every scope's `tileHashes`, which is what keeps viewer tiles alive.

### Rewriting a JSON asset with `json.dumps` reformats the whole file (2026-09-26)
**What happened:** adding i18n keys by load-then-dump removed the blank lines that separate sections in `en.json`/`ar.json`. It was a 76-line diff for 31 new keys. **Fix:** restore the file, then append the new keys as text before the closing `}` and check the result parses. **Watch:** `git diff --stat assets/i18n/` should show only insertions plus the one line that gains a comma.

### Riverpod: attach an engine after the first frame, and before starting it (2026-09-26)
**What happened:** `BimViewerScreen.initState` first called `controller.attach(engine)` (which sets state), then `engine.start()`, whose fake emits `ready` in a microtask. Two bugs: changing provider state during build throws, and if `start()` ran first, `ready` fired into a broadcast stream nobody listened to yet. **Fix:** in one `scheduleMicrotask` from `initState`: `attach`, then `start`, then `open`. `detach()` from `dispose` changes no state. **Watch:** the same applies to any screen that owns an engine and a notifier.
