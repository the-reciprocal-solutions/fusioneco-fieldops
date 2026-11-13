import 'package:flutter/widgets.dart';
import 'package:flutter_localization/flutter_localization.dart';

/// Central registry of the app's supported languages. Same shape as
/// technician_portal: add `assets/i18n/<code>.json` + one [JsonLocale] entry.
abstract final class AppLocales {
  static const english = 'en';
  static const arabic = 'ar';

  /// Languages that read right-to-left. Anything not listed is LTR.
  static const rtlLanguageCodes = <String>{arabic};

  static const supported = <JsonLocale>[
    JsonLocale(english, 'assets/i18n/en.json'),
    JsonLocale(arabic, 'assets/i18n/ar.json'),
  ];

  /// Display names for the language switcher, keyed by language code.
  static const languageNames = <String, String>{
    english: 'English',
    arabic: 'العربية',
  };

  static bool isRtl(String? languageCode) =>
      languageCode != null && rtlLanguageCodes.contains(languageCode);

  static Locale localeFor(String languageCode) => Locale(languageCode);
}
