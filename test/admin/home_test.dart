import 'dart:convert';
import 'dart:io';

import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/core/storage/session_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/home/home_screen.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final gets = <String>[];
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    gets.add(path);
    return {'success': true, 'data': <String, dynamic>{}};
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  testWidgets('Home loads the dashboard even when the Dashboard switch is off (P-003)', (tester) async {
    final api = _Api();
    // No `dashboard` module in the catalog: the web's switch is off for this user.
    final boot = MobileBootstrap.fromJson({'modules': <dynamic>[], 'prefs': <String, dynamic>{'dashboardEnv': 'test'}});
    expect(boot.has('dashboard'), isFalse);
    final l = FlutterLocalization.instance;
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api), sessionStoreProvider.overrideWithValue(await SessionStore.open()), loadedCatalogProvider.overrideWithValue(boot)],
      child: MaterialApp(theme: AppTheme.build(), supportedLocales: l.supportedLocales, localizationsDelegates: l.localizationsDelegates, home: const HomeScreen()),
    ));
    await tester.pumpAndSettle();
    expect(api.gets, contains('/api/dashboard-v3'));
    expect(find.text('Facility Dashboard'), findsOneWidget);
  });
}
