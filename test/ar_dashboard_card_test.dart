import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/storage/session_store.dart';
import 'package:technician_portal/features/ar/widgets/ar_entry_widgets.dart';
import 'package:technician_portal/state/ar_availability.dart';
import 'package:technician_portal/state/ar_prefs_controller.dart';
import 'package:technician_portal/state/auth_controller.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// Owner, 2026-10-06: "make AR active by default". The dashboard card shows
/// unless the client explicitly set isArView = false; with no published
/// model it says so and offers the demo room + "Scan an AR board".
const _strings = {
  'ar.dashboard.title': 'AR: the model where you stand',
  'ar.dashboard.sub': 'Find hidden assets, check installs, leave boards for next time.',
  'ar.dashboard.sub_demo': 'Demo mode is on — sample building, nothing is saved.',
  'ar.dashboard.no_models': 'No AR model for your buildings yet',
  'ar.dashboard.try_demo': 'Try the demo room',
  'ar.dashboard.scan_board': 'Scan an AR board',
  'ar.dashboard.scan': 'Scan a board',
  'ar.dashboard.floor': 'Open a floor',
  'ar.dashboard.install': 'Install run',
  'ar.dashboard.demo': 'Demo',
};

class _Auth extends AuthController {
  _Auth(this.isArView);
  final bool? isArView;
  @override
  AuthState build() => AuthState(
        session: const Session(userId: 'u1', name: 'Ravi'),
        permissions: Permissions(isArView: isArView),
      );
}

/// No offline DB in a widget test: demo flag lives in memory.
class _Prefs extends ArPrefsController {
  @override
  ArPrefsState build() => const ArPrefsState(loaded: true);
  @override
  Future<void> setDemo(bool on) async => state = state.copyWith(demo: on);
}

Future<void> _pump(WidgetTester tester, {bool? isArView, FutureOr<bool> Function()? anyModels}) async {
  final localization = FlutterLocalization.instance;
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const Scaffold(body: SingleChildScrollView(child: ArDashboardCard())),
    ),
    GoRoute(path: '/ar/marker/:code', builder: (_, s) => Text('demo room ${s.pathParameters['code']}')),
    GoRoute(path: '/scan', builder: (_, _) => const Text('scanner')),
  ]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => _Auth(isArView)),
        arPrefsProvider.overrideWith(_Prefs.new),
        arAnyBuildingProvider.overrideWith((ref) async => (anyModels ?? () => false)()),
      ],
      child: MaterialApp.router(
        theme: AppTheme.build(),
        supportedLocales: localization.supportedLocales,
        localizationsDelegates: localization.localizationsDelegates,
        locale: localization.currentLocale,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final localization = FlutterLocalization.instance;
    await localization.ensureInitialized();
    localization.init(mapLocales: [const MapLocale('en', _strings)], initLanguageCode: 'en');
  });

  testWidgets('no flag from the server (older tenant) + no model: card shows, says so, offers demo', (tester) async {
    await _pump(tester, isArView: null);
    expect(find.text('AR: the model where you stand'), findsOneWidget);
    expect(find.text('No AR model for your buildings yet'), findsOneWidget);
    expect(find.text('Try the demo room'), findsOneWidget);
    expect(find.text('Scan an AR board'), findsOneWidget);
  });

  testWidgets('client explicitly switched AR off: hidden', (tester) async {
    await _pump(tester, isArView: false);
    expect(find.text('AR: the model where you stand'), findsNothing);
  });

  testWidgets('published model: the usual card, no "no model" line', (tester) async {
    await _pump(tester, isArView: true, anyModels: () => true);
    expect(find.text('Find hidden assets, check installs, leave boards for next time.'), findsOneWidget);
    expect(find.text('Open a floor'), findsOneWidget);
    expect(find.text('No AR model for your buildings yet'), findsNothing);
  });

  testWidgets('availability check fails (older server 404/500): card still shows, as "no model"', (tester) async {
    await _pump(tester, isArView: true, anyModels: () => throw Exception('404'));
    expect(find.text('No AR model for your buildings yet'), findsOneWidget);
  });

  testWidgets('"Try the demo room" switches Demo on and opens the sample board', (tester) async {
    await _pump(tester, isArView: true);
    await tester.tap(find.text('Try the demo room'));
    await tester.pumpAndSettle();
    expect(find.textContaining('demo room'), findsOneWidget);
  });

  testWidgets('"Scan an AR board" opens the scanner', (tester) async {
    await _pump(tester, isArView: true);
    await tester.tap(find.text('Scan an AR board'));
    await tester.pumpAndSettle();
    expect(find.text('scanner'), findsOneWidget);
  });

  test('card mode provider', () async {
    final c = ProviderContainer(overrides: [
      authControllerProvider.overrideWith(() => _Auth(null)),
      arAnyBuildingProvider.overrideWith((ref) async => true),
    ]);
    addTearDown(c.dispose);
    final sub = c.listen(arCardModeProvider, (_, _) {});
    expect(sub.read(), ArCardMode.checking);
    await c.read(arAnyBuildingProvider.future);
    expect(c.read(arCardModeProvider), ArCardMode.models);
  });
}
