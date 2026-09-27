import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/ar/ar_engine.dart' show ArCapabilities;
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/core/offline/offline_db.dart' show ArPackStore;
import 'package:technician_portal/features/ar/ar_ui.dart';
import 'package:technician_portal/features/ar/setup/ar_method_chooser.dart';
import 'package:technician_portal/features/ar/widgets/ar_chrome.dart';
import 'package:technician_portal/features/ar/workspace/ar_workspace.dart';
import 'package:technician_portal/state/ar_permissions.dart';
import 'package:technician_portal/state/ar_prefs_controller.dart';
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_setup_controller.dart';
import 'package:technician_portal/state/ar_workspace_controller.dart';
import 'package:technician_portal/state/providers.dart';
import 'package:technician_portal/theme/app_theme.dart';
import 'package:technician_portal/theme/fe_ar_colors.dart';
import 'package:technician_portal/theme/fe_colors.dart';

import 'ar_workspace_fakes.dart';

/// Sunlight mode (high-contrast AR chrome): the pref persists through the
/// `ar_prefs` store, the shared chrome widgets switch to the opaque
/// near-black + white-outline look when it is on (and back when it is off),
/// and the workspace, menu and method chooser still fit a small phone and a
/// phone on its side with the larger, heavier text.

/// Only the two pref calls; everything else in [ArPackStore] is unused here.
class _PrefStore implements ArPackStore {
  final prefs = <String, String>{};

  @override
  Future<String?> getArPref(String key) async => prefs[key];

  @override
  Future<void> setArPref(String key, String? value) async {
    if (value == null) {
      prefs.remove(key);
    } else {
      prefs[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _IdleSetup extends ArSetupController {
  @override
  ArSetupState build() => const ArSetupState();
}

Map<String, dynamic> _strings(String lang) =>
    jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;

Widget _app(Widget child, {String lang = 'en'}) => MaterialApp(
  theme: AppTheme.build(),
  supportedLocales: FlutterLocalization.instance.supportedLocales,
  localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
  locale: Locale(lang),
  home: Scaffold(backgroundColor: FeArColors.cameraFloor, body: ArSunlightHost(child: child)),
);

Material _materialOf(WidgetTester tester, Finder f) =>
    tester.widget<Material>(find.descendant(of: f, matching: find.byType(Material)).first);

BoxDecoration _decorationOf(WidgetTester tester, Finder f) =>
    tester.widget<Container>(find.descendant(of: f, matching: find.byType(Container)).first).decoration! as BoxDecoration;

TextStyle _textStyle(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style!;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final l = FlutterLocalization.instance;
    await l.ensureInitialized();
    l.init(
      mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))],
      initLanguageCode: 'en',
    );
  });

  group('pref', () {
    test('defaults off, persists on and off, and is restored by a new controller', () async {
      final store = _PrefStore();
      final c1 = ProviderContainer(overrides: [arPackStoreProvider.overrideWithValue(store)]);
      addTearDown(c1.dispose);
      c1.read(arPrefsProvider);
      await c1.read(arPrefsProvider.notifier).ready;
      expect(c1.read(arPrefsProvider).sunlight, isFalse);

      await c1.read(arPrefsProvider.notifier).setSunlight(true);
      expect(c1.read(arPrefsProvider).sunlight, isTrue);
      expect(store.prefs['sunlight'], '1');

      // A fresh start (new provider container, same device store).
      final c2 = ProviderContainer(overrides: [arPackStoreProvider.overrideWithValue(store)]);
      addTearDown(c2.dispose);
      c2.read(arPrefsProvider);
      await c2.read(arPrefsProvider.notifier).ready;
      expect(c2.read(arPrefsProvider).sunlight, isTrue);
      // Other prefs are untouched by the new key.
      expect(c2.read(arPrefsProvider).demo, isFalse);

      await c2.read(arPrefsProvider.notifier).setSunlight(false);
      expect(store.prefs['sunlight'], '0');
      final c3 = ProviderContainer(overrides: [arPackStoreProvider.overrideWithValue(store)]);
      addTearDown(c3.dispose);
      c3.read(arPrefsProvider);
      await c3.read(arPrefsProvider.notifier).ready;
      expect(c3.read(arPrefsProvider).sunlight, isFalse);
    });

    test('copyWith keeps sunlight unless given', () {
      const s = ArPrefsState(sunlight: true);
      expect(s.copyWith(demo: true).sunlight, isTrue);
      expect(s.copyWith(sunlight: false).sunlight, isFalse);
    });
  });

  group('chrome widgets', () {
    Widget chrome() => const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ArGlassButton(key: Key('btn'), icon: ArIcons.menu, label: 'Menu', onTap: _noop),
          SizedBox(height: 8),
          ArGlassButton(key: Key('btn-active'), icon: ArIcons.measure, label: 'Measure', onTap: _noop, active: true),
          SizedBox(height: 8),
          ArGlassChip(key: Key('chip'), text: 'Corner 1 · column C-2', icon: ArIcons.board),
          SizedBox(height: 8),
          ArStatusBadge(key: Key('badge'), tone: ArBadgeTone.locked, text: 'Locked ±2 cm'),
          SizedBox(height: 8),
          ArOnCameraButton(key: Key('cam'), label: 'Other method', onPressed: _noop),
        ],
      ),
    );

    testWidgets('render the high-contrast variant when Sunlight is on, glass when off', (tester) async {
      final store = _PrefStore()..prefs['sunlight'] = '1';
      await tester.pumpWidget(ProviderScope(
        overrides: [arPackStoreProvider.overrideWithValue(store)],
        child: _app(chrome()),
      ));
      await tester.pump();
      // The saved flag arrives a frame later; let the badge's 280 ms
      // AnimatedContainer settle on it.
      await tester.pumpAndSettle();

      final bodySmall = Theme.of(tester.element(find.byKey(const Key('chip')))).textTheme.bodySmall!;

      // Button: opaque near-black, white 1.5 px outline, white icon.
      final btn = _materialOf(tester, find.byKey(const Key('btn')));
      expect(btn.color, FeArColors.sunlightSurface);
      final side = (btn.shape! as RoundedRectangleBorder).side;
      expect(side.color, Colors.white);
      expect(side.width, 1.5);
      final icon = tester.widget<Icon>(find.descendant(of: find.byKey(const Key('btn')), matching: find.byType(Icon)));
      expect(icon.color, Colors.white);
      expect(icon.size, greaterThan(21));

      // Active: solid brand blue with white.
      final active = _materialOf(tester, find.byKey(const Key('btn-active')));
      expect(active.color, FeColors.primary);
      final activeIcon = tester.widget<Icon>(find.descendant(of: find.byKey(const Key('btn-active')), matching: find.byType(Icon)));
      expect(activeIcon.color, Colors.white);

      // Chip: opaque, outlined, white text 1.5 sp larger and one step heavier.
      final chip = _decorationOf(tester, find.byKey(const Key('chip')));
      expect(chip.color, FeArColors.sunlightSurface);
      expect((chip.border! as Border).top.color, Colors.white);
      expect((chip.border! as Border).top.width, 1.5);
      final chipText = _textStyle(tester, 'Corner 1 · column C-2');
      expect(chipText.color, Colors.white);
      expect(chipText.fontSize, bodySmall.fontSize! + 1.5);
      expect(chipText.fontWeight, FontWeight.w700);

      // Badge: near-black with white text; the tone moves to the outline.
      final badge = _decorationOf(tester, find.byKey(const Key('badge')));
      expect(badge.color, FeArColors.sunlightSurface);
      expect((badge.border! as Border).top.color, FeArColors.drillSafe);
      expect(_textStyle(tester, 'Locked ±2 cm').color, Colors.white);

      // On-camera button: opaque with the outline.
      final cam = tester.widget<TextButton>(find.descendant(of: find.byKey(const Key('cam')), matching: find.byType(TextButton)));
      expect(cam.style!.backgroundColor!.resolve({}), FeArColors.sunlightSurface);
      expect((cam.style!.shape!.resolve({})! as RoundedRectangleBorder).side.color, Colors.white);

      // Turning it off switches every control back to glass, live.
      final container = ProviderScope.containerOf(tester.element(find.byKey(const Key('btn'))));
      await container.read(arPrefsProvider.notifier).setSunlight(false);
      await tester.pumpAndSettle();
      expect(_materialOf(tester, find.byKey(const Key('btn'))).color, FeArColors.glass);
      expect((_materialOf(tester, find.byKey(const Key('btn'))).shape! as RoundedRectangleBorder).side, BorderSide.none);
      expect(_materialOf(tester, find.byKey(const Key('btn-active'))).color, Colors.white);
      final glassChip = _decorationOf(tester, find.byKey(const Key('chip')));
      expect(glassChip.color, FeArColors.glass);
      expect(glassChip.border, isNull);
      expect(_textStyle(tester, 'Corner 1 · column C-2').color, FeArColors.onGlass);
      expect(_textStyle(tester, 'Corner 1 · column C-2').fontSize, bodySmall.fontSize);
      expect(_decorationOf(tester, find.byKey(const Key('badge'))).color, FeArColors.lockedBg);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without a host everything reads as glass', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.build(), home: Scaffold(body: chrome())));
      expect(_materialOf(tester, find.byKey(const Key('btn'))).color, FeArColors.glass);
    });
  });

  const sizes = {'phone 360x780': Size(360, 780), 'landscape 915x412': Size(915, 412)};

  for (final lang in ['en', 'ar']) {
    for (final e in sizes.entries) {
      testWidgets('Sunlight workspace, menu and chooser fit — ${e.key} ($lang)', (tester) async {
        FlutterLocalization.instance.translate(lang);
        tester.view.physicalSize = e.value * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        addTearDown(() => FlutterLocalization.instance.translate('en'));

        final store = _PrefStore()..prefs['sunlight'] = '1';
        final placed = session(caps: const ArCapabilities(supported: true, torch: true)).copyWith(
          fit: placedFit(),
          cameraAr: const Vec3(5, 1, 2),
          cameraForwardAr: const Vec3(0, 0, -1),
          target: pump,
        );
        final fake = FakeSession(placed, FakeGateway());
        final layout = arLayoutFor(e.value);
        final overrides = [
          arPackStoreProvider.overrideWithValue(store),
          arSessionProvider.overrideWith(() => fake),
          pendingMutationCountProvider.overrideWith((ref) async => 0),
          arSetupProvider.overrideWith(_IdleSetup.new),
          arInstallAllowedProvider.overrideWithValue(true),
        ];
        await tester.pumpWidget(ProviderScope(
          overrides: overrides,
          child: _app(
            LayoutBuilder(
              builder: (context, c) => ArWorkspace(
                tablet: layout == ArLayout.tablet,
                landscape: layout == ArLayout.landscapePhone,
                viewSize: c.biggest,
                onBack: () {},
              ),
            ),
            lang: lang,
          ),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        var err = tester.takeException();
        expect(err, isNull, reason: '$err');

        // The workspace chrome picked it up.
        final menuButton = find.byWidgetPredicate((w) => w is ArGlassButton && w.icon == ArIcons.menu);
        expect(menuButton, findsWidgets);
        expect(_materialOf(tester, menuButton.first).color, FeArColors.sunlightSurface);

        // Legend open + drill crosshair (both over the camera).
        final container = ProviderScope.containerOf(tester.element(find.byType(ArWorkspace)));
        final ws = container.read(arWorkspaceProvider.notifier);
        if (!container.read(arWorkspaceProvider).legendOpen) ws.toggleLegend();
        await tester.pump(const Duration(milliseconds: 300));
        err = tester.takeException();
        expect(err, isNull, reason: 'legend: $err');
        ws.toggleDrill();
        await tester.pump(const Duration(milliseconds: 300));
        err = tester.takeException();
        expect(err, isNull, reason: 'drill: $err');
        ws.toggleDrill();
        await tester.pump(const Duration(milliseconds: 300));

        // The menu, with its Sunlight row switched on; tapping it turns it off.
        ws.openPanel(ArPanel.menu);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        err = tester.takeException();
        expect(err, isNull, reason: 'menu: $err');
        final row = find.text('ar.menu.sunlight'.getString(tester.element(find.byType(ArWorkspace))));
        await tester.scrollUntilVisible(row, 80, scrollable: find.byType(Scrollable).last);
        await tester.tap(row);
        await tester.pump();
        expect(container.read(arPrefsProvider).sunlight, isFalse);
        await tester.pump();
        expect(store.prefs['sunlight'], '0');
        await tester.tap(row);
        await tester.pump();
        expect(container.read(arPrefsProvider).sunlight, isTrue);
        expect(store.prefs['sunlight'], '1');
      });

      testWidgets('Sunlight method chooser fits — ${e.key} ($lang)', (tester) async {
        FlutterLocalization.instance.translate(lang);
        tester.view.physicalSize = e.value * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        addTearDown(() => FlutterLocalization.instance.translate('en'));

        final store = _PrefStore();
        await tester.pumpWidget(ProviderScope(
          overrides: [
            arPackStoreProvider.overrideWithValue(store),
            arSessionProvider.overrideWith(() => FakeSession(session(), FakeGateway())),
            arSetupProvider.overrideWith(_IdleSetup.new),
          ],
          child: _app(const SingleChildScrollView(padding: EdgeInsets.all(12), child: ArMethodChooser(tablet: false)), lang: lang),
        ));
        await tester.pump();
        var err = tester.takeException();
        expect(err, isNull, reason: '$err');

        final sun = find.byWidgetPredicate((w) => w is Icon && w.icon == ArIcons.sunlight);
        expect(sun, findsOneWidget);
        await tester.tap(sun);
        await tester.pump();
        final container = ProviderScope.containerOf(tester.element(find.byType(ArMethodChooser)));
        expect(container.read(arPrefsProvider).sunlight, isTrue);
        expect(store.prefs['sunlight'], '1');
        // Let the tiles' staggered entrance finish.
        await tester.pump(const Duration(seconds: 1));
        err = tester.takeException();
        expect(err, isNull, reason: '$err');
      });
    }
  }
}

void _noop() {}
