import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/fm_specs.dart';
import 'package:technician_portal/admin/features/modules/module_summary_screen.dart';
import 'package:technician_portal/admin/features/modules/scan_screen.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// `GET /api/fm/assets`: two assets; `search=AST301` finds one.
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final searches = <Object?>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    if (path != '/api/fm/assets') return {'success': true, 'data': <String, dynamic>{}};
    searches.add(query?['search']);
    final a7 = {'id': 'a7', 'name': 'FCU 5th-Floor', 'assetReferenceId': 'AST301'};
    final rows = query?['search'] == 'AST301' ? [a7] : query?['search'] == null ? [a7, {'id': 'a8', 'name': 'AHU-01'}] : <Object>[];
    return {'success': true, 'data': rows, 'pagination': {'total': rows.length}};
  }
}

const _assets = MobileModule(id: 'assets', label: 'Assets', group: 'Facility Management', icon: 'box', webPath: '/x');

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  group('assetIdFromScan', () {
    test('the sticker JSON and the public link give the id', () {
      expect(assetIdFromScan('{"type":"Asset","id":"a7"}'), 'a7');
      expect(assetIdFromScan('https://dev.eco.thefusionapps.com/public/assets/a7'), 'a7');
    });
    test('a bare reference, a work order sticker or a foreign scheme give null', () {
      expect(assetIdFromScan('AST301'), isNull);
      expect(assetIdFromScan('{"type":"WorkOrder","id":"w1"}'), isNull);
      expect(assetIdFromScan('javascript:/assets/a7'), isNull);
    });
  });

  Future<_Api> pump(WidgetTester tester, String? scanned) async {
    final api = _Api();
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => ModuleSummaryScreen(module: _assets, spec: assetsSpec)),
      GoRoute(path: '/m/:m/r/:id', builder: (_, s) => Scaffold(body: Text('opened ${s.pathParameters['id']}'))),
    ]);
    final l = FlutterLocalization.instance;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        scanCodeProvider.overrideWithValue((_) async => scanned),
      ],
      child: MaterialApp.router(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.scanLine));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('a sticker opens its asset straight away', (tester) async {
    await pump(tester, '{"type":"Asset","id":"a7"}');
    expect(find.text('opened a7'), findsOneWidget);
  });

  testWidgets('an old barcode (the reference) is searched; one match opens', (tester) async {
    final api = await pump(tester, 'AST301');
    expect(api.searches.last, 'AST301');
    expect(find.text('opened a7'), findsOneWidget);
  });

  testWidgets('backing out of the camera changes nothing', (tester) async {
    final api = await pump(tester, null);
    expect(api.searches, [null]);
    expect(find.text('AHU-01'), findsOneWidget);
  });
}
