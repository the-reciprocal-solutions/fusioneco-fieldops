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
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// A 1×1 JPEG.
const _jpeg = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=';

/// No CCTV in the building system; SustainSphere has 5 cameras at site 1
/// only (the live shape, 2026-11-01). Camera 3 sends no picture.
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final batches = <List<int>>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    switch (path) {
      case '/api/proxy/bacnet/api/devices':
      case '/api/proxy/bacnet/api/history/devices/latest':
        return {'data': <Object>[]};
      case '/api/proxy/v1/energy-dashboard/all_org_tree':
        return {
          'data': [
            {'o_id': 2, 'children': [{'o_id': 3}]},
          ],
        };
      case '/api/proxy/v1/energy-dashboard/all_sites_by_o_id':
        return {
          'data': [
            {'site_id': 2, 'site_name': 'Demo Site1'},
            {'site_id': 1, 'site_name': 'Demo Site4'},
          ],
        };
      case '/api/proxy/v1/energy_dashboard/list_devices_by_subsite':
        return {
          'status_code': 200,
          'data': query!['site_id'] == '1' ? [for (var i = 1; i <= 5; i++) {'camera_id': i, 'camera_name': 'Cam $i'}] : <Object>[],
        };
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    final ids = ((body as Map)['camera_ids'] as List).cast<int>();
    batches.add(ids);
    expect(body['site_id'], 1);
    return {
      'status_code': 200,
      'data': [
        for (final id in ids) {'camera_id': id, 'camera_name': 'Cam $id', 'last_communication_time': '2026-10-31 05:14:37 PM', 'encode_str': id == 3 ? '' : _jpeg},
      ],
    };
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  testWidgets('no building-system cameras → site cameras, first site that has some, pictures in batches', (tester) async {
    final api = _Api();
    final l = FlutterLocalization.instance;
    await tester.binding.setSurfaceSize(const Size(420, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        home: moduleSpecs['cctv']!.screen!(
          const MobileModule(id: 'cctv', label: 'CCTV', group: 'g', icon: 'camera', webPath: '/facility-utilities/cctv', tabs: ['isCctv_Dashboard']),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No devices connected'), findsNothing);
    expect(find.text('Demo Site4 · 5 cameras'), findsOneWidget); // site 2 (first) has none
    expect(api.batches, [
      [1, 2, 3],
      [4, 5],
    ]);
    expect(find.text('Cam 5'), findsOneWidget);
    expect(find.text('5 cameras · 4 with a picture · 1 no picture · 0 checking'), findsOneWidget);
    expect(find.text('No picture'), findsOneWidget);
  });
}
