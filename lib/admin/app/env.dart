/// Build-time configuration. Override per flavour:
/// flutter run --dart-define=API_BASE_URL=https://dev.api.eco.thefusionapps.com
abstract final class Env {
  /// The Express API, no `/api` suffix.
  static const defaultApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://dev.api.eco.thefusionapps.com',
  );

  /// The Next.js client. Later used for WebView fallbacks (3D, report PDF).
  static const webBaseUrl = String.fromEnvironment(
    'WEB_BASE_URL',
    defaultValue: 'https://dev.eco.thefusionapps.com',
  );

  static const brandName = String.fromEnvironment(
    'BRAND_NAME',
    defaultValue: 'Fusion Eco',
  );

  static const connectTimeout = Duration(seconds: 15);
  static const receiveTimeout = Duration(seconds: 30);
  static const uploadTimeout = Duration(seconds: 90);
}
