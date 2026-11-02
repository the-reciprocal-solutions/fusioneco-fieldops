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
import 'package:technician_portal/admin/domain/mobile_catalog.dart';
import 'package:technician_portal/admin/features/modules/amc_calendar_screen.dart';
import 'package:technician_portal/admin/state/providers.dart';
import 'package:technician_portal/admin/theme/app_theme.dart';

/// The calendar's live shape (2026-11-01): `{data: {"YYYY-MM": {day: [item]}}}`.
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final asked = <String>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    expect(path, '/api/fm/schedule-management/calendar');
    asked.add('${query!['year']}-${query['month']}');
    if (query['month'] != '10') return {'success': true, 'data': <String, dynamic>{}};
    return {
      'success': true,
      'data': {
        '2026-10': {
          '5': [
            {'id': 's1', 'type': 'work-order', 'status': 'On Hold', 'assetName': 'FCU 5th-Floor', 'technicianName': 'Balaji'},
          ],
          '12': [
            {'id': 's2', 'type': 'preventive', 'status': 'pending', 'assetName': 'AHU-01'},
            {'id': 's3', 'type': 'preventive', 'status': 'completed', 'assetName': 'AHU-02'},
          ],
        },
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

  test('the month\'s items by day', () {
    final days = calendarDays({
      'data': {
        '2026-10': {'5': [{'id': 'a'}], 'x': [{'id': 'b'}]},
        '2026-11': {'1': [{'id': 'c'}]},
      },
    }, 2026, 10);
    expect(days.keys, [5]);
    expect(calendarDays({'data': <String, dynamic>{}}, 2026, 10), isEmpty);
  });

  testWidgets('one month at a time; a day lists its work; an item opens its record', (tester) async {
    final api = _Api();
    const module = MobileModule(id: 'amc', label: 'AMC', group: 'g', icon: 'calendar', webPath: '/amc');
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => AmcCalendarScreen(module: module, initialMonth: DateTime(2026, 10))),
      GoRoute(path: '/m/:m/r/:id', builder: (_, s) => Scaffold(body: Text('opened ${s.pathParameters['m']} ${s.pathParameters['id']}'))),
    ]);
    final l = FlutterLocalization.instance;
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp.router(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    expect(api.asked, ['2026-10']);
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('3 scheduled this month'), findsOneWidget);

    await tester.tap(find.text('12'));
    await tester.pumpAndSettle();
    expect(find.text('AHU-01'), findsOneWidget);
    expect(find.text('AHU-02'), findsOneWidget);

    await tester.tap(find.text('5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FCU 5th-Floor'));
    await tester.pumpAndSettle();
    expect(find.text('opened amc s1'), findsOneWidget);
    GoRouter.of(tester.element(find.text('opened amc s1'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(api.asked.last, '2026-11');
    expect(find.text('0 scheduled this month'), findsOneWidget);
  });
}
