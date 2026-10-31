import 'dart:convert';
import 'dart:io';

import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/home/home_screen.dart';
import 'package:technician_portal/admin/features/modules/fm_specs.dart';
import 'package:technician_portal/admin/features/modules/module_spec.dart';
import 'package:technician_portal/admin/features/modules/module_summary_screen.dart';
import 'package:technician_portal/admin/features/modules/record_detail_screen.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Response bodies shaped like the live server's (probed 2026-10-30).
final _woRow = {
  'id': 'w1',
  'workOrderId': 'WO-762',
  'title': 'Chiller noise',
  'status': 'Open',
  'priority': 'High',
  'location': 'Tower A / Roof',
  'technicianName': 'Balaji',
  'dueDate': '2026-10-09T00:00:00.000Z',
  'cost': '78210.00',
  'currency': 'AED',
};

class _FakeApi extends ApiClient {
  _FakeApi() : super(secureStore: SecureStore());
  final gets = <String>[];
  final posts = <(String, Object?)>[];
  Map<String, dynamic>? lastQuery;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    gets.add(path);
    lastQuery = query;
    if (path.endsWith('/analytics')) {
      return {
        'success': true,
        'data': {
          'summary': {'openWorkOrders': 44, 'inProgressWorkOrders': 11, 'overdueWorkOrders': 58, 'onTimeCompletionRate': 85.14},
        },
      };
    }
    if (path == '/api/fm/work-order') {
      final page = int.parse('${query?['page'] ?? 1}');
      return {
        'success': true,
        'data': page == 1 ? [for (var i = 0; i < 20; i++) {..._woRow, 'id': 'w$i', 'title': 'Order $i'}] : [_woRow],
        'pagination': {'total': 21, 'page': page, 'limit': 20, 'totalPages': 2},
      };
    }
    if (path.startsWith('/api/fm/work-order/')) return {'success': true, 'data': posts.isEmpty ? _woRow : {..._woRow, 'status': 'In Progress'}};
    throw StateError('unexpected GET $path');
  }

  @override
  Future<dynamic> post(String path, {Object? body}) async {
    posts.add((path, body));
    return {'success': true};
  }
}

const _module = MobileModule(id: 'work_orders', label: 'Work Orders', group: 'Facility Management', icon: 'wrench', webPath: '/x');

Future<_FakeApi> _pump(WidgetTester tester, Widget screen) async {
  final api = _FakeApi();
  final localization = FlutterLocalization.instance;
  await tester.pumpWidget(ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api)],
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

  group('tolerant readers (the four FM envelope shapes)', () {
    test('rowsOf / totalOf', () {
      expect(rowsOf({'data': [{'a': 1}]}).single['a'], 1);
      expect(rowsOf({'data': {'items': [{'a': 2}], 'total': 9}}).single['a'], 2);
      expect(rowsOf({'documents': [{'a': 3}], 'total': 4}).single['a'], 3);
      expect(rowsOf([{'a': 4}]).single['a'], 4);
      expect(rowsOf({'data': null}), isEmpty);
      expect(totalOf({'pagination': {'total': 21}}), 21);
      expect(totalOf({'data': {'items': [], 'total': 3}}), 3);
      expect(totalOf({'documents': [], 'total': 40}), 40);
      expect(totalOf({'data': []}), isNull);
    });

    test('numbers: counts may arrive as strings', () {
      expect(fmtNum('35'), '35');
      expect(fmtNum(1234), '1,234');
      expect(fmtNum(684000), '684k');
      expect(fmtNum(23639546.04), '23.6M');
      expect(fmtNum(null), '–');
      expect(fmtPct(85.14), '85%');
      expect(countIn([{'status': 'overdue', 'count': '35'}], 'status', 'OVERDUE'), 35);
      expect(fmtMoney('78210.00', 'AED'), 'AED 78,210');
    });
  });

  group('actions follow the record state (server-allowed moves only)', () {
    List<String> labels(ModuleSpec s, Map<String, dynamic> r) => s.actions!(r).map((a) => a.label).toList();

    test('work order', () {
      expect(labels(workOrdersSpec, {'status': 'Open'}), ['act.start', 'act.hold', 'act.comment']);
      expect(labels(workOrdersSpec, {'status': 'In Progress'}), ['act.complete', 'act.hold', 'act.comment']);
      expect(labels(workOrdersSpec, {'status': 'Completed'}), ['act.comment']);
    });

    test('permit: approve / reject only while submitted', () {
      expect(labels(permitsSpec, {'status': 'submitted'}), ['act.approve', 'act.reject']);
      expect(labels(permitsSpec, {'status': 'approved'}), isEmpty);
    });

    test('quote Sent → accept/reject; invoice Draft/Pending → approve', () {
      expect(labels(quotesSpec, {'status': 'Sent'}), ['act.accept', 'act.reject']);
      expect(labels(quotesSpec, {'status': 'Draft'}), isEmpty);
      expect(labels(invoicesSpec, {'status': 'Pending Approval'}), ['act.approve']);
      expect(labels(invoicesSpec, {'status': 'Overdue'}), isEmpty);
    });

    test('assets never show camera credentials', () {
      final facts = assetsSpec.facts!({'cameraUsername': 'admin', 'cameraPassword': 'secret', 'name': 'Cam'});
      expect(facts.map((f) => f.$2), isNot(contains('secret')));
    });
  });

  test('dashboard tiles from a live-shaped doc', () {
    final sections = dashboardSections({
      'total_sq_ft': {'curr_site_count': 6, 'curr_total_sq_ft': 684000},
      'asset_health': {'total': 141, 'breakdown': [{'status': 'excellent', 'count': 21}, {'status': 'good', 'count': 58}, {'status': 'critical', 'count': 19}]},
      'maintenance_risk': {'breakdown': [{'level': 'high', 'count': 49}]},
      'center': {'floors': 21, 'occupancy': 243, 'capacity': 680},
      'operational': {'pct': 100},
      'curr_month_units': [{'total_units_kwh': 0}],
    });
    final all = {for (final (_, kpis) in sections) for (final k in kpis) k.label: k.value};
    expect(all['home.sites'], '6');
    expect(all['home.health_good'], '79');
    expect(all['home.health_poor'], '19');
    expect(all['home.risk_high'], '49');
    expect(all['home.occupancy'], '243 / 680');
    expect(all['home.avg_temp'], '–');
  });

  testWidgets('work orders: tiles, first page, next page on scroll', (tester) async {
    final api = await _pump(tester, ModuleSummaryScreen(module: _module, spec: workOrdersSpec));
    expect(find.text('58'), findsOneWidget); // overdue tile
    expect(find.text('85%'), findsOneWidget);
    expect(find.text('21 records'), findsOneWidget);
    expect(find.text('Order 0'), findsOneWidget);
    expect(api.lastQuery, containsPair('page', '1'));

    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await tester.pumpAndSettle();
    expect(api.lastQuery, containsPair('page', '2'));
  });

  testWidgets('record detail: facts, then an action posts and the record refreshes', (tester) async {
    final api = await _pump(tester, RecordDetailScreen(spec: workOrdersSpec, recordId: 'w1', initial: _woRow));
    expect(find.text('WO-762'), findsOneWidget);
    expect(find.text('Balaji'), findsOneWidget);
    expect(find.text('AED 78,210'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(api.posts.single.$1, '/api/fm/work-order/w1/status');
    expect(api.posts.single.$2, {'status': 'In Progress'});
    // Refetched: now In Progress → Complete is offered.
    expect(find.text('Complete'), findsOneWidget);
  });

  testWidgets('a required-text action does nothing when the text is left empty', (tester) async {
    final api = await _pump(tester, RecordDetailScreen(spec: workOrdersSpec, recordId: 'w1', initial: _woRow));
    await tester.tap(find.text('Put on hold'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.posts, isEmpty);

    await tester.tap(find.text('Put on hold'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Waiting for parts');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.posts.single.$2, {'status': 'On Hold', 'holdReason': 'Waiting for parts'});
  });
}
