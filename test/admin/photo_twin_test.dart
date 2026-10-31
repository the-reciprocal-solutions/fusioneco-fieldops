import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:technician_portal/admin/core/media/photo_picker.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/network/api_exception.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/core/storage/session_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/specs.dart';
import 'package:technician_portal/admin/features/photo_twin/photo_twin_screens.dart';
import 'package:technician_portal/admin/features/photo_twin/snag_actions.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _b1 = 'b-1';

/// Shaped like the live `/api/snags` rows (2026-10-30).
final _snag = {
  'id': 's-1',
  'reference': 'SNG-0007',
  'title': 'Ceiling tile stained',
  'status': 'in-progress',
  'priority': 'minor',
  'trade': 'finishes',
  'evidence': [
    {'id': 'e1', 'kind': 'photo', 'stage': 'before', 'url': 'http://files.local/1.jpg'},
  ],
  'activity': [
    {'at': '2026-10-29T11:40:53.163Z', 'type': 'raised', 'byName': 'Ragul'},
  ],
};

final _models = [
  {'id': 'r1', 'buildingId': _b1, 'modelId': 'm1-b1-control', 'name': 'BMS Room · 360° scan', 'isCurrent': true, 'metadata': {'kind': 'splat', 'thumbUrl': '/twin-assets/realistic/x.thumb.jpg', 'placement': {'level': 'B1'}}},
  {'id': 'r2', 'buildingId': _b1, 'modelId': 'design', 'name': 'Clinic HVAC', 'isCurrent': true, 'metadata': {}},
  {'id': 'r3', 'buildingId': 'not-mine', 'modelId': 'x', 'name': 'Other site scan', 'isCurrent': true, 'metadata': {'kind': 'splat'}},
];

class _FakeApi extends ApiClient {
  _FakeApi({this.duplicateOnce = false}) : super(secureStore: SecureStore());
  final bool duplicateOnce;
  final posts = <(String, Object?)>[];
  final uploads = <String>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    switch (path) {
      case '/api/snags/summary':
        return {'success': true, 'data': {'byStatus': {'open': 4, 'in-progress': 1, 'ready': 0}, 'overdue': 2}};
      case '/api/snags':
        return {'success': true, 'data': {'items': [_snag], 'total': 1}};
      case '/api/snags/locations/buildings':
        return {'success': true, 'data': [{'id': _b1, 'name': 'Tower A'}]};
      case '/api/fm/bs/3d-models':
        return {'success': true, 'data': _models};
      case '/api/snags/s-1':
        return {'success': true, 'data': _snag};
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add((path, body));
    if (duplicateOnce && path == '/api/fm/reactive-maintenance' && (body as Map)['duplicateAck'] != true) {
      throw const HttpFailure(status: 409, message: 'A similar ticket is open');
    }
    return {'success': true, 'data': {'ticketId': 'RM-42'}};
  }

  @override
  Future<String> uploadFile(List<int> bytes, String fileName) async {
    uploads.add(fileName);
    return 'http://files.local/$fileName';
  }
}

final _boot = MobileBootstrap(
  role: 'Admin',
  isSuperAdmin: false,
  accessScope: 'all',
  buildings: const [],
  language: 'en',
  license: const LicenseInfo(state: 'active', access: 'full'),
  modules: [MobileModule(id: 'photo_twin', label: 'Photo Twin', group: 'g', icon: 'aperture', webPath: '/digital-twin/realistic')],
  webOnly: const [],
  catalogVersion: 1,
);

Future<_FakeApi> _pump(WidgetTester tester, {_FakeApi? api}) async {
  final a = api ?? _FakeApi();
  final localization = FlutterLocalization.instance;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(a),
      sessionStoreProvider.overrideWithValue(await SessionStore.open()),
      loadedCatalogProvider.overrideWithValue(_boot),
      photoPickerProvider.overrideWithValue((_) async => (bytes: Uint8List(4), name: 'after.jpg')),
    ],
    child: MaterialApp(
      theme: AppTheme.build(),
      supportedLocales: localization.supportedLocales,
      localizationsDelegates: localization.localizationsDelegates,
      home: PhotoTwinScreen(module: _boot.module('photo_twin')!),
    ),
  ));
  await tester.pumpAndSettle();
  return a;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    final localization = FlutterLocalization.instance;
    await localization.ensureInitialized();
    localization.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  test('photo_twin has a screen', () => expect(moduleSpecs['photo_twin']?.screen, isNotNull));

  test('snag moves follow the server rules', () {
    List<String> labels(String status, {String? wo}) => [for (final a in snagActions({'id': 'x', 'status': status, 'workOrderId': ?wo})) a.label];
    expect(labels('open'), ['act.start', 'act.snag_ready', 'act.comment', 'act.add_photo', 'act.snag_wo', 'act.waive']);
    expect(labels('ready'), ['act.verify', 'act.reject', 'act.comment', 'act.add_photo', 'act.snag_wo', 'act.waive']);
    expect(labels('closed'), ['act.reopen', 'act.comment']);
    expect(labels('waived'), ['act.comment']);
    expect(labels('open', wo: 'wo-1'), isNot(contains('act.snag_wo')));
    // "Mark fixed" needs a photo; reject / reopen / waive need a reason.
    expect(snagActions({'status': 'open'}).firstWhere((a) => a.label == 'act.snag_ready').photoRun, isNotNull);
  });

  test('scans: photo scans only, of my buildings, thumbs from the web app', () {
    final scans = scansByBuilding(_models, {_b1});
    expect(scans.keys, [_b1]);
    expect(scans[_b1]!.single.modelId, 'm1-b1-control');
    expect(scans[_b1]!.single.thumbUrl, endsWith('/twin-assets/realistic/x.thumb.jpg'));
    expect(photoTwinWebPath(_b1, 'm1-b1-control'), '/digital-twin/realistic?b=b-1&m=m1-b1-control');
  });

  test('reactive payload matches the web Report sheet', () {
    final p = reactivePayload(type: 'safety', title: 'Exit blocked', note: 'Boxes', priority: 'high', buildingName: 'Tower A', buildingId: _b1, where: 'B1 corridor', requestedBy: 'Ragul');
    expect(p['type'], 'Fire Safety');
    expect(p['subRequest'], 'Safety: Exit blocked');
    expect(p['location'], 'Tower A · B1 corridor');
    expect(p['buildingId'], _b1);
    expect(p.containsKey('duplicateAck'), isFalse);
  });

  testWidgets('home: counts, open snags, scans of my buildings', (tester) async {
    await _pump(tester);
    expect(find.text('Ceiling tile stained'), findsOneWidget);
    expect(find.text('BMS Room · 360° scan'), findsOneWidget);
    expect(find.text('Clinic HVAC'), findsNothing); // a design model, not a photo scan
    expect(find.text('Other site scan'), findsNothing); // not my building
  });

  testWidgets('snag: mark fixed uploads the after photo and sends it with ready', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.text('Ceiling tile stained'));
    await tester.pumpAndSettle();
    expect(find.text('Raised'), findsOneWidget); // the thread

    await tester.tap(find.text('Mark fixed (after photo)'));
    await tester.pumpAndSettle();
    expect(api.uploads, ['after.jpg']);
    final (path, body) = api.posts.single;
    expect(path, '/api/snags/s-1/transition');
    expect((body as Map)['action'], 'ready');
    expect(((body['evidence'] as List).single as Map)['url'], 'http://files.local/after.jpg');
    expect((body['evidence'] as List).single['stage'], 'after');
  });

  testWidgets('report issue: a duplicate asks, then resends with duplicateAck', (tester) async {
    final api = await _pump(tester, api: _FakeApi(duplicateOnce: true));
    await tester.tap(find.text('Report issue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Water on floor');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Send'), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Possible duplicate'), findsOneWidget);
    await tester.tap(find.text('Send anyway'));
    await tester.pumpAndSettle();

    expect(api.posts.length, 2);
    final body = api.posts.last.$2 as Map;
    expect(body['duplicateAck'], true);
    expect(body['buildingId'], _b1); // the only building is picked for you
    expect(body['subRequest'], 'Fault: Water on floor');
  });
}
