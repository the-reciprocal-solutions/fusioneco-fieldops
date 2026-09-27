import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/ar/ar_engine.dart' show ArCapabilities;
import 'package:technician_portal/core/ar/reanchor_rule.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/features/ar/ar_coach_overlay.dart';
import 'package:technician_portal/features/ar/ar_ui.dart';
import 'package:technician_portal/features/ar/workspace/ar_workspace.dart';
import 'package:technician_portal/state/ar_permissions.dart';
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_setup_controller.dart';
import 'package:technician_portal/state/ar_workspace_controller.dart';
import 'package:technician_portal/state/providers.dart';
import 'package:technician_portal/theme/app_theme.dart';

import 'ar_workspace_fakes.dart';

/// Render smoke test of the AR workspace in every layout — portrait phone,
/// a phone on its side (two sizes) and a tablet — in English and Arabic:
/// no overflow, no exception (the landscape-phone layout is new). Strings
/// are the real ones plus the pending agent files, so a missing key shows.
Map<String, dynamic> _strings(String lang) {
  final all = <String, dynamic>{
    ...jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>,
  };
  final pending = Directory('assets/i18n/pending');
  if (pending.existsSync()) {
    for (final f in pending.listSync().whereType<File>().where((f) => f.path.endsWith('.$lang.json'))) {
      all.addAll(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    }
  }
  return all;
}

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

  const sizes = {
    'phone 360x780': Size(360, 780),
    'landscape 915x412': Size(915, 412),
    'landscape 780x360': Size(780, 360),
    'tablet 1180x820': Size(1180, 820),
  };

  for (final lang in ['en', 'ar']) {
    for (final e in sizes.entries) {
      testWidgets('workspace renders without overflow — ${e.key} ($lang)', (tester) async {
        FlutterLocalization.instance.translate(lang);
        tester.view.physicalSize = e.value * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);

        final placed = session(caps: const ArCapabilities(supported: true, torch: true)).copyWith(
          fit: placedFit(),
          cameraAr: const Vec3(5, 1, 2),
          cameraForwardAr: const Vec3(0, 0, -1),
          target: pump,
        );
        final fake = FakeSession(placed, FakeGateway());
        final layout = arLayoutFor(e.value);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            arSessionProvider.overrideWith(() => fake),
            pendingMutationCountProvider.overrideWith((ref) async => 0),
            // Setup (another workstream's controller) stays idle here.
            arSetupProvider.overrideWith(_IdleSetup.new),
            // No signed-in session in a widget test.
            arInstallAllowedProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            theme: AppTheme.build(),
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
            locale: Locale(lang),
            home: Scaffold(
              body: LayoutBuilder(
                builder: (context, c) => Stack(
                  children: [
                    Positioned.fill(
                      child: ArWorkspace(
                        tablet: layout == ArLayout.tablet,
                        landscape: layout == ArLayout.landscapePhone,
                        viewSize: c.biggest,
                        onBack: () {},
                      ),
                    ),
                    const Positioned.fill(child: ArCoachOverlay(startAtWork: true)),
                  ],
                ),
              ),
            ),
          ),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        var err = tester.takeException();
        expect(err, isNull, reason: '$err');
        expect(find.byType(ArWorkspace), findsOneWidget);

        // Drifting prompt + the Layers panel with the section slider open.
        final container = ProviderScope.containerOf(tester.element(find.byType(ArWorkspace)));
        fake.put(fake.state.copyWith(recheck: const ArRecheckPrompt(seq: 1, reason: ReanchorReason.walkedFar, walkedM: 8)));
        final ws = container.read(arWorkspaceProvider.notifier);
        ws.setSectionHeight(1.5);
        ws.toggleXray();
        ws.openPanel(ArPanel.layers);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        err = tester.takeException();
        expect(err, isNull, reason: '$err');
        expect(find.byType(Slider), findsWidgets);
      });
    }
  }
}

class _IdleSetup extends ArSetupController {
  @override
  ArSetupState build() => const ArSetupState();
}
