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
import 'package:technician_portal/admin/features/modules/floor_plan_screen.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// The live shapes (2026-11-01): devices with `fe_asset_uuid`, latest points,
/// floors, assets with floorID + customAttributes.
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final assetGets = <String>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    switch (path) {
      case '/api/proxy/bacnet/api/devices':
        return {
          'data': [
            {'device_id': 3001, 'name': 'TSTAT-01', 'utility_tag': 'TEMP', 'status': 'online', 'fe_asset_uuid': 'a1'},
            {'device_id': 1001, 'name': 'AHU-01', 'utility_tag': 'AHU', 'status': 'online', 'fe_asset_uuid': 'a2'},
            {'device_id': 2002, 'name': 'FCU-02', 'utility_tag': 'DUCTABLE-AC', 'status': 'online', 'fe_asset_uuid': 'gone'},
            {'device_id': 2003, 'name': 'FCU-03', 'utility_tag': 'AC', 'status': 'online'},
          ],
        };
      case '/api/proxy/bacnet/api/history/devices/latest':
        return {
          'data': [
            {'device_id': 3001, 'points': {'TSTAT-01/SpaceTemp': 28.4, 'TSTAT-01/HeatingSetpoint': 21, 'TSTAT-01/CoolingSetpoint': 24}},
            {'device_id': 1001, 'points': {'AHU-01/ReturnAirTemp': 23.1, 'AHU-01/FanStatus': true}},
          ],
        };
      case '/api/floors/floors':
        return {
          'data': [
            {'id': 'f1', 'floorName': 'B1 Basement', 'floorNumber': '-1', 'imageUrl': null, 'building': {'name': 'Tower A'}},
            {'id': 'f2', 'floorName': 'Level 01', 'floorNumber': '1', 'imageUrl': '/images/l1.png', 'building': {'name': 'Tower A'}},
          ],
        };
    }
    if (path.startsWith('/api/fm/assets/')) {
      final id = path.split('/').last;
      assetGets.add(id);
      return switch (id) {
        'a1' => {'data': {'id': 'a1', 'floorID': 'f1', 'customAttributes': <String, dynamic>{}}},
        'a2' => {'data': {'id': 'a2', 'floorID': 'f1', 'customAttributes': {'x': 40, 'y': 60}}},
        _ => throw StateError('404'),
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

  group('deviceHealth (web deviceReading port)', () {
    test('sensor: set points are the band; above it is "too warm"', () {
      final r = deviceHealth('TEMP', {'T/SpaceTemp': 28.4, 'T/HeatingSetpoint': 21, 'T/CoolingSetpoint': 24});
      expect((r.health, r.temp, r.note), (MapHealth.warn, 28.4, 'floor.too_warm'));
    });
    test('sensor: 0 / 0 limits are "not set" → standard 20–26 band; -50 is no value', () {
      expect(deviceHealth('TEMP', {'SpaceTemp': 23, 'MinThreshold': 0, 'MaxThreshold': 0}).health, MapHealth.ok);
      expect(deviceHealth('TEMP', {'SpaceTemp': -50}).health, MapHealth.unknown);
    });
    test('AC: running 3°+ above its set point is off; a trip is an alarm; offline wins', () {
      expect(deviceHealth('AC', {'RoomTemp': 28, 'SetTemp': 24, 'State': 1}).health, MapHealth.warn);
      expect(deviceHealth('AC', {'RoomTemp': 28, 'SetTemp': 24, 'State': 0}).health, MapHealth.ok);
      expect(deviceHealth('AHU', {'ReturnAirTemp': 22, 'TripStatus': true}).health, MapHealth.alarm);
      expect(deviceHealth('AHU', {'ReturnAirTemp': 22}, online: false).health, MapHealth.offline);
      expect(deviceHealth('AHU', const {}).health, MapHealth.offline);
    });
  });

  test('plan URLs: web paths go to the web app, absolute ones stay', () {
    expect(planUrl('/images/floors/a.jpg', webBase: 'https://w.example/'), 'https://w.example/images/floors/a.jpg');
    expect(planUrl('http://h:5002/uploads/p.png', webBase: 'https://w'), 'http://h:5002/uploads/p.png');
    expect(planUrl('  ', webBase: 'https://w'), isNull);
    expect(isPdf('https://x/plan.PDF?v=2'), isTrue);
    expect(spotOf({'customAttributes': {'x': 40, 'y': '60'}}), const Offset(0.4, 0.6));
    expect(spotOf({'customAttributes': {'x': 40}}), isNull);
  });

  testWidgets('floors with devices, their health and temperature, unplaced and unlinked ones said', (tester) async {
    final api = _Api();
    final l = FlutterLocalization.instance;
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        home: const FloorPlanScreen(module: MobileModule(id: 'floor_plan', label: 'Floor Plan', group: 'g', icon: 'map', webPath: '/facility-utilities/floor-map')),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('B1 Basement'), findsOneWidget); // only floors with devices
    expect(find.text('Level 01'), findsNothing);
    expect(find.text('No plan for this floor'), findsOneWidget);
    expect(find.text('TSTAT-01'), findsOneWidget);
    expect(find.text('28.4 °C'), findsOneWidget);
    expect(find.textContaining('Too warm'), findsOneWidget);
    expect(find.textContaining('Not on the plan yet'), findsOneWidget); // TSTAT-01; AHU-01 has a spot
    expect(find.text('AHU-01'), findsOneWidget);
    expect(find.textContaining('2 devices aren'), findsOneWidget); // FCU-02 (asset gone) + FCU-03 (no asset)
    expect(api.assetGets.toSet(), {'a1', 'a2', 'gone'});
  });
}
