import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/features/modules/fm_specs.dart';
import 'package:technician_portal/admin/features/modules/pm_report_screen.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// The server's shape (pmComplianceReportService.ts, 2026-11-02).
final _rows = [
  {'id': 'p1', 'pmScheduleId': 'PM-0001', 'assetName': 'AHU-01', 'pmCategory': 'regulatory', 'status': 'completed', 'plannedDate': '2026-01-10T00:00:00Z', 'completedDate': '2026-01-11T00:00:00Z', 'technicianName': 'Balaji'},
  {'id': 'p1', 'pmScheduleId': 'PM-0001', 'assetName': 'AHU-01', 'pmCategory': 'regulatory', 'status': 'pending', 'plannedDate': '2026-04-10T00:00:00Z'},
  {'id': 'p2', 'pmScheduleId': 'PM-0002', 'assetName': 'Fire pump, "main"', 'pmCategory': 'oem', 'status': 'cancelled', 'plannedDate': '2026-04-20T00:00:00Z'},
];

class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final asked = <Map<String, dynamic>>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    expect(path, '/api/fm/preventive-maintenance/compliance-report');
    asked.add(query!);
    final empty = query['year'] != '2026';
    return {
      'success': true,
      'data': {
        'building': {'id': 'b1', 'name': 'Tower A'},
        'year': int.parse('${query['year']}'),
        'total': empty ? 0 : 3,
        'completed': empty ? 0 : 1,
        'open': empty ? 0 : 2,
        'coveragePercent': empty ? null : 33.3,
        'rows': empty ? <Object>[] : _rows,
      },
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

  test('a building row: percentage on the card, the name in the detail header', () {
    final row = pmComplianceSpec.list!.row({'id': 'b1', 'name': 'Tower A', 'sub': 'Saravanampatti', 'total': 4, 'done': 3, 'open': 1, 'cov': 75});
    expect(row.ref, '75%');
    expect(row.refInHeader, isFalse);
  });

  test('rows by month, in order', () {
    final m = rowsByMonth(_rows);
    expect(m.keys.toList(), ['2026-01', '2026-04']);
    expect(m['2026-04'], hasLength(2));
  });

  test('CSV: the web table columns, quoted where needed', () {
    final csv = pmReportCsv(_rows).split('\r\n');
    expect(csv.first, 'PM #,Asset,Location,Category,Status,Planned,Completed,Technician');
    expect(csv[1], 'PM-0001,AHU-01,,regulatory,completed,2026-01-10,2026-01-11,Balaji');
    expect(csv[3], startsWith('PM-0002,"Fire pump, ""main""",'));
  });

  testWidgets('a year, its totals, rows by month; filters and years reload', (tester) async {
    final api = _Api();
    final l = FlutterLocalization.instance;
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        home: const PmReportScreen(buildingId: 'b1', buildingName: 'Tower A', year: 2026),
      ),
    ));
    await tester.pumpAndSettle();
    expect(api.asked.single, {'buildingId': 'b1', 'year': '2026', 'pmCategory': 'regulatory,oem'});
    expect(find.text('33.3%'), findsOneWidget);
    expect(find.text('JANUARY 2026'), findsOneWidget);
    expect(find.text('APRIL 2026'), findsOneWidget);
    expect(find.text('AHU-01'), findsNWidgets(2));

    await tester.tap(find.text('OEM only'));
    await tester.pumpAndSettle();
    expect(api.asked.last['pmCategory'], 'oem');

    await tester.tap(find.byTooltip('Previous year'));
    await tester.pumpAndSettle();
    expect(api.asked.last['year'], '2025');
    expect(find.text('No records'), findsOneWidget);
    expect(find.text('No PMs of this kind in this year.'), findsOneWidget);
  });
}
