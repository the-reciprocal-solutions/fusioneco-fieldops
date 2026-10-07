import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/locale_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/location_checkin_gate.dart';
import '../widgets/keyboard_dismiss.dart';
import 'locale_config.dart';
import 'router.dart';

class TechnicianApp extends ConsumerStatefulWidget {
  const TechnicianApp({super.key});

  @override
  ConsumerState<TechnicianApp> createState() => _TechnicianAppState();
}

class _TechnicianAppState extends ConsumerState<TechnicianApp> {
  @override
  void initState() {
    super.initState();
    // `ensureInitialized()` (called in main() before runApp) already restored
    // any previously-saved locale into `currentLocale`. Only "en"/"ar" are
    // wired up right now, so anything else (a fresh install picking up the
    // device locale, or a stale value) falls back to English — the app's
    // documented default — rather than silently trying to render an
    // unsupported language.
    final restored = FlutterLocalization.instance.currentLocale?.languageCode;
    final initLanguageCode = restored == AppLocales.arabic
        ? AppLocales.arabic
        : AppLocales.english;

    FlutterLocalization.instance.init(
      mapLocales: const [],
      jsonLocales: AppLocales.supported,
      initLanguageCode: initLanguageCode,
      source: LocalizationSource.jsonAsset,
    );
    // No `onTranslatedLanguage` callback wired here anymore. The active
    // language now lives in [localeControllerProvider]
    // (state/locale_controller.dart) — the single source of truth every
    // screen watches — and `build()` below reacts to *that*, not to a
    // one-shot global callback the package calls after `translate()`. See
    // that file's doc comment for why the old callback-based wiring let the
    // language silently revert to English after switching bottom-nav tabs.
  }

  @override
  Widget build(BuildContext context) {
    final languageCode = ref.watch(localeControllerProvider);
    final textDirection = AppLocales.isRtl(languageCode)
        ? TextDirection.rtl
        : TextDirection.ltr;
    final localization = FlutterLocalization.instance;

    return MaterialApp.router(
      title: 'FusionEco FieldOps',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      supportedLocales: localization.supportedLocales,
      localizationsDelegates: localization.localizationsDelegates,
      // Built from the Riverpod-owned `languageCode` (not re-read off the
      // FlutterLocalization singleton) so this can never disagree with what
      // [LocaleController] most recently set — see locale_controller.dart.
      locale: AppLocales.localeFor(languageCode),
      routerConfig: ref.watch(routerProvider),
      // Dragging any list closes the keyboard (forms, checklists, chat);
      // tapping blank space closes it too — KeyboardDismissOnTapOutside.
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      ),
      // Belt-and-suspenders: MaterialApp/WidgetsApp derives Directionality
      // from the resolved locale automatically once GlobalWidgetsLocalizations
      // is in localizationsDelegates (it is, via the package) and `locale` is
      // set (it is, above) — but this package's own README/example never
      // demonstrates RTL, so we pin it explicitly here rather than trust an
      // unconfirmed default.
      builder: (context, child) => Directionality(
        textDirection: textDirection,
        child: KeyboardDismissOnTapOutside(
          child: LocationCheckInGate(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}
