import 'dart:convert';
import 'dart:io';

import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/specs.dart';
import 'package:technician_portal/admin/features/plant_room/plant_room_screens.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _a1 = '11111111-1111-1111-1111-111111111111';
const _a2 = '22222222-2222-2222-2222-222222222222';

/// A room shaped like the client's PlantLayout (layoutSchema.ts).
final _room = {
  'id': 'room-1',
  'name': 'Basement plant',
  'instances': [
    {'id': 'i1', 'type': 'PUMP', 'label': 'CHW pump 1', 'assetId': _a1, 'assetName': 'PMP-01'},
    {'id': 'i2', 'type': 'CHILLER', 'label': 'Chiller 1', 'assetId': _a2},
    {'id': 'i3', 'type': 'COOLING_TOWER', 'label': 'CT-1', 'binding': {'deviceId': 7, 'deviceName': 'CT gw', 'deviceTagCode': 'CT'}},
    {'id': 'i4', 'type': 'AHU', 'label': 'AHU demo'},
  ],
  'connections': [],
};

/// Shaped like the live `/api/fm/plant-layouts/live` (2026-10-30).
final _live = {
  'assets': {
    _a1: {
      'status': 'live',
      'points': {
        'Running status': {'value': 'ON', 'unit': null, 'time': '04:40 PM', 'name': 'Running status'},
        'Trip alarm': {'value': 'TRIPPED', 'unit': null, 'time': '04:40 PM', 'name': 'Trip alarm'},
      },
    },
    _a2: {'status': 'unmapped', 'points': {}},
  },
};

class _FakeApi extends ApiClient {
  _FakeApi() : super(secureStore: SecureStore());
  final gets = <String>[];
  Duration? liveTimeout;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    gets.add(path);
    if (path == '/api/fm/plant-layouts') return {'success': true, 'data': [{'id': 'room-1', 'name': 'Basement plant', 'updatedAt': '2026-10-30T10:00:00Z', 'shared': true}]};
    if (path == '/api/fm/plant-layouts/live') {
      liveTimeout = timeout;
      expect(query?['assetIds'], '$_a1,$_a2');
      return {'success': true, 'data': _live};
    }
    if (path == '/api/fm/plant-layouts/room-1') return {'success': true, 'data': _room};
    throw StateError('unexpected GET $path');
  }
}

final _boot = MobileBootstrap(
  role: 'Admin',
  isSuperAdmin: false,
  accessScope: 'all',
  buildings: const [],
  language: 'en',
  license: const LicenseInfo(state: 'active', access: 'full'),
  modules: [MobileModule(id: 'plant_room', label: 'Plant Room', group: 'g', icon: 'factory', webPath: '/facility-utilities/plant-room')],
  webOnly: const [],
  catalogVersion: 1,
);

Future<_FakeApi> _pump(WidgetTester tester, {MobileBootstrap? boot}) async {
  final api = _FakeApi();
  final b = boot ?? _boot;
  final localization = FlutterLocalization.instance;
  await tester.pumpWidget(ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api), loadedCatalogProvider.overrideWithValue(b)],
    child: MaterialApp(
      theme: AppTheme.build(),
      supportedLocales: localization.supportedLocales,
      localizationsDelegates: localization.localizationsDelegates,
      home: PlantRoomListScreen(module: _boot.module('plant_room')!),
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

  test('plant_room has a screen', () => expect(moduleSpecs['plant_room']?.screen, isNotNull));

  test('alarm reading follows the web toAlarmState', () {
    expect(toAlarmState('TRIPPED'), 'trip');
    expect(toAlarmState('NO ALARM'), 'normal');
    expect(toAlarmState('Fault'), 'alarm');
    expect(toAlarmState(true), 'alarm');
    expect(toAlarmState('0'), 'normal');
    expect(toAlarmState('STOPPED'), 'unknown');
    // Only alarm-type parameters count: a running pump is not an alarm.
    expect(const PlantPoint(name: 'Running status', value: 'ON').isAlarm, isFalse);
    expect(const PlantPoint(name: 'Trip alarm', value: 'TRIPPED').isAlarm, isTrue);
  });

  test('machines: feed per binding, alarms first, asset ids deduped', () {
    final m = [for (final i in _room['instances'] as List) PlantMachine.fromJson(i as Map).withLive(_live['assets'])];
    expect(m.map((x) => x.feed), [PlantFeed.live, PlantFeed.unmapped, PlantFeed.device, PlantFeed.none]);
    expect(m.first.level, 'critical');
    expect(assetIdsOf([...m, ...m]), [_a1, _a2]);
    final sorted = sortMachines([m[3], m[1], m[0]]);
    expect(sorted.first.id, 'i1');
  });

  testWidgets('list → room: cards with live values and an alarm', (tester) async {
    final api = await _pump(tester);
    expect(find.text('Basement plant'), findsOneWidget);
    await tester.tap(find.text('Basement plant'));
    await tester.pumpAndSettle();

    expect(find.text('CHW pump 1'), findsOneWidget);
    expect(find.text('TRIPPED'), findsOneWidget);
    expect(find.text('Points not mapped (Device Mapping)'), findsOneWidget);
    expect(find.text('Live readings on the web'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(api.liveTimeout, const Duration(seconds: 60));

    // Leaving the room stops the 30 s poll.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    final before = api.gets.length;
    await tester.pump(const Duration(seconds: 61));
    expect(api.gets.length, before);
  });
}
