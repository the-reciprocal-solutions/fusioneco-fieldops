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

class _FakeApi extends ApiClient {
  _FakeApi() : super(secureStore: SecureStore());
  final gets = <String>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    gets.add(path);
    if (path == '/api/fm/plant-layouts') return {'success': true, 'data': [{'id': 'room-1', 'name': 'Basement plant', 'updatedAt': '2026-10-30T10:00:00Z', 'shared': true}]};
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

  test('machines counted by type, biggest first', () {
    final m = [for (final i in _room['instances'] as List) PlantMachine.fromJson(i as Map)];
    expect(countByType([...m, m.first]), [('PUMP', 2), ('AHU', 1), ('CHILLER', 1), ('COOLING_TOWER', 1)]);
    expect(m[2].deviceName, 'CT gw');
  });

  testWidgets('list → room: a summary and the desktop note, no live calls', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = await _pump(tester);
    expect(find.text('Basement plant'), findsOneWidget);
    await tester.tap(find.text('Basement plant'));
    await tester.pumpAndSettle();

    expect(find.text('MACHINES BY TYPE'), findsOneWidget);
    expect(find.text('Linked'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // two assets + one device
    expect(find.text('For live readings, warning colours and the 3D plant room, use the web admin panel on a desktop.'), findsOneWidget);
    expect(api.gets, ['/api/fm/plant-layouts', '/api/fm/plant-layouts/room-1']); // nothing live, no polling

    await tester.pump(const Duration(seconds: 61));
    expect(api.gets, hasLength(2));
  });
}
