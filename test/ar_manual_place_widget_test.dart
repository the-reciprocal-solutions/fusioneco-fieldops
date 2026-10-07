import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/features/ar/ar_ui.dart';
import 'package:technician_portal/features/ar/setup/ar_method_chooser.dart';
import 'package:technician_portal/features/ar/setup/manual/ar_manual_place_overlay.dart';
import 'package:technician_portal/features/ar/widgets/ar_chrome.dart';
import 'package:technician_portal/state/ar_manual_place_controller.dart';
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_setup_controller.dart';
import 'package:technician_portal/state/providers.dart';
import 'package:technician_portal/theme/app_theme.dart';
import 'package:technician_portal/theme/fe_ar_colors.dart';

import 'manual_place_test_fakes.dart';

/// "Place by hand" screen at phone sizes, in English and Arabic (RTL), in
/// Sunlight mode too: nothing overflows with every panel open, the readout
/// and the scale badge show, a drag on the camera moves the model, and the
/// chooser offers the method (first, on a floor with few corners).

Map<String, dynamic> _strings(String lang) =>
    jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;

Widget _app(Widget child, {String lang = 'en'}) => MaterialApp(
  theme: AppTheme.build(),
  supportedLocales: FlutterLocalization.instance.supportedLocales,
  localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
  locale: Locale(lang),
  home: Scaffold(backgroundColor: FeArColors.cameraFloor, body: ArSunlightHost(child: child)),
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final l = FlutterLocalization.instance;
    await l.ensureInitialized();
    l.init(mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))], initLanguageCode: 'en');
  });

  test('every ar.manual / ar.method.manual / ar.badge.hand key is in both files', () {
    final en = _strings('en');
    final ar = _strings('ar');
    final keys = en.keys.where((k) => k.startsWith('ar.manual.') || k.startsWith('ar.method.manual') || k.startsWith('ar.badge.hand') || k == 'ar.measure.result_approx');
    expect(keys.length, greaterThan(55));
    for (final k in keys) {
      expect(ar.containsKey(k), isTrue, reason: k);
      expect('%a'.allMatches(ar[k] as String).length, '%a'.allMatches(en[k] as String).length, reason: k);
    }
    // And the other way round.
    for (final k in ar.keys.where((k) => k.startsWith('ar.manual.'))) {
      expect(en.containsKey(k), isTrue, reason: k);
    }
  });

  const sizes = {
    'phone 360x780': Size(360, 780),
    'small 320x568': Size(320, 568),
    'landscape 915x412': Size(915, 412),
  };

  for (final lang in ['en', 'ar']) {
    for (final sunlight in [false, true]) {
      for (final e in sizes.entries) {
        testWidgets('Place by hand fits — ${e.key} ($lang${sunlight ? ', Sunlight' : ''})', (tester) async {
          FlutterLocalization.instance.translate(lang);
          tester.view.physicalSize = e.value * 2;
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.reset);
          addTearDown(() => FlutterLocalization.instance.translate('en'));

          final store = PrefStore();
          if (sunlight) store.prefs['sunlight'] = '1';
          store.prefs['manual:size:f-bed'] = jsonEncode({'scale': 1.12, 'stretchX': 1, 'stretchZ': 1, 'heightM': 0});
          final session = ManualFakeSession(manualSession());
          session.viewSize = e.value;
          final io = TestManualIo(
            width: e.value.width,
            height: e.value.height,
            walls: [testWall('north', const Vec2(-1.2, -3.9), const Vec2(2, -3.9), const Vec2(0, 1))],
          );
          final layout = arLayoutFor(e.value);
          await tester.pumpWidget(ProviderScope(
            overrides: [
              arPackStoreProvider.overrideWithValue(store),
              arSessionProvider.overrideWith(() => session),
              arSetupProvider.overrideWith(IdleSetup.new),
              arManualIoProvider.overrideWithValue(io),
            ],
            child: _app(
              ArManualPlaceOverlay(tablet: false, topInset: 76, landscape: layout == ArLayout.landscapePhone),
              lang: lang,
            ),
          ));
          await tester.pump();
          final container = ProviderScope.containerOf(tester.element(find.byType(ArManualPlaceOverlay)));
          final ctrl = container.read(arManualPlaceProvider.notifier);
          // ignore: unawaited_futures
          ctrl.begin();
          await tester.pump(const Duration(milliseconds: 200));
          var err = tester.takeException();
          expect(err, isNull, reason: 'loaded: $err');
          final m0 = container.read(arManualPlaceProvider);
          expect(m0.active, isTrue);
          expect(m0.pose, isNotNull);
          final ctx = tester.element(find.byType(ArManualPlaceOverlay));

          // The coach line and the readout.
          expect(find.text('ar.manual.coach.drag'.getString(ctx)), findsOneWidget);
          expect(find.textContaining('100'), findsWidgets);
          expect(find.text('ar.manual.lock'.getString(ctx)), findsOneWidget);

          // A one-finger drag on the camera moves the model.
          final before = container.read(arManualPlaceProvider).pose!;
          await tester.dragFrom(Offset(e.value.width / 2, e.value.height * 0.45), const Offset(40, -30));
          await tester.pump(const Duration(milliseconds: 100));
          expect(container.read(arManualPlaceProvider).pose!.pos, isNot(before.pos));
          expect(container.read(arManualPlaceProvider).moved, isTrue);

          // Every panel opens without overflowing.
          for (final key in ['ar.manual.nudge', 'ar.manual.height', 'ar.manual.more']) {
            await tester.tap(find.bySemanticsLabel(key.getString(ctx)).first);
            await tester.pump(const Duration(milliseconds: 100));
            err = tester.takeException();
            expect(err, isNull, reason: '$key: $err');
          }
          // More is open: "Use last size (112%)" is there; stretch on shows its sliders.
          expect(find.textContaining('112'), findsWidgets);
          ctrl.setStretchOn(true);
          await tester.pump(const Duration(milliseconds: 100));
          err = tester.takeException();
          expect(err, isNull, reason: 'stretch on: $err');

          // Nudge pad buttons work.
          ctrl.openPanel(ManualPanel.nudge);
          await tester.pump();
          final p0 = container.read(arManualPlaceProvider).pose!;
          await tester.tap(find.bySemanticsLabel('ar.manual.nudge_up'.getString(ctx)).first);
          await tester.pump(const Duration(milliseconds: 50));
          expect(container.read(arManualPlaceProvider).pose!.heightM, closeTo(p0.heightM + 0.01, 1e-9));

          // Pinch to 120 %: the badge says so, and "True size" fixes it.
          ctrl.twoStart();
          ctrl.twoUpdate(rotationRad: 0, scale: 1.2, dxPx: 0, dyPx: 0);
          ctrl.twoEnd();
          await tester.pump(const Duration(milliseconds: 100));
          final badge = find.text('ar.manual.not_true_size'.getString(ctx));
          expect(badge, findsOneWidget);
          expect(find.textContaining('120'), findsWidgets);
          err = tester.takeException();
          expect(err, isNull, reason: 'badge: $err');
          await tester.tap(find.widgetWithText(FilledButton, 'ar.manual.true_size'.getString(ctx)));
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('ar.manual.not_true_size'.getString(ctx)), findsNothing);

          // The corner tool and the coach line it brings.
          ctrl.openPanel(ManualPanel.nudge); // close
          await tester.tap(find.bySemanticsLabel('ar.manual.snap_corner'.getString(ctx)).first);
          await tester.pump(const Duration(milliseconds: 100));
          expect(container.read(arManualPlaceProvider).cornerMode, isTrue);
          expect(find.text('ar.manual.coach.corner'.getString(ctx)), findsOneWidget);
          err = tester.takeException();
          expect(err, isNull, reason: 'corner mode: $err');

          // Lock hands over to the workspace.
          await tester.tap(find.text('ar.manual.lock'.getString(ctx)));
          await tester.pump(const Duration(milliseconds: 100));
          expect(container.read(arManualPlaceProvider).active, isFalse);
          expect(container.read(arSessionProvider).stage, ArSessionStage.work);
          expect(container.read(arSessionProvider).fit!.isHandPlaced, isTrue);
        });
      }
    }
  }

  for (final lang in ['en', 'ar']) {
    testWidgets('chooser offers Place by hand first on a floor with few corners ($lang)', (tester) async {
      FlutterLocalization.instance.translate(lang);
      tester.view.physicalSize = const Size(360, 780) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      addTearDown(() => FlutterLocalization.instance.translate('en'));
      final session = ManualFakeSession(manualSession());
      await tester.pumpWidget(ProviderScope(
        overrides: [
          arPackStoreProvider.overrideWithValue(PrefStore()),
          arSessionProvider.overrideWith(() => session),
          arSetupProvider.overrideWith(IdleSetup.new),
          arManualIoProvider.overrideWithValue(TestManualIo()),
        ],
        child: _app(const SingleChildScrollView(padding: EdgeInsets.all(12), child: ArMethodChooser(tablet: false)), lang: lang),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      final ctx = tester.element(find.byType(ArMethodChooser));
      final title = find.text('ar.method.manual'.getString(ctx));
      expect(title, findsOneWidget);
      // First tile, with the "Best here" tag.
      final best = find.text('ar.method.best_here'.getString(ctx));
      expect(best, findsOneWidget);
      expect(tester.getTopLeft(title).dy, lessThan(tester.getTopLeft(find.text('ar.method.board'.getString(ctx))).dy));
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 200));
      final container = ProviderScope.containerOf(ctx);
      expect(container.read(arManualPlaceProvider).active, isTrue);
      // Stop the timers before teardown.
      await container.read(arManualPlaceProvider.notifier).cancel();
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
