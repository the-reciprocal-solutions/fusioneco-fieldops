import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/bim_viewer/bim_view_engine.dart';
import 'package:technician_portal/core/bim_viewer/web_view_errors.dart';
import 'package:technician_portal/features/bim_viewer/bim_viewer_screen.dart';
import 'package:technician_portal/state/ar_catalog_controller.dart' show arGatewayProvider;
import 'package:technician_portal/state/bim_viewer_controller.dart';
import 'package:technician_portal/state/bim_viewer_pack.dart';
import 'package:technician_portal/theme/app_theme.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'bim_viewer_fakes.dart';

/// "Verify in 3D shows a broken page, and none of the actions work"
/// (owner, iPhone, 2026-10-06). Every way the viewer can fail must end in a
/// plain-words state with a next step — never a blank page or an endless
/// spinner — and a 3D page that comes back must get its floor again.
Map<String, dynamic> _strings(String lang) {
  final all = jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in all.entries)
      if (e.key.startsWith('bim_viewer.') || e.key.startsWith('common.') || e.key.startsWith('ar.')) e.key: e.value,
  };
}

final _en = _strings('en');

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final l = FlutterLocalization.instance;
    await l.ensureInitialized();
    l.init(
      mapLocales: [MapLocale('en', _en), MapLocale('ar', _strings('ar'))],
      initLanguageCode: 'en',
    );
  });

  group('controller', () {
    late FakeViewerGateway gateway;
    late ProviderContainer container;

    BimViewerController ctl() => container.read(bimViewerProvider.notifier);
    BimViewerState st() => container.read(bimViewerProvider);
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUp(() {
      gateway = FakeViewerGateway();
      container = ProviderContainer(overrides: [
        arGatewayProvider.overrideWithValue(gateway),
        bimViewerPackProvider.overrideWithValue(FakeViewerPack(gateway)),
      ]);
      container.listen(bimViewerProvider, (_, _) {});
    });
    tearDown(() => container.dispose());

    test('a floor with no model and no plan is "no model", not an empty canvas', () async {
      gateway.empty = true;
      await ctl().open(floorId: 'flr-3');
      expect(st().noModel, isTrue);
      expect(st().errorKey, isNull);
    });

    test('tiles not on the phone yet is NOT "no model": walls come from the plan meanwhile', () async {
      await ctl().open(floorId: 'flr-3');
      expect(st().localPaths, isEmpty);
      expect(st().planHasGeometry, isTrue);
      expect(st().noModel, isFalse);
      expect(st().usesMassing, isTrue);
    });

    test('a reloaded page gets the whole floor again', () async {
      final engine = FakeBimViewEngine();
      ctl().attach(engine);
      await engine.start();
      await ctl().open(floorId: 'flr-3');
      await settle();
      expect(engine.named('setFloor'), hasLength(1));

      // Same page saying ready twice (the hello handshake): no second push.
      engine.emit(const BimReady(version: 1, webgl2: true));
      await settle();
      expect(engine.named('setFloor'), hasLength(1));

      // iOS killed the page; a fresh one comes up.
      engine.emit(const BimViewerError(code: 'RELOADING'));
      await settle();
      expect(st().engineReady, isFalse);
      engine.emit(const BimReady(version: 1, webgl2: true));
      await settle();
      expect(engine.named('setFloor'), hasLength(2));
      expect(engine.named('setPlan'), hasLength(2));
    });

    test('a page that never says ready ends in plan-only, and Retry brings the layout back', () async {
      final first = FakeBimViewEngine(autoReady: false);
      ctl().attach(first);
      await first.start();
      await ctl().open(floorId: 'flr-3');
      ctl().setLayout(BimViewLayout.split);
      first.emit(const BimViewerError(code: 'NOT_READY'));
      await settle();
      expect(st().model3dAvailable, isFalse);
      expect(st().layout, BimViewLayout.plan);

      final second = FakeBimViewEngine();
      ctl().attach(second);
      expect(st().model3dAvailable, isTrue);
      expect(st().layout, BimViewLayout.split, reason: 'the user\'s layout is back while 3D starts');
      await second.start();
      await settle();
      expect(st().engineReady, isTrue);
      expect(second.named('setFloor'), hasLength(1), reason: 'the new page gets the floor');
    });

    test('NOT_READY is fatal, RELOADING is not', () {
      expect(const BimViewerError(code: 'NOT_READY').fatal, isTrue);
      expect(const BimViewerError(code: 'RELOADING').fatal, isFalse);
      expect(const BimViewerError(code: 'RELOADING').reloading, isTrue);
    });
  });

  group('load errors read as plain words', () {
    test('every arErrorKey maps to a title and subtitle that exist in both languages', () {
      final ar = _strings('ar');
      for (final key in ['ar.error.offline', 'ar.error.no_build', 'ar.error.no_access', 'ar.error.not_found', 'ar.error.generic', 'x']) {
        final (_, title, subtitle) = bimLoadErrorCopy(key);
        expect(_en.containsKey(title) && ar.containsKey(title), isTrue, reason: title);
        expect(_en.containsKey(subtitle) && ar.containsKey(subtitle), isTrue, reason: subtitle);
      }
      expect(bimLoadErrorCopy('ar.error.offline').$2, 'bim_viewer.needs_signal_title');
      expect(bimLoadErrorCopy('ar.error.no_build').$2, 'bim_viewer.no_model_title');
    });
  });

  group('WebView errors (iOS)', () {
    WebResourceError err(int code, {bool? main = true, WebResourceErrorType? type}) =>
        WebResourceError(errorCode: code, description: 'x', isForMainFrame: main, errorType: type);

    test('a superseded load (-999) and a refused navigation (102) are not failures', () {
      expect(classifyWebViewError(err(-999)), WebViewErrorKind.benign);
      expect(classifyWebViewError(err(102)), WebViewErrorKind.benign);
    });
    test('a sub-resource failure is not the page failing', () {
      expect(classifyWebViewError(err(-1004, main: false)), WebViewErrorKind.benign);
    });
    test('a killed web process is a reload, a refused connection a failure', () {
      expect(classifyWebViewError(err(2, type: WebResourceErrorType.webContentProcessTerminated)), WebViewErrorKind.processGone);
      expect(classifyWebViewError(err(-1004)), WebViewErrorKind.failed);
      expect(classifyWebViewError(err(-1004, main: null)), WebViewErrorKind.failed);
    });
  });

  group('screen', () {
    Future<List<FakeBimViewEngine>> pump(WidgetTester tester, FakeViewerGateway gateway, {bool autoReady = true}) async {
      FlutterLocalization.instance.translate('en');
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final engines = <FakeBimViewEngine>[];
      await tester.pumpWidget(ProviderScope(
        overrides: [
          arGatewayProvider.overrideWithValue(gateway),
          bimViewerPackProvider.overrideWithValue(FakeViewerPack(gateway)),
          bimViewEngineFactoryProvider.overrideWithValue(() {
            final e = FakeBimViewEngine(autoReady: autoReady || engines.isNotEmpty);
            engines.add(e);
            return e;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.build(),
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
          home: const BimViewerScreen(floorId: 'flr-3'),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return engines;
    }

    testWidgets('no model for the floor: says so, with Retry — not a blank page', (tester) async {
      final gateway = FakeViewerGateway()..empty = true;
      await pump(tester, gateway);
      expect(find.text(_en['bim_viewer.no_model_title'] as String), findsOneWidget);
      expect(find.text(_en['common.retry'] as String), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('offline with nothing on the phone: "Needs signal once" + Retry that works', (tester) async {
      final gateway = FakeViewerGateway()..floorError = true;
      await pump(tester, gateway);
      expect(find.text(_en['bim_viewer.needs_signal_title'] as String), findsOneWidget);
      gateway.floorError = false;
      await tester.tap(find.text(_en['common.retry'] as String));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(_en['bim_viewer.needs_signal_title'] as String), findsNothing);
      expect(find.byKey(const ValueKey('fake-bim-view')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no published build (409): the no-model words, never the raw error', (tester) async {
      final gateway = FakeViewerGateway()
        ..floorError = true
        ..floorErrorText = 'ArApiError(409 NO_PUBLISHED_BUILD)';
      await pump(tester, gateway);
      expect(find.text(_en['bim_viewer.no_model_title'] as String), findsOneWidget);
      expect(find.textContaining('409'), findsNothing);
    });

    testWidgets('3D never comes up: plan-only banner, "Try 3D again" starts a fresh engine', (tester) async {
      final engines = await pump(tester, FakeViewerGateway(), autoReady: false);
      engines.single.emit(const BimViewerError(code: 'NOT_READY'));
      await tester.pump();
      expect(find.text(_en['bim_viewer.no_3d_title'] as String), findsOneWidget);
      await tester.tap(find.text(_en['bim_viewer.retry_3d'] as String));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(engines, hasLength(2));
      expect(engines.first.disposed, isTrue);
      expect(engines.last.named('setFloor'), hasLength(1), reason: 'the new page gets the floor');
      expect(find.text(_en['bim_viewer.no_3d_title'] as String), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a picked element linked to an asset offers Open, Verify and Flag', (tester) async {
      final engines = await pump(tester, FakeViewerGateway());
      engines.single.emit(const BimPick(featureId: 42, buildId: 'b1', layer: 'mep'));
      await tester.pump();
      expect(find.text('CHW pump P-01'), findsOneWidget);
      expect(find.text(_en['bim_viewer.open_asset'] as String), findsOneWidget);
      expect(find.text(_en['bim_viewer.verify'] as String), findsOneWidget);
      expect(find.text(_en['bim_viewer.flag'] as String), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
