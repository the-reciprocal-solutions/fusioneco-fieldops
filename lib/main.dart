import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
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

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  final secureStore = SecureStore();
  final sessionStore = await SessionStore.open();
  final dbPassphrase = await secureStore.getOrCreateDbPassphrase();
  final offlineDb = await OfflineDb.open(passphrase: dbPassphrase);
  final api = ApiClient(
    secureStore: secureStore,
    baseUrl: sessionStore.readBaseUrlOverride() ?? Env.defaultApiBaseUrl,
  );

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
      ],
      child: const TechnicianApp(),
    ),
  );
}
