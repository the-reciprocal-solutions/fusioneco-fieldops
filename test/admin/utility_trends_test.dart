import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/specs.dart';
import 'package:technician_portal/admin/features/modules/utility_screens.dart';
import 'package:technician_portal/admin/features/modules/utility_trends.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// One DG; history in two pages (the live shape, 2026-11-01).
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final history = <Map<String, dynamic>>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    switch (path) {
      case '/api/proxy/bacnet/api/devices':
        return {
          'data': [
            {'device_id': 7, 'name': 'DG-01', 'utility_tag': 'DG', 'status': 'online'},
          ],
        };
      case '/api/proxy/bacnet/api/history/devices/latest':
        return {
          'data': [
            {'device_id': 7, 'points': {'DG-01/FuelLevel': 410.0, 'DG-01/EngineRunning': false, 'DG-01/Model': 'X1'}},
          ],
        };
      case '/api/proxy/bacnet/api/timeseries/readings':
        history.add(query!);
        final first = query['offset'] == '0';
        return {
          'paging': {'has_more': first},
          'readings': first
              ? [
                  {'time': '2026-10-31T10:00:00+00:00', 'object_name': 'DG-01/FuelLevel', 'avg': 400},
                  {'time': '2026-10-31T11:00:00+00:00', 'object_name': 'DG-01/FuelLevel', 'avg': 380},
                ]
              : [
                  {'time': '2026-10-31T12:00:00+00:00', 'object_name': 'DG-01/FuelLevel', 'avg': null, 'last': true},
                ],
        };
    }
    throw StateError('unexpected GET $path');
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  test('history: every page read, on/off values → 1 / 0, numbers first in the picker', () async {
    final api = _Api();
    final rows = await loadTrend(api, 'DG-01/FuelLevel', '1h', DateTime(2026, 10, 31), DateTime(2026, 11, 1));
    expect(rows.map((r) => r.v), [400, 380, 1]);
    expect(api.history.map((q) => q['offset']), ['0', '2']);
    expect(api.history.first['res'], '1h');
    const d = MscDevice(id: '7', name: 'DG', tag: 'DG', raw: {'B/On': true, 'B/Model': 'X', 'B/Fuel': 3});
    expect(chartablePoints(d), ['B/Fuel', 'B/On']);
  });

  Future<_Api> pump(WidgetTester tester, List<String> tabs) async {
    final api = _Api();
    final l = FlutterLocalization.instance;
    final module = MobileModule(id: 'dg', label: 'DG', group: 'g', icon: 'fuel', webPath: '/facility-utilities/dg', tabs: tabs);
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        home: moduleSpecs['dg']!.screen!(module),
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('Trends switch on: Readings | Trends; Trends charts the first number', (tester) async {
    final api = await pump(tester, ['isDg_Dashboard', 'isDg_Trends']);
    expect(find.text('Trends'), findsOneWidget);
    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();
    expect(api.history.first['point'], 'DG-01/FuelLevel');
    expect(find.text('Fuel level'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('400'), findsOneWidget); // high of 400, 380, 1

    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();
    expect(api.history.last['res'], '1h');
  });

  testWidgets('Trends switch off: no Trends', (tester) async {
    await pump(tester, ['isDg_Dashboard']);
    expect(find.text('Trends'), findsNothing);
  });
}
