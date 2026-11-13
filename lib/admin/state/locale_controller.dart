import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/locale_config.dart';
import 'providers.dart';

/// The single source of truth for the app's active language.
///
/// Every read AND write goes through this [Notifier] — it is the only caller
/// of [FlutterLocalization.translate]. technician_portal learned the hard way
/// (2026-09-09) that reading the package's singleton directly lets the
/// language revert to English after switching bottom-nav tabs.
class LocaleController extends Notifier<String> {
  @override
  String build() {
    final restored = FlutterLocalization.instance.currentLocale?.languageCode;
    return restored == AppLocales.arabic
        ? AppLocales.arabic
        : AppLocales.english;
  }

  void set(String languageCode) {
    if (languageCode == state) return;
    FlutterLocalization.instance.translate(languageCode);
    state = languageCode;
  }

  /// The user picked a language in the app: switch, and keep it in their
  /// config (`POST /api/auth/config {language}`, as the web's switcher does),
  /// so the web and the next catalog fetch agree (PENDING P-001).
  Future<void> choose(String languageCode) async {
    set(languageCode);
    try {
      await ref.read(apiClientProvider).post('/api/auth/config', body: {'language': languageCode});
    } catch (_) {
      // Offline: the choice still stands on this phone (the catalog only
      // follows the server when the server's value itself changes).
    }
  }
}

/// The language the server's config had at the last catalog fetch. The
/// catalog follows the server only when this changes (switched on the web),
/// never just because it differs from the phone.
final serverLanguageProvider = StateProvider<String?>((ref) => null);

final localeControllerProvider = NotifierProvider<LocaleController, String>(
  LocaleController.new,
);
