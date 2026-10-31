import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_exception.dart';
import '../core/push/push_service.dart';
import '../domain/admin_user.dart';
import 'providers.dart';

class AuthState {
  const AuthState({
    this.user,
    this.isBusy = false,
    this.error,
    this.sessionExpired = false,
  });

  final AdminUser? user;
  final bool isBusy;
  final String? error;
  final bool sessionExpired;

  bool get isAuthenticated => user != null && user!.id.isNotEmpty;

  AuthState copyWith({
    AdminUser? user,
    bool? isBusy,
    String? error,
    bool? sessionExpired,
    bool clearUser = false,
    bool clearError = false,
  }) =>
      AuthState(
        user: clearUser ? null : (user ?? this.user),
        isBusy: isBusy ?? this.isBusy,
        error: clearError ? null : (error ?? this.error),
        sessionExpired: sessionExpired ?? this.sessionExpired,
      );
}

/// Restores the saved user on cold start; [ApiClient.onSessionExpired]
/// (server refused the token) sends the user back to sign-in.
class AuthController extends Notifier<AuthState> {
  StreamSubscription<void>? _expirySub;

  @override
  AuthState build() {
    _expirySub ??= ref.read(apiClientProvider).onSessionExpired.listen((_) {
      _handleSessionExpired();
    });
    ref.onDispose(() => _expirySub?.cancel());

    return AuthState(user: ref.read(sessionStoreProvider).readUser());
  }

  Future<void> login(String identifier, String password) async {
    state = state.copyWith(isBusy: true, clearError: true, sessionExpired: false);
    try {
      final result = await ref
          .read(authRepositoryProvider)
          .login(identifier, password);
      final secure = ref.read(secureStoreProvider);
      await secure.writeToken(result.accessToken);
      await secure.writeRefreshToken(result.refreshToken);
      await ref.read(sessionStoreProvider).writeUser(result.user);
      state = AuthState(user: result.user);
    } on ApiFailure catch (e) {
      state = state.copyWith(isBusy: false, error: e.message);
    }
  }

  /// Manual sign-out: revoke the session on the server (best effort), then
  /// forget everything on the phone.
  Future<void> logout({bool revoke = true}) async {
    final secure = ref.read(secureStoreProvider);
    final refreshToken = await secure.readRefreshToken();
    // While the session still works: this phone stops getting this user's pushes.
    if (revoke) await ref.read(pushServiceProvider).unregister();
    if (revoke && refreshToken != null) await ref.read(authRepositoryProvider).logout(refreshToken);
    await secure.clear();
    await ref.read(sessionStoreProvider).clear();
    state = const AuthState();
  }

  /// The server refused to renew the session (revoked on another device,
  /// password changed, account removed). Nothing left to revoke.
  Future<void> _handleSessionExpired() async {
    // Several requests can be refused at once; end the session once.
    if (!state.isAuthenticated) return;
    await logout(revoke: false);
    state = state.copyWith(sessionExpired: true);
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
