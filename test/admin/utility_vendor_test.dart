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
import 'package:technician_portal/admin/features/modules/utility_screens.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// The provider chosen for the user in Settings decides where utilities read
/// from (owner, 2026-11-02): BacNet MSC → the building system; Vidyutt /
/// SustainSphere → `GET /api/fm/utilities/live` (server services/utilityLive.ts).
/// Shape as live on Vidyutt Demo, 2026-11-02.
final _live = {
  'success': true,
  'data': {
    'provider': {'slug': 'vidyutt-demo', 'alias': 'v6', 'displayName': 'Vidyutt Demo', 'family': 'demo'},
    'devices': [
      {
        'id': '1:1:100',
        'deviceId': 100,
        'tag': 'AC',
        'name': 'WS_Duct_(5/5)',
        'subsiteName': 'Ground Floor',
        'online': true,
        'readings': [
          {'key': 'ROOM_TEMP', 'name': 'Room Temperature', 'value': null, 'unit': '°C'},
          {'key': 'CURRENT_TEMP', 'name': 'Set/Discharge Temperature', 'value': 25, 'unit': '°C'},
          {'key': 'AC_MODE', 'name': 'Mode', 'value': 'COOL'},
          {'key': 'POLLING_STATUS', 'name': 'Connection', 'value': 'Online'},
        ],
      },
      {'id': '1:1:151', 'deviceId': 151, 'tag': 'AC', 'name': 'FF- Shoes area', 'online': false, 'readings': []},
    ],
    'failedTags': [],
  },
};

class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final paths = <String>[];
  final queries = <Map<String, dynamic>?>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    paths.add(path);
    queries.add(query);
    if (path == '/api/fm/utilities/live') return _live;
    throw StateError('unexpected GET $path');
  }
}

MobileBootstrap _boot(String provider) => MobileBootstrap(
      role: 'Admin',
      isSuperAdmin: false,
      accessScope: 'all',
      buildings: const [],
      language: 'en',
      license: const LicenseInfo(state: 'active', access: 'full'),
      modules: const [],
      webOnly: const [],
      catalogVersion: 1,
      utilityProvider: provider,
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  test('bootstrap: utilityProvider read; older servers mean BacNet', () {
    final base = {'role': 'Admin', 'modules': <Object>[], 'webOnly': <Object>[], 'catalogVersion': 1};
    expect(MobileBootstrap.fromJson({...base, 'prefs': {'utilityProvider': 'test'}}).utilitiesOnBacnet, isFalse);
    expect(MobileBootstrap.fromJson({...base, 'prefs': <String, Object>{}}).utilitiesOnBacnet, isTrue);
  });

  test('a vendor device: empty values and the connection field left out; units kept', () async {
    final api = _Api();
    final d = await loadUtilityDevices(api, ['AC', 'AHU'], bacnet: false);
    expect(api.paths, ['/api/fm/utilities/live']);
    expect(api.queries.single, {'tags': 'AC,AHU'});
    expect(d.first.points, [('Set/Discharge Temperature', '25 °C'), ('Mode', 'COOL')]);
    expect(d.first.description, 'Ground Floor');
    expect(d.first.labelOf('AC_MODE'), 'Mode');
    expect(d.last.online, isFalse);
  });

  testWidgets('AC on a vendor provider: its devices, no Trends option at all', (tester) async {
    final api = _Api();
    final l = FlutterLocalization.instance;
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api), loadedCatalogProvider.overrideWithValue(_boot('vidyutt-demo'))],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        home: const UtilityScreen(
          module: MobileModule(id: 'hvac_ac', label: 'AC', group: 'HVAC', icon: 'air-vent', webPath: '/hvac/ac'),
          tag: 'AC',
          alwaysTrends: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(api.paths.toSet(), {'/api/fm/utilities/live'}); // never the building system
    expect(find.text('WS_Duct_(5/5)'), findsOneWidget);
    expect(find.text('25 °C'), findsOneWidget);
    expect(find.text('Trends'), findsNothing);
    expect(find.textContaining('desktop'), findsNothing); // no Trends, no note about it
  });
}
