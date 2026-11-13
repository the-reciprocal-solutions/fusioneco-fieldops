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
import 'package:technician_portal/admin/features/modules/module_summary_screen.dart';
import 'package:technician_portal/admin/features/modules/specs.dart';
import 'package:technician_portal/admin/features/modules/timeline_summary_screen.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';
import 'package:technician_portal/admin/widgets/open_on_web.dart';

/// The rollup's shape (server occupancyFootfall.ts `OccupancyRollup`), trimmed.
final _rollup = {
  'success': true,
  'data': {
    'cursorOccupancy': 120,
    'capacity': 400,
    'footfallTotal': 310,
    'footfallVsPrevPct': 4.5,
    'peak': {'value': 180, 't': DateTime(2026, 11, 2, 11, 15).millisecondsSinceEpoch},
    'entrances': [
      {'key': 'main', 'name': 'Main', 'count': 200},
      {'key': 'lab', 'name': 'Lab', 'count': 110},
    ],
    'floors': [
      {'storey': 'Level 1', 'level': 1, 'occupancy': 40, 'capacity': 200, 'pct': 20, 'rooms': 10},
      {'storey': 'Level 2', 'level': 2, 'occupancy': 80, 'capacity': 200, 'pct': 40, 'rooms': 12},
    ],
    'incidents': [
      {'spaceCode': 'MR-201', 'storey': 'Level 2', 'capacity': 8, 'peak': 11, 'from': DateTime(2026, 11, 2, 10).millisecondsSinceEpoch, 'to': DateTime(2026, 11, 2, 10, 30).millisecondsSinceEpoch},
    ],
    'topSpaces': [
      {'spaceCode': 'MR-201', 'storey': 'Level 2', 'role': 'Meeting', 'value': 9, 'capacity': 8},
      {'spaceCode': 'OF-101', 'storey': 'Level 1', 'role': 'Office', 'value': 0, 'capacity': 20},
    ],
  },
};

class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  Map<String, dynamic>? asked;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    if (path == '/api/timeline/occupancy/rollup') {
      asked = query;
      return _rollup;
    }
    if (path == '/api/fm/bs/building-systems') {
      return {
        'data': [
          {'id': 1, 'name': 'Tower A', 'status': 'active'},
        ],
      };
    }
    throw StateError('unexpected GET $path');
  }
}

Future<void> _pump(WidgetTester tester, _Api api, Widget home) async {
  final l = FlutterLocalization.instance;
  await tester.binding.setSurfaceSize(const Size(420, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api)],
    child: MaterialApp(theme: AppTheme.build(), supportedLocales: l.supportedLocales, localizationsDelegates: l.localizationsDelegates, home: home),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  test('today runs from local midnight to now', () {
    final w = todayWindow(DateTime(2026, 11, 2, 14, 30));
    expect(w.from, DateTime(2026, 11, 2).millisecondsSinceEpoch);
    expect(w.to, DateTime(2026, 11, 2, 14, 30).millisecondsSinceEpoch);
  });

  testWidgets('Timeline Revisit: today in numbers, then the desktop note (no web page)', (tester) async {
    final api = _Api();
    const m = MobileModule(id: 'timeline_revisit', label: 'Timeline Revisit', group: 'g', icon: 'clock', webPath: '/timeline-revisit');
    await _pump(tester, api, TimelineSummaryScreen(module: m, now: DateTime(2026, 11, 2, 14, 30)));

    expect(api.asked!['from'], '${DateTime(2026, 11, 2).millisecondsSinceEpoch}');
    expect(find.text('120 / 400'), findsOneWidget);
    expect(find.text('180 · 11:15'), findsOneWidget);
    expect(find.text('310 (+4.5%)'), findsOneWidget);
    // Top floor first, like the building.
    expect(tester.getTopLeft(find.text('Level 2').first).dy, lessThan(tester.getTopLeft(find.text('Level 1')).dy));
    expect(find.text('OF-101'), findsNothing); // empty rooms aren't "busiest"
    expect(find.text('11 / 8'), findsOneWidget);
    expect(find.text('Main'), findsOneWidget);
    expect(find.byType(DesktopNote), findsOneWidget);
    expect(find.textContaining('on a desktop'), findsOneWidget);
  });

  testWidgets('a summary screen has no "Open on web" button; Digital Twin says 3D is on the desktop', (tester) async {
    const m = MobileModule(id: 'digital_twin', label: 'Digital Twin', group: 'g', icon: 'box', webPath: '/digital-twin');
    await _pump(tester, _Api(), ModuleSummaryScreen(module: m, spec: moduleSpecs['digital_twin']!));
    expect(find.text('Tower A'), findsOneWidget);
    expect(find.byTooltip('Open on web'), findsNothing);
    expect(find.text('For the 3D twin of each building, use the web admin panel on a desktop.'), findsOneWidget);
  });
}
