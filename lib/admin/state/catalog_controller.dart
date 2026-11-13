import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/mobile_catalog.dart';
import 'auth_controller.dart';
import 'locale_controller.dart';
import 'providers.dart';

/// The signed-in user's catalog. Null while signed out.
///
/// Refetched (FE-mobile.md Phase 1) on app resume (AdminShell), on
/// pull-to-refresh, and — once Phase 0.3 lands — on the socket's
/// `config:changed`. Callers refetch with `ref.invalidate(catalogProvider)`.
final catalogProvider = FutureProvider<MobileBootstrap?>((ref) async {
  // Re-run when the user changes (sign in / sign out), not on busy/error ticks.
  final userId = ref.watch(authControllerProvider.select((s) => s.user?.id));
  if (userId == null) return null;

  final boot = await ref.read(bootstrapRepositoryProvider).fetch();
  // The web keeps the language in the user's config; follow it when it
  // changes there (or on the first fetch), not on every refetch — a choice
  // made on the phone that didn't reach the server must not be undone.
  final seen = ref.read(serverLanguageProvider);
  if (seen != boot.language) {
    ref.read(serverLanguageProvider.notifier).state = boot.language;
    ref.read(localeControllerProvider.notifier).set(boot.language);
  }
  return boot;
});

/// The loaded catalog, or null while loading / failed / signed out.
final loadedCatalogProvider = Provider<MobileBootstrap?>(
  (ref) => ref.watch(catalogProvider).valueOrNull,
);
