import 'package:flutter_localization/flutter_localization.dart';
// ignore: implementation_imports
import 'package:flutter_localization/src/localization/flutter_localization_translator.dart';

/// Words that reach the app in English from outside the i18n files: the
/// server catalog's module, group and page names, and status words stored in
/// the database. English shows them exactly as sent; other languages look them
/// up, and a word with no entry stays as it came rather than showing a key.
///
/// It needs no BuildContext because these are read from models and from specs
/// built outside a widget. A widget that shows them directly must call
/// `Localizations.localeOf(context)` so that it redraws on a language switch.
String serverText(String key, String raw) {
  final lang = FlutterLocalization.instance.currentLocale?.languageCode;
  if (lang == null || lang == 'en') return raw;
  final v = FlutterLocalizationTranslator.instance.getStringOrKey(key);
  return v == key ? raw : v;
}

/// `In Progress` / `in-progress` / `in_progress` → `in_progress`.
String wordSlug(String raw) => raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

/// A catalog group name ("Facility Management") in the user's language.
String catalogGroup(String raw) => serverText('catalog.group.${wordSlug(raw)}', raw);

/// A page kept on the web, as listed under More.
String catalogWebOnly(String raw) => serverText('catalog.web.${wordSlug(raw)}', raw);

/// A status, priority, condition or role word from the database.
String statusWord(String raw) => serverText('chip.${wordSlug(raw)}', raw);
