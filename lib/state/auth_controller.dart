import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_exception.dart';
import '../core/push/push_service.dart';
import '../core/storage/session_store.dart';
import 'providers.dart';

class AuthState {
  const AuthState({
    this.session,
    this.permissions = const Permissions(),
    this.isBusy = false,
    this.error,
    this.sessionExpired = false,
  });

  final Session? session;
  final Permissions permissions;
  final bool isBusy;
  final String? error;
  final bool sessionExpired;

  bool get isAuthenticated => session != null && session!.userId.isNotEmpty;

  AuthState copyWith({
    Session? session,
    Permissions? permissions,
    bool? isBusy,
    String? error,
    bool? sessionExpired,
    bool clearSession = false,
    bool clearError = false,
  }) => AuthState(
    session: clearSession ? null : (session ?? this.session),
    permissions: permissions ?? this.permissions,
    isBusy: isBusy ?? this.isBusy,
    error: clearError ? null : (error ?? this.error),
    sessionExpired: sessionExpired ?? this.sessionExpired,
  );
}

/// Signed in until the technician signs out (owner, 2026-10-06). There is no
/// client-side session clock any more: the access token is short and
/// [ApiClient] renews it silently (`SessionRefresher`). [onSessionExpired]
/// fires only when the server *refuses* a renewal — revoked on another
/// device, password changed, account removed — and only then does the
/// sign-in screen appear. The offline queue survives that (NFR-1, [logout]).
class AuthController extends Notifier<AuthState> {
  StreamSubscription<void>? _expirySub;

  @override
  AuthState build() {
    final store = ref.read(sessionStoreProvider);
    _expirySub ??= ref.read(apiClientProvider).onSessionExpired.listen((_) {
      _handleSessionExpired();
    });
    ref.onDispose(() {
      _expirySub?.cancel();
    });

    final session = store.readSession();
    if (session != null) {
      // Restored session: attach push and send the token (it may have
      // rotated since the last cold start). Resume re-sends it too, from
      // TechnicianShell.didChangeAppLifecycleState.
      ref.read(pushServiceProvider).init();
    }

    return AuthState(session: session, permissions: store.readPermissions());
  }

  Future<void> _handleSessionExpired() async {
    // Several requests can be refused at once; end the session once.
    if (!state.isAuthenticated) return;
    await logout(revoke: false);
    state = state.copyWith(sessionExpired: true, clearSession: true);
  }

  Future<bool> login(String username, String password) async {
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      final repo = ref.read(authRepositoryProvider);
      final result = await repo.login(username: username, password: password);

      final secure = ref.read(secureStoreProvider);
      await secure.writeToken(result.token);
      if (result.refreshToken != null) {
        await secure.writeRefreshToken(result.refreshToken);
        await secure.clearLegacyLogin();
      } else {
        // An older server: no refresh token. Keep the sign-in in the
        // keystore so the app can sign itself back in when the 24h token
        // runs out (SessionRefresher's fallback). Removed on sign-out and
        // as soon as the server issues refresh tokens.
        await secure.writeRefreshToken(null);
        await secure.writeLegacyLogin(username, password);
      }
      final store = ref.read(sessionStoreProvider);
      await store.writeSession(result.session);

      var permissions = const Permissions();
      try {
        permissions = await repo.fetchPermissions();
        await store.writePermissions(permissions);
      } on ApiFailure {
        // Config is advisory; a failure here must not block sign-in.
      }

      state = AuthState(session: result.session, permissions: permissions);
      ref.read(syncClientProvider).startAutoFlush();
      ref.read(pushServiceProvider).init();
      return true;
    } on ApiFailure catch (e) {
      state = state.copyWith(isBusy: false, error: e.message);
      return false;
    }
  }

  /// [revoke] tells the server to forget this phone's refresh token (a manual
  /// sign-out). False when the server already refused it.
  Future<void> logout({bool revoke = true}) async {
    if (revoke) await ref.read(apiClientProvider).revokeSession();
    // Deliberately not unregistering the device token here — phones are
    // personally issued, one per technician, so push should keep reaching
    // this device (a job assigned overnight, say) even while signed out.
    await ref.read(secureStoreProvider).clear();
    await ref.read(sessionStoreProvider).clear();
    // NFR-1: never destroy unsent work. A queue that isn't empty stays on
    // disk (still encrypted at rest) so the next sign-in on this device can
    // finish draining it — wiping here would silently lose whatever a
    // technician captured underground and hadn't synced yet.
    // P-002: an empty queue is not "nothing unsent" — a snag the server
    // refused stays on the phone as local_only without a queued write, and
    // so do capture drafts and the conflict log. Only server copies go.
    if (await ref.read(offlineDbProvider).countMutations() == 0) {
      await ref.read(offlineDbProvider).wipeForSignOut();
    }
    state = const AuthState();
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
