import 'dart:convert';
import 'dart:io';

import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/core/storage/session_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/performance_specs.dart';
import 'package:technician_portal/admin/features/modules/record_detail_screen.dart';
import 'package:technician_portal/admin/features/modules/utility_screens.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers the building-system proxy like the live server (2026-10-30).
class _FakeApi extends ApiClient {
  _FakeApi() : super(secureStore: SecureStore());
  final queries = <String, Map<String, dynamic>?>{};
  var deviceCalls = 0;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    queries[path] = query;
    if (path == '/api/proxy/bacnet/api/devices') {
      deviceCalls++;
      return [
        {'device_id': 30019, 'name': 'VID-DG-01', 'description': 'Main DG', 'status': 'online', 'utility_tag': 'DG'},
        {'device_id': 30020, 'name': 'VID-DG-02', 'status': 'offline', 'utility_tag': 'DG'},
      ];
    }
    if (path == '/api/proxy/bacnet/api/history/devices/latest') {
      return [
        {
          'device_id': 30019,
          'utility_tag': 'DG',
          'points': {'VID-DG-01/FuelLevel': 82, 'VID-DG-01/RunHours': 375, 'VID-DG-01/Running': true},
        },
      ];
    }
    if (path.startsWith('/api/fm/energy/summary')) {
      return {'success': true, 'data': {'buildingId': 'b1', 'kwh': 12345.6, 'peakDemandKw': 410, 'completeness': 0.92, 'status': 'ok'}};
    }
    throw StateError('unexpected GET $path');
  }
}

MobileModule _dg({List<String> tabs = const ['isDg_Dashboard']}) =>
    MobileModule(id: 'dg', label: 'DG', group: 'Facility Utilities', icon: 'fuel', webPath: '/x', tabs: tabs);

Future<_FakeApi> _pump(WidgetTester tester, Widget screen) async {
  final api = _FakeApi();
  final localization = FlutterLocalization.instance;
  await tester.pumpWidget(ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api), sessionStoreProvider.overrideWithValue(await SessionStore.open())],
    child: MaterialApp(
      theme: AppTheme.build(),
      supportedLocales: localization.supportedLocales,
      localizationsDelegates: localization.localizationsDelegates,
      home: screen,
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

  test('point names read like the web', () {
    // Same outputs as the web's humanizePoint (lib/api/msc.ts).
    expect(humanizePoint('TSTAT-01/SpaceTemp'), 'Space temp');
    expect(humanizePoint('VID-DG-01/RunHours'), 'Run hours');
    expect(humanizePoint('fuel_level'), 'Fuel level');
    expect(humanizePoint('ReturnAirTemp'), 'Return air temp');
    expect(humanizePoint('VID-AC-01/Comp1Hp1Fault'), 'Compressor 1 high-pressure 1 fault');
    expect(humanizePoint('co2_level'), 'CO₂ level');
    expect(humanizePoint('UPSLoad'), 'UPS load');
    expect(formatPoint(true), 'On');
    expect(formatPoint(21.676), '21.7'); // 1 decimal from 10 up
    expect(formatPoint(4.1234), '4.12');
    expect(formatPoint(375), '375');
    expect(formatPoint(null), '–');
  });

  test('the device list is read once and reused across screens; latest values every time', () async {
    final api = _FakeApi();
    await loadMscDevices(api, ['DG']);
    final again = await loadMscDevices(api, ['UPS']);
    expect(api.deviceCalls, 1);
    expect(again, isEmpty); // no UPS in the list: filtered here
  });

  test('devices joined with their latest readings; tags repeated in one call', () async {
    final api = _FakeApi();
    final devices = await loadMscDevices(api, ['DG', 'UPS']);
    // The whole list once (filtered here); the latest values per tag.
    expect(api.queries['/api/proxy/bacnet/api/devices'], isNull);
    expect(api.queries['/api/proxy/bacnet/api/history/devices/latest'], {'utility_tag': ['DG', 'UPS']});
    expect(devices.length, 2);
    expect(devices.first.points, [('Fuel level', '82'), ('Run hours', '375'), ('Running', 'On')]);
    expect(devices.last.online, isFalse);
    expect(devices.last.points, isEmpty);
  });

  test('every utility module has a master code and a spec', () {
    for (final id in utilityTags.keys) {
      expect(performanceSpecs[id]?.screen, isNotNull, reason: id);
    }
    expect(performanceSpecs['facility_utilities']?.screen, isNotNull);
    expect(performanceSpecs['utility_explorer']?.screen, isNotNull);
  });

  testWidgets('utility: counts and readings while the Dashboard tab is on', (tester) async {
    await _pump(tester, UtilityScreen(module: _dg(), tag: 'DG', dashboardTab: 'isDg_Dashboard'));
    expect(find.text('2'), findsOneWidget); // devices
    expect(find.text('VID-DG-01'), findsOneWidget);
    expect(find.text('Fuel level'), findsOneWidget);
    expect(find.text('82'), findsOneWidget);
    expect(find.text('No readings yet'), findsOneWidget); // the offline one
  });

  testWidgets('utility: Dashboard tab off → counts only, no readings', (tester) async {
    await _pump(tester, UtilityScreen(module: _dg(tabs: const []), tag: 'DG', dashboardTab: 'isDg_Dashboard'));
    expect(find.text('The Dashboard view is switched off for this utility.'), findsOneWidget);
    expect(find.text('Fuel level'), findsNothing);
  });

  test('occupancy floors come from data.floors of the rollup', () {
    final list = occupancySpec.list!;
    final rows = list.items!({
      'data': {
        'floors': [
          {'storey': 'L1', 'level': 1, 'occupancy': 120, 'capacity': 300, 'pct': 40, 'breachedRooms': 0},
          {'storey': 'L2', 'level': 2, 'occupancy': 310, 'capacity': 300, 'pct': 103, 'breachedRooms': 2},
        ],
      },
    });
    expect(rows.map((r) => list.row(r).title), ['L1', 'L2']);
    expect(list.row(rows.last).status, 'over capacity');
    expect(list.liveQuery!().keys, containsAll(['from', 'to', 'cursor']));
  });

  testWidgets('energy building: the summary is merged over the list row (name kept)', (tester) async {
    await _pump(
      tester,
      RecordDetailScreen(spec: buildingEnergySpec, recordId: 'b1', initial: const {'buildingId': 'b1', 'name': 'Tower A', 'meterCount': 10}),
    );
    expect(find.text('Tower A'), findsWidgets);
    expect(find.text('12,346 kWh'), findsOneWidget);
    expect(find.text('92%'), findsOneWidget);
    expect(find.text('10'), findsOneWidget); // meters, from the row
  });
}
