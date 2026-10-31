import '../core/network/api_client.dart';
import '../core/network/api_exception.dart';
import '../domain/admin_user.dart';

class AuthRepository {
  AuthRepository(this._api);

  final ApiClient _api;

  /// `POST /api/auth/mobile/login` (FE-mobile.md 0.2): a short access token
  /// plus a rotating refresh token, so the user stays signed in until they
  /// sign out. The server takes either `username` or `email`; pick by `@`.
  Future<({String accessToken, String refreshToken, AdminUser user})> login(
    String identifier,
    String password,
  ) async {
    final id = identifier.trim();
    final data = await _api.post(
      '/api/auth/mobile/login',
      body: {
        if (id.contains('@')) 'email': id else 'username': id,
        'password': password,
      },
    );
    if (data is! Map ||
        data['accessToken'] is! String ||
        data['refreshToken'] is! String ||
        data['user'] is! Map<String, dynamic>) {
      throw const UnknownFailure('Unexpected login response');
    }
    return (
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
      user: AdminUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  /// Revokes the session on the server. Best effort: sign-out never waits on it.
  Future<void> logout(String refreshToken) async {
    try {
      await _api.post('/api/auth/mobile/logout', body: {'refreshToken': refreshToken});
    } on ApiFailure {
      // Offline or already gone; the phone forgets the tokens either way.
    }
  }
}
