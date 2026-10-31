import 'dart:convert';
import 'dart:io';

import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/core/storage/session_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/efficiency/efficiency_data.dart';
import 'package:technician_portal/admin/features/efficiency/efficiency_pages.dart';
import 'package:technician_portal/admin/features/modules/specs.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A summary shaped like the live `/api/fm/hvac-efficiency/summary` (2026-10-30).
final _summary = {
  'score': 73,
  'grade': 'Fair',
  'kpis': {'dataHealthPct': 88, 'chillersRunning': 3, 'chillersTotal': 3, 'plantDeltaT': 3.5, 'designDeltaT': 5.5},
  'impact': {'perDay': 8.674, 'perYear': 3166, 'currency': 'OMR', 'byCategory': []},
  'pillars': [
    {'key': 'comfort', 'label': 'Comfort', 'available': true, 'score': 81, 'issues': 2, 'top': 'FCU corridor L5 setpoint is 17.8 °C'},
    {'key': 'safety', 'label': 'Safety', 'available': true, 'score': 100, 'issues': 0},
  ],
  'findings': [
    {'id': 'info:1', 'rule': 'r1', 'severity': 'info', 'pillar': 'comfort', 'title': 'Minor drift', 'actions': []},
    {
      'id': 'valve_saturated:fahu:3',
      'rule': 'valve_saturated',
      'severity': 'warn',
      'pillar': 'equipment',
      'title': "FAHU-03 can't reach its off-coil setpoint",
      'summary': 'Off-coil air is 26.8 °C above setpoint.',
      'evidence': [{'label': 'Valve open', 'value': '98.1%'}],
      'causes': ['Warm chilled water'],
      'actions': [{'tier': 'now', 'text': 'Check the chilled water temperature'}],
      'workOrder': {'title': 'x'},
    },
    {'id': 'risk:1', 'rule': 'r2', 'severity': 'risk', 'pillar': 'safety', 'title': 'Smoke fan not ready', 'actions': []},
  ],
  'headline': ['FAHU-03 runs day and night'],
};

const _site = {'connectionId': 'c1', 'site': 'bacnet_gw_02', 'label': 'bacnet_gw_02', 'devices': 23};

class _FakeApi extends ApiClient {
  _FakeApi() : super(secureStore: SecureStore());
  final posts = <(String, Object?)>[];
  Map<String, dynamic>? summaryQuery;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    if (path.endsWith('/sites')) {
      return {'success': true, 'data': [_site, {..._site, 'site': 'bacnet_gw_03', 'label': 'bacnet_gw_03'}]};
    }
    if (path.endsWith('/summary')) {
      summaryQuery = query;
      return {'success': true, 'data': _summary};
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add((path, body));
    return {'success': true, 'data': {'workOrderId': 'WO-900'}};
  }
}

MobileBootstrap _boot(List<String> pages) => MobileBootstrap(
      role: 'Admin',
      isSuperAdmin: false,
      accessScope: 'all',
      buildings: const [],
      language: 'en',
      license: const LicenseInfo(state: 'active', access: 'full'),
      modules: [MobileModule(id: 'efficiency', label: 'Building Efficiency', group: 'g', icon: 'gauge', webPath: '/hvac/efficiency', pages: [for (final p in pages) ModulePage(id: p, label: p)])],
      webOnly: const [],
      catalogVersion: 1,
    );

Future<_FakeApi> _pump(WidgetTester tester, String page, {List<String> pages = const ['overview', 'fix']}) async {
  final api = _FakeApi();
  final boot = _boot(pages);
  final localization = FlutterLocalization.instance;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      sessionStoreProvider.overrideWithValue(await SessionStore.open()),
      loadedCatalogProvider.overrideWithValue(boot),
    ],
    child: MaterialApp(
      theme: AppTheme.build(),
      supportedLocales: localization.supportedLocales,
      localizationsDelegates: localization.localizationsDelegates,
      home: EffPageScreen(module: boot.module('efficiency')!, pageId: page),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    final localization = FlutterLocalization.instance;
    await localization.ensureInitialized();
    localization.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  test('all 16 pages have a screen', () {
    for (final p in ['overview', 'insight', 'impact', 'report', 'comfort', 'energy', 'equipment', 'safety', 'fix', 'actions', 'savings', 'live', 'trends', 'data', 'checks', 'settings']) {
      expect(moduleSpecs[specKey('efficiency', p)]?.screen, isNotNull, reason: p);
    }
  });

  test('findings: worst first, filtered by pillar', () {
    expect(findingsOf(_summary).map((f) => f['severity']), ['risk', 'warn', 'info']);
    expect(findingsOf(_summary, pillar: 'equipment').single['id'], 'valve_saturated:fahu:3');
    expect(pillarOf(_summary, 'comfort')?['score'], 81);
    expect(pillarOf(_summary, 'power'), isNull);
  });

  testWidgets('overview: score, areas, do-first, from the picked site', (tester) async {
    final api = await _pump(tester, 'overview');
    expect(find.text('73 · Fair'), findsOneWidget);
    expect(find.text('Comfort'), findsWidgets);
    expect(find.text('Smoke fan not ready'), findsOneWidget); // most urgent first
    expect(api.summaryQuery, {'connectionId': 'c1', 'site': 'bacnet_gw_02', 'days': '1'});
  });

  testWidgets('the picked site is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({'hvac-eff:last-site': 'c1|bacnet_gw_03'});
    final api = await _pump(tester, 'overview');
    expect(api.summaryQuery?['site'], 'bacnet_gw_03');
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('fix: open a finding, raise its work order once', (tester) async {
    final api = await _pump(tester, 'fix');
    await tester.tap(find.text("FAHU-03 can't reach its off-coil setpoint"));
    await tester.pumpAndSettle();
    expect(find.text('Warm chilled water'), findsOneWidget);
    expect(find.text('98.1%'), findsOneWidget);

    await tester.tap(find.text('Raise work order'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Raise work order').last); // confirm
    await tester.pumpAndSettle();
    final (path, body) = api.posts.single;
    expect(path, '/api/fm/hvac-efficiency/work-order');
    expect(body, containsPair('findingId', 'valve_saturated:fahu:3'));
    expect(body, containsPair('site', 'bacnet_gw_02'));
    expect((body as Map)['requestId'], isA<String>());
    // The button is now done: a second tap can't create another.
    expect(find.text('Work order WO-900 raised'), findsWidgets);
  });

  testWidgets('no Raise button when the Open issues page is off', (tester) async {
    await _pump(tester, 'safety', pages: const ['safety']);
    await tester.tap(find.text('Smoke fan not ready'));
    await tester.pumpAndSettle();
    expect(find.text('Raise work order'), findsNothing);
  });
}
