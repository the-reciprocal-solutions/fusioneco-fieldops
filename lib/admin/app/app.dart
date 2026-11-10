import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/locale_controller.dart';
import '../theme/app_theme.dart';
import 'env.dart';
import 'locale_config.dart';
import 'router.dart';

class AdminApp extends ConsumerStatefulWidget {
  const AdminApp({super.key});

  @override
  ConsumerState<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends ConsumerState<AdminApp> {
  @override
  void initState() {
    super.initState();
    // ensureInitialized() in main() already restored any saved language.
    // Only en/ar exist, so anything else falls back to English.
    final restored = FlutterLocalization.instance.currentLocale?.languageCode;
    FlutterLocalization.instance.init(
      mapLocales: const [],
      jsonLocales: AppLocales.supported,
      initLanguageCode:
          restored == AppLocales.arabic ? AppLocales.arabic : AppLocales.english,
      source: LocalizationSource.jsonAsset,
    );
  }

  @override
  Widget build(BuildContext context) {
    final languageCode = ref.watch(localeControllerProvider);
    final localization = FlutterLocalization.instance;

    return MaterialApp.router(
      title: '${Env.brandName} Admin',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(rtl: AppLocales.isRtl(languageCode)),
      supportedLocales: localization.supportedLocales,
      localizationsDelegates: localization.localizationsDelegates,
      locale: AppLocales.localeFor(languageCode),
      routerConfig: ref.watch(routerProvider),
      // Pinned explicitly, as in technician_portal: the localization package
      // never demonstrates RTL, so don't trust the derived default.
      builder: (context, child) => Directionality(
        textDirection: AppLocales.isRtl(languageCode)
            ? TextDirection.rtl
            : TextDirection.ltr,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
