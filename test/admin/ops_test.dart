import 'dart:convert';
import 'dart:io';

import 'package:technician_portal/admin/catalog/catalog_guard.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/chat_screen.dart';
import 'package:technician_portal/admin/features/modules/module_spec.dart';
import 'package:technician_portal/admin/features/modules/ops_specs.dart';
import 'package:technician_portal/admin/features/modules/specs.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every module id in the server catalog (src/mobile/moduleCatalog.ts, 2026-10-30).
const _catalogIds = [
  'dashboard', 'efficiency', 'alerts', 'work_orders', 'permits', 'attendance', 'snags', 'preventive', 'reactive', 'annual',
  'inspections', 'pm_compliance', 'assets', 'documents', 'quotes', 'invoices', 'reporting', 'audit_log', 'facility_ops', 'amc',
  'plant_room', 'facility_utilities', 'energy', 'dg', 'ups', 'solar_panel', 'water_meter', 'tank_level', 'pump', 'feel_temperature',
  'co2', 'fire', 'intrusion', 'cctv', 'lift', 'it_rack', 'utility_explorer', 'building_energy', 'floor_plan', 'hvac_ac', 'hvac_ahu',
  'hvac_ductable_ac', 'energy_analytics', 'access_control', 'occupancy', 'photo_twin', 'digital_twin', 'timeline_revisit', 'handover',
  'construction_progress', 'reports', 'intelligence', 'carbon', 'ask_flowai', 'flow_agents', 'notifications',
];

/// Screens of their own (Home, tabs) or not built yet (Phase 2 / PENDING).
const _notSpecs = {'dashboard', 'efficiency', 'alerts', 'floor_plan'};

class _ChatApi extends ApiClient {
  _ChatApi() : super(secureStore: SecureStore());
  Object? lastBody;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async => {'messages': <Object>[]};

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    lastBody = body;
    return {'content': 'Two DGs are running.', 'messageId': 'm1'};
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    final localization = FlutterLocalization.instance;
    await localization.ensureInitialized();
    localization.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  test('every catalog module has a phone screen, except the known ones', () {
    final missing = _catalogIds.where((id) => !moduleSpecs.containsKey(id) && !_notSpecs.contains(id)).toList();
    expect(missing, isEmpty);
  });

  test('Facility Ops: each page has its own spec; the page stays in the record path', () {
    for (final page in ['bookings', 'visitors', 'service_schedules', 'rfqs', 'purchase_orders']) {
      expect(moduleSpecs[specKey('facility_ops', page)], isNotNull, reason: page);
    }
    expect(moduleSpecs[specKey('facility_ops', null)]?.screen, isNotNull);
    final path = Uri.parse(recordPath('facility_ops', 'v1', page: 'visitors'));
    expect(path.path, '/m/facility_ops/r/v1');
    expect(path.queryParameters['page'], 'visitors');

    MobileBootstrap boot(List<String> pages) => MobileBootstrap(
          role: 'Admin',
          isSuperAdmin: false,
          accessScope: 'all',
          buildings: const [],
          language: 'en',
          license: const LicenseInfo(state: 'active', access: 'full'),
          modules: [
            MobileModule(id: 'facility_ops', label: 'Facility Ops', group: 'g', icon: 'x', webPath: '/x', pages: [for (final p in pages) ModulePage(id: p, label: p)]),
          ],
          webOnly: const [],
          catalogVersion: 1,
        );
    expect(catalogRedirect(boot(['visitors']), path), isNull);
    // A page switched off blocks its records too.
    expect(catalogRedirect(boot(['bookings']), path), unavailablePath);
  });

  test('visitor: check in, then check out, then nothing', () {
    List<String> labels(Map<String, dynamic> r) => visitorsSpec.actions!(r).map((a) => a.label).toList();
    expect(labels({'checkInAt': null}), ['act.check_in']);
    expect(labels({'checkInAt': '2026-10-01T06:22:42Z', 'checkOutAt': null}), ['act.check_out']);
    expect(labels({'checkInAt': '2026-10-01T06:22:42Z', 'checkOutAt': '2026-10-01T09:00:00Z'}), isEmpty);
  });

  test('visitor: a walk-in waiting for the host can be approved (P-015)', () async {
    final r = {'id': 'v1', 'status': 'pending_host_approval', 'checkInAt': '2026-10-01T06:22:42Z', 'checkOutAt': null};
    final actions = visitorsSpec.actions!(r);
    expect(actions.map((a) => a.label), ['act.approve', 'act.check_out']);
    final api = _RecordingApi();
    await actions.first.run!(api, r, null);
    expect(api.posts.single.$1, '/api/ops/visitors/v1/pre-register');
    expect(api.posts.single.$2, isEmpty); // keeps the host
  });

  test('nested lists: notifications, reports, intelligence', () {
    final n = notificationsSpec.list!;
    final nRows = n.items!({'success': true, 'data': {'notifications': [{'id': 'n1', 'title': 'Escalated', 'isRead': false}], 'total': 9}});
    expect(n.row(nRows.single).status, 'unread');
    expect(notificationsSpec.actions!(nRows.single).single.label, 'act.mark_read');
    expect(notificationsSpec.actions!({'isRead': true}), isEmpty);
    expect(n.pageQuery!(3, 20), {'limit': '20', 'offset': '40'});

    final r = reportsSpec.list!;
    expect(r.row(r.items!({'reports': [{'id': 'r1', 'name': 'Monthly'}]}).single).title, 'Monthly');

    final i = intelligenceSpec.list!;
    final caps = i.items!({'success': true, 'data': {'capabilities': [{'id': 'predictive', 'name': 'Predictive maintenance', 'headline': '31 assets likely to need attention', 'value': 31, 'tone': 'warn'}]}});
    expect(i.row(caps.single).title, 'Predictive maintenance');
    expect(i.row(caps.single).subtitle, '31 assets likely to need attention');
    expect(i.row({'id': 'risk'}).title, 'risk'); // older server: no name
  });

  test('chip text has no underscores or dashes', () {
    expect(chipLabel('checked_in'), 'checked in');
    expect(chipLabel('in-progress'), 'in progress');
    expect(chipLabel('Open'), 'Open');
  });

  test('chat session ids are v4 UUIDs', () {
    final id = newSessionId();
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(id), isTrue);
    expect(newSessionId(), isNot(id));
  });

  testWidgets('chat: sends message + session + env, shows the answer', (tester) async {
    final api = _ChatApi();
    const module = MobileModule(id: 'ask_flowai', label: 'Ask FlowAI', group: 'AI', icon: 'bot', webPath: '/fu-agent');
    final localization = FlutterLocalization.instance;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        loadedCatalogProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: localization.supportedLocales,
        localizationsDelegates: localization.localizationsDelegates,
        home: const ChatScreen(module: module, sessionId: 's-1'),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'How many DGs are running?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(api.lastBody, {'message': 'How many DGs are running?', 'sessionId': 's-1', 'env': 'test'});
    expect(find.text('How many DGs are running?'), findsOneWidget);
    expect(find.text('Two DGs are running.'), findsOneWidget);
  });
}

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(secureStore: SecureStore());
  final posts = <(String, Object?)>[];
  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add((path, body));
    return {'success': true};
  }
}
