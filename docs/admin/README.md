# admin_portal — Fusion Eco Admin (mobile)

Phone summary of the Fusion Eco admin panel for Admin, Vendor and Tenant users.
Technicians use FieldOps (`../technician_portal`). The plan is `FE-mobile.md` in the
`fusion-eco` repo.

Same stack and idioms as technician_portal: Flutter 3.47 / Dart 3.13, Riverpod 2
(hand-written, no codegen), go_router, Dio, flutter_secure_storage,
flutter_localization (JSON, EN + AR/RTL), bundled Montserrat (shared with the technician side) + lucide icons.

- Android package / iOS bundle: `com.fusionapps.admin`

## Commands

```bash
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=API_BASE_URL=http://<lan-ip>:5002 --dart-define=WEB_BASE_URL=http://<lan-ip>:3000
flutter build apk --debug
```

`API_BASE_URL` has no `/api` suffix. The default is the dev server.

## Layout

```
lib/
  main.dart     builds SecureStore, SessionStore, ApiClient → ProviderScope overrides
  app/          app.dart, env.dart, router.dart (auth redirect + 5-tab shell), locale_config.dart
  core/         network (ApiClient, ApiFailure), storage (token in keystore, user in prefs)
  data/         auth_repository.dart
  domain/       admin_user.dart
  state/        providers.dart, auth_controller.dart, locale_controller.dart
  features/     login/, shell/ (bottom nav), home/ (placeholder tab), more/ (profile, language, sign out)
  theme/        copied from technician_portal (Navy Professional, light only)
```

## Current state

- **Login (0.2):** `POST /api/auth/mobile/login` returns a 1 h access token plus a rotating
  refresh token, both kept in secure storage. On a 401, `ApiClient` renews once through
  `core/network/session_renewer.dart` (single-flight) and replays the request. If the server refuses
  the renewal, the app signs out; if the server can't be reached, the app shows an offline error and
  keeps the tokens. Logout revokes the session on the server.
- **Look:** theme, `AppText`, `FeHeader`, `TechCard` and the motion widgets are copied from technician_portal,
  and so is the floating bottom bar. Use those; don't add raw `Text(style: …)`.
- **Phone over USB:** `adb reverse tcp:5002 tcp:5002`, then build with `API_BASE_URL=http://localhost:5002`.
  The debug manifest allows plain http.
- **Catalog (Phase 0.1 + 1):** after sign-in, the app loads `GET /api/mobile/bootstrap`
  (server `src/mobile/`, doc `documentation/mobile-catalog.md`). The server decides
  what is visible. The app only reads it:
  - `lib/state/catalog_controller.dart`: `catalogProvider`, refetched on app resume and pull-to-refresh
  - `lib/catalog/catalog_guard.dart`: router redirect. A hidden tab goes to `/home`; a hidden module or page goes to `/unavailable`
  - bottom nav hides empty tabs; Efficiency lists the visible pages in the web's groups; Operations and More list modules grouped like the web sidebar
- **Live channel (0.3):** `core/realtime/socket_service.dart` handles `config:changed` (refetch the catalog), `alerts:changed` (refetch alerts), and refetches everything on reconnect.
- **Alerts (Phase 2):** `features/alerts/`:
  - list: counts, severity, mine and resolved filters, worst first, long-press for bulk acknowledge/resolve
  - detail at `/alert/:key`: facts, history, acknowledge, resolve, reopen, take, note
  - data from `/api/fm/alerts`, refetched live on `alerts:changed`
  - rules, teams and the simulator stay on the web
- Other module screens (`/m/:moduleId`) are placeholders until their phase.
- Open items: [PENDING.md](PENDING.md). Lessons: [LEARNINGS.md](LEARNINGS.md).

## Android build notes (this Windows machine)

- NDK pinned to `30.0.16138531` in `android/app/build.gradle.kts` and for all
  plugin subprojects in `android/build.gradle.kts`. NDK 28.2, the Flutter default,
  is only partly downloaded here, and the auto-install crashes `sdkmanager`.
- `kotlin.incremental=false` in `android/gradle.properties`, the same as technician_portal.

## Push notifications (FE-mobile.md 0.4)

The code is in (`lib/core/push/`). Push switches on by itself once this build has the Firebase config; until then the app runs with push off ("Firebase unavailable, push is off" in the log) and More → Alert notifications says so.

To switch it on (one-time, needs Firebase console access):

1. Firebase console → project **fusion-eco-technician** (the one the server's `FIREBASE_SERVICE_ACCOUNT_JSON` sends from) → Add app → Android → package **`com.fusionapps.admin`**. Add the debug SHA-1 if Google sign-in is ever needed (not for push).
2. Download `google-services.json` → put it at `android/app/google-services.json`. `app/build.gradle.kts` applies the Google Services plugin only when that file exists.
3. iOS: add an iOS app with bundle id `com.fusionapps.admin`, put `GoogleService-Info.plist` in `ios/Runner/`, and upload the APNs auth key under Cloud Messaging (same as FieldOps).
4. Rebuild. After sign-in the phone asks for notification permission and registers its token (`POST /api/notifications/register-device`); sign-out unregisters it.

What arrives: new and escalated alerts in the user's buildings at or above their chosen severity (default high and critical), plus every bell notification addressed to the user (for example "Assigned to you"). Tapping an alert push opens that alert (the catalog guard still applies); anything else opens Notifications. The server side: fusion-eco-server documentation/mobile-catalog.md "Alert push".
