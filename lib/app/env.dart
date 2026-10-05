/// Build-time configuration. Override per flavour:
/// flutter run --dart-define=API_BASE_URL=https://dev.api.eco.thefusionapps.com
abstract final class Env {
  // static const defaultApiBaseUrl = String.fromEnvironment(
  //   'API_BASE_URL',
  //   defaultValue: 'http://192.168.0.155:5002',
  // );
  static const defaultApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://dev.api.eco.thefusionapps.com',
  );

  /// The Next.js client, not the API. Only two things need it: deciding
  /// whether a scanned link is one of ours, and loading `/public/*` pages in
  /// the built-in browser.
  // static const webBaseUrl = String.fromEnvironment(
  //   'WEB_BASE_URL',
  //   defaultValue: 'http://192.168.0.155:3000',
  // );
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
  static const uploadTimeout = Duration(seconds: 120);

  /// Cached GETs and prefetched records expire after this.
  static const cacheTtl = Duration(hours: 24);

  /// A queued mutation is dropped after this many failed replays.
  static const maxMutationAttempts = 5;

  /// prefetchOfflineBundle no-ops if it ran more recently than this.
  static const prefetchThrottle = Duration(hours: 4);
}
