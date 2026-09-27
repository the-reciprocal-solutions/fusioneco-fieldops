import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ar_prefs_controller.dart';
import 'auth_controller.dart';

/// May this account run board installs and turn spare boards into markers
/// (PENDING P-007)? The server's `isArInstall` flag (opt-in, default off,
/// `GET /api/auth/config`). Demo mode always may: its sample building is
/// on the phone only and writes nothing to the server.
///
/// Gates: the dashboard's Install tile, the install list and guide (a push
/// link can still open them: they then explain instead of listing), the
/// marker screen's "register this spare", the spare screen, and the
/// workspace's "Save a board here". Viewing AR is `isArView`
/// (`ar_availability.dart`).
final arInstallAllowedProvider = Provider<bool>((ref) {
  final flag = ref.watch(authControllerProvider.select((s) => s.permissions.isArInstall));
  final demo = ref.watch(arPrefsProvider.select((p) => p.demo));
  return flag || demo;
});
