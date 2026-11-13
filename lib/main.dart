import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin/core/network/api_client.dart' as admin;
import 'admin/core/storage/secure_store.dart' as admin;
import 'admin/core/storage/session_store.dart' as admin;
import 'admin/state/providers.dart' as admin;
import 'app/app_root.dart';
import 'app/env.dart';
import 'core/legal/third_party_licenses.dart';
import 'core/network/api_client.dart';
import 'core/offline/background_sync.dart';
import 'core/offline/offline_db.dart';
import 'core/push/push_service.dart';
import 'core/storage/secure_store.dart';
import 'core/storage/session_store.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerThirdPartyLicenses();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Restores any previously-saved language choice (see app/app.dart) before
  // the first frame, so the app never flashes English before switching.
  await FlutterLocalization.instance.ensureInitialized();

  // Push is optional at startup. An iOS build made before
  // ios/Runner/GoogleService-Info.plist exists has no default Firebase app, so
  // initializeApp() throws here. firebase_core skips FirebaseApp.configure()
  // natively when the plist is missing, so there's no native crash. The rest
  // of the app must still run; PushService.init checks Firebase.apps and
  // stays off. Android always has google-services.json.
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('Firebase unavailable, push is off: $e');
  }

  final secureStore = SecureStore();
  final sessionStore = await SessionStore.open();
  final dbPassphrase = await secureStore.getOrCreateDbPassphrase();
  final offlineDb = await OfflineDb.open(passphrase: dbPassphrase);
  final baseUrl = sessionStore.readBaseUrlOverride() ?? Env.defaultApiBaseUrl;
  final api = ApiClient(secureStore: secureStore, baseUrl: baseUrl);

  // The admin side (lib/admin/, app/app_root.dart): its own keystore names,
  // prefs and client, on the same server.
  final adminSecureStore = admin.SecureStore();
  final adminSessionStore = await admin.SessionStore.open();
  final adminApi = admin.ApiClient(secureStore: adminSecureStore, baseUrl: baseUrl);

  // FR-4.4 — schedule the OS-level queue drain that runs even while the app
  // is closed. Not awaited past its own error handling: it must never block
  // or break startup.
  await BackgroundSync.init();

  runApp(
    ProviderScope(
      overrides: [
        secureStoreProvider.overrideWithValue(secureStore),
        sessionStoreProvider.overrideWithValue(sessionStore),
        offlineDbProvider.overrideWithValue(offlineDb),
        apiClientProvider.overrideWithValue(api),
        admin.secureStoreProvider.overrideWithValue(adminSecureStore),
        admin.sessionStoreProvider.overrideWithValue(adminSessionStore),
        admin.apiClientProvider.overrideWithValue(adminApi),
      ],
      child: const AppRoot(),
    ),
  );
}
