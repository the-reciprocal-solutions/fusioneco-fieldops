import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/alert.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/alerts/alert_detail_screen.dart';
import 'package:technician_portal/admin/state/catalog_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// One open alert; actions change it as alertCenterController would.
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final posts = <(String, Map<String, Object?>)>[];
  Map<String, dynamic> alert = {
    'key': 'sa:1',
    'ref': 'AL-1',
    'title': 'Chiller 2 supply temp high',
    'severity': 'critical',
    'status': 'acknowledged',
    'sourceLabel': 'Sensor',
    'source': 'sensor',
    'assetId': 'as1',
    'buildingName': 'Tower A',
  };

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    if (path.endsWith('/assignees')) {
      return {
        'success': true,
        'data': [
          {'id': 'u2', 'name': 'Anita Raghavan', 'role': 'Technician', 'teams': ['HVAC']},
        ],
      };
    }
    return {
      'success': true,
      'data': {
        'alert': alert,
        'events': <Object>[],
        'can': {'assign': true, 'take': false, 'snooze': true},
        'snoozeChoices': [15, 60, 1440],
      },
    };
  }

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    final b = (body as Map).cast<String, Object?>();
    posts.add((path, b));
    final action = path.split('/').last;
    alert = {
      ...alert,
      if (action == 'assign') 'assignee': {'id': b['userId'], 'name': 'Anita Raghavan'},
      if (action == 'snooze') 'snoozedUntil': DateTime.now().add(Duration(minutes: b['minutes']! as int)).toUtc().toIso8601String(),
      if (action == 'snooze') 'snoozeReason': b['reason'],
      if (action == 'unsnooze') 'snoozedUntil': null,
      if (action == 'work_order') 'workOrder': b['workOrderId'] == null ? null : {'id': 'w1', 'ref': b['workOrderId'], 'status': 'Open'},
    };
    return {'success': true, 'data': alert};
  }
}

MobileBootstrap _boot() => const MobileBootstrap(
      role: 'Admin',
      isSuperAdmin: false,
      accessScope: 'all',
      buildings: [],
      language: 'en',
      license: LicenseInfo(state: 'active', access: 'full'),
      modules: [
        MobileModule(id: 'alerts', label: 'Alerts', group: 'g', icon: 'bell', webPath: '/alerts'),
        MobileModule(id: 'work_orders', label: 'Work Orders', group: 'g', icon: 'wrench', webPath: '/wo'),
      ],
      webOnly: [],
      catalogVersion: 1,
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  Future<_Api> pump(WidgetTester tester) async {
    final api = _Api();
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const AlertDetailScreen(alertKey: 'sa:1')),
      GoRoute(path: '/m/:m/r/:id', builder: (_, s) => Scaffold(body: Text('opened ${s.pathParameters['m']} ${s.pathParameters['id']}'))),
    ]);
    final l = FlutterLocalization.instance;
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api), loadedCatalogProvider.overrideWithValue(_boot())],
      child: MaterialApp.router(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('assign: the sheet lists who can see it; the pick is sent', (tester) async {
    final api = await pump(tester);
    await tester.tap(find.text('Assign'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anita Raghavan'));
    await tester.pumpAndSettle();
    expect(api.posts.single.$1, '/api/fm/alerts/sa%3A1/assign');
    expect(api.posts.single.$2, {'userId': 'u2'});
    expect(find.text('Assigned to Anita Raghavan'), findsOneWidget);
  });

  testWidgets('snooze needs a reason; then End snooze undoes it', (tester) async {
    final api = await pump(tester);
    await tester.tap(find.text('Snooze'));
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(TextButton, 'Snooze');
    expect(tester.widget<TextButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, 'contractor on site');
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(api.posts.single.$2, {'minutes': 60, 'reason': 'contractor on site'});
    expect(find.text('Snoozed for 1 h'), findsOneWidget);
    expect(find.textContaining('contractor on site'), findsOneWidget); // the Snoozed fact

    await tester.tap(find.text('End snooze'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$1, '/api/fm/alerts/sa%3A1/unsnooze');
  });

  testWidgets('work order: link by number, open it, unlink', (tester) async {
    final api = await pump(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Work order'));
    await tester.pumpAndSettle();
    expect(find.text('Create work order'), findsOneWidget);
    await tester.tap(find.text('Link a work order'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' WO-762 ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.posts.single.$2, {'workOrderId': 'WO-762'});
    expect(find.text('WO-762 · Open'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Work order'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open WO-762'));
    await tester.pumpAndSettle();
    expect(find.text('opened work_orders w1'), findsOneWidget);
    GoRouter.of(tester.element(find.textContaining('opened'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Work order'));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.text('Unlink work order'))).clearSnackBars(); // "linked" still showing
    await tester.tap(find.text('Unlink work order'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$2, {'workOrderId': null});
    expect(find.text('Work order unlinked'), findsOneWidget);
  });

  test("create work order: the web form's link, filled in like the web's", () {
    final a = AlertItem.fromJson({
      'key': 'sa:1',
      'ref': 'AL-1',
      'title': 'Chiller hot',
      'severity': 'high',
      'detail': 'Supply 12 °C',
      'buildingName': 'Tower A',
      'sourceLabel': 'Sensor',
      'source': 'sensor',
      'assetId': 'as1',
    });
    final q = Uri.parse(workOrderCreatePath(a)).queryParameters;
    expect(Uri.parse(workOrderCreatePath(a)).path, '/facility-management/work-order/create');
    expect(q['alert'], 'sa:1');
    expect(q['priority'], 'High');
    expect(q['assetId'], 'as1');
    expect(q['description'], 'Supply 12 °C\nBuilding: Tower A\nAlert AL-1 · Sensor');
    // An access alarm's "asset" is the door zone, not an FM asset.
    expect(Uri.parse(workOrderCreatePath(AlertItem.fromJson({'key': 'ac:1', 'source': 'access', 'assetId': 'z1'}))).queryParameters.containsKey('assetId'), isFalse);
  });

  test('building filter: sent as a comma list; the summary facet is read', () {
    expect(const AlertFilters(buildings: {'b1'}).toQuery()['building'], 'b1');
    expect(const AlertFilters().toQuery().containsKey('building'), isFalse);
    expect(const AlertFilters(buildings: {'b1'}) == const AlertFilters(), isFalse);
    final s = AlertSummary.fromJson({
      'facets': {
        'building': [
          {'value': 'b1', 'label': 'Tower A', 'count': 9},
          {'value': 'none', 'label': 'No building', 'count': 2},
        ],
      },
    });
    expect(s.buildings.map((b) => (b.id, b.count)), [('b1', 9), ('none', 2)]);
  });
}
