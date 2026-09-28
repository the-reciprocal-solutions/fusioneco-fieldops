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

class AuthController extends Notifier<AuthState> {
  StreamSubscription<void>? _expirySub;
  Timer? _sessionExpiryTimer;

  @override
  AuthState build() {
    final store = ref.read(sessionStoreProvider);
    _expirySub ??= ref.read(apiClientProvider).onSessionExpired.listen((_) {
      _handleSessionExpired();
    });
    ref.onDispose(() {
      _expirySub?.cancel();
      _sessionExpiryTimer?.cancel();
    });

    final session = store.readSession();
    if (session != null) {
      _scheduleExpirationTimer(session);
      // Re-register the device token on app resume — it may have rotated
      // since the last cold start, and FCM has no other way to tell us.
      ref.read(pushServiceProvider).init();
    }

    return AuthState(session: session, permissions: store.readPermissions());
  }

  void _scheduleExpirationTimer(Session session) {
    _sessionExpiryTimer?.cancel();
    final remaining = session.remainingValidity;
    if (remaining <= Duration.zero) {
      _handleSessionExpired();
    } else {
      _sessionExpiryTimer = Timer(remaining, () {
        _handleSessionExpired();
      });
    }
  }

  Future<void> _handleSessionExpired() async {
    await logout();
    state = state.copyWith(sessionExpired: true, clearSession: true);
  }

  Future<bool> login(String username, String password) async {
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      final repo = ref.read(authRepositoryProvider);
      final result = await repo.login(username: username, password: password);

      await ref.read(secureStoreProvider).writeToken(result.token);
      final store = ref.read(sessionStoreProvider);
      await store.writeSession(result.session);
      _scheduleExpirationTimer(result.session);

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

  Future<void> logout() async {
    _sessionExpiryTimer?.cancel();
    // Deliberately not unregistering the device token here — phones are
    // personally issued, one per technician, so push should keep reaching
    // this device (a job assigned overnight, say) even while signed out or
    // between the 24h session expiring and the next login.
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
