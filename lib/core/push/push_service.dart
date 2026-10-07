import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../state/providers.dart';
import '../conversation/conversation_links.dart';
import 'local_notifications.dart';

/// Runs in a separate isolate when a data message arrives while the app is
/// backgrounded or killed, so it must re-init Firebase itself. Top-level (not
/// a method) and `@pragma('vm:entry-point')` are both required by the plugin
/// so the background isolate can find this function after tree-shaking.
///
/// The message is data-only (see `notificationService.ts`), so without this
/// the OS shows nothing at all — no banner, no sound. This is what actually
/// posts the ting.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await LocalNotifications.show(message);
}

/// Wires FCM (Firebase Cloud Messaging) into the app: asks permission, hands
/// the device token to the server, shows the locally-drawn notification (with
/// sound) on receipt, and routes a tap to the right screen using the same
/// entityType/link scheme the in-app list uses (see
/// `core/utils/notification_route.dart`).
class PushService {
  PushService(this._ref);

  final Ref _ref;
  // Lazy, because FirebaseMessaging.instance throws when no Firebase app
  // exists (an iOS build without GoogleService-Info.plist, see main.dart).
  // This object is built on every login and session restore
  // (auth_controller.dart), so an eager field would break both.
  late final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized || Firebase.apps.isEmpty) return;
    _initialized = true;

    final settings = await _messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return;

    await LocalNotifications.init(onTap: _routeFromPayload);

    final token = await _fcmToken();
    if (token != null) await _register(token);
    _messaging.onTokenRefresh.listen(_register);

    FirebaseMessaging.onMessage.listen((message) {
      LocalNotifications.show(message);
      _ref.invalidate(unseenNotificationCountProvider);
    });

    // Tapped a tray notification while the app was alive in the background.
    final launchPayload = await LocalNotifications.launchPayload();
    if (launchPayload != null) _routeFromPayload(launchPayload);

    // iOS: the server's APNs copy is an alert the OS shows itself while the
    // app is in the background or closed, so its tap arrives through FCM, not
    // the local-notifications plugin. (Android pushes are data-only and never
    // reach these.)
    FirebaseMessaging.onMessageOpenedApp.listen((m) => _routeFromPayload(jsonEncode(m.data)));
    final initial = await _messaging.getInitialMessage();
    if (initial != null) _routeFromPayload(jsonEncode(initial.data));
  }

  /// The FCM token, or null when there isn't one yet. On iOS, `getToken()`
  /// throws `apns-token-not-set` until APNs has handed the app its device
  /// token (firebase_messaging_platform_interface `_APNSTokenCheck`), and that
  /// can lag the permission prompt by a few seconds on a first launch. Offline
  /// at launch it throws on both platforms. Either throw used to abort
  /// [init] before any listener below was set up, so that process never
  /// showed a foreground push or routed a tap. A null here is not fatal:
  /// once FCM has a token, `onTokenRefresh` hands it to [_register].
  Future<String?> _fcmToken() async {
    try {
      if (Platform.isIOS) {
        for (var i = 0; i < 10 && await _messaging.getAPNSToken() == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      return await _messaging.getToken();
    } catch (_) {
      return null;
    }
  }

  Future<void> _register(String token) async {
    try {
      await _ref.read(notificationsRepositoryProvider).registerDevice(
            token: token,
            platform: Platform.isIOS ? 'ios' : 'android',
          );
    } catch (_) {
      // Registration is advisory — losing push on one device must not block
      // the rest of the app.
    }
  }

  /// Best-effort — called on logout, while the auth token is still valid.
  Future<void> unregister() async {
    if (!_initialized) return;
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        await _ref.read(notificationsRepositoryProvider).unregisterDevice(token);
      }
    } catch (_) {
      // Not worth failing logout over.
    }
  }

  void _routeFromPayload(String? payload) {
    if (payload == null) return;
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final route = _routeForPushData(
      link: data['link'] as String?,
      entityId: data['entityId'] as String?,
      entityType: data['entityType'] as String?,
      title: data['title'] as String?,
    );
    if (route != null) _ref.read(routerProvider).go(route);
  }
}

/// Same rules as `routeForNotification` in `core/utils/notification_route.dart`,
/// against the flat string keys a push data payload carries instead of the
/// typed `AppNotification` the in-app list uses.
String? _routeForPushData({
  String? link,
  String? entityId,
  String? entityType,
  String? title,
}) {
  // Same first step as `routeForNotification`: conversation / schedule
  // pushes carry web admin links (see conversation_links.dart).
  final conversation = conversationRouteFor(entityType: entityType, entityId: entityId, link: link);
  if (conversation != null) return conversation;

  final trimmedLink = link?.trim();
  if (trimmedLink != null && trimmedLink.isNotEmpty) {
    const prefix = '/technician';
    if (!trimmedLink.startsWith(prefix)) return null;
    final route = trimmedLink.substring(prefix.length);
    if (route.isEmpty || route == '/') return Routes.dashboard;
    return route.startsWith('/') ? route : '/$route';
  }

  if (entityId == null || entityId.isEmpty) return null;
  if (entityType == null || entityType.isEmpty) return null;
  if (entityType == 'conversation') return null;
  if (title == 'New assignment invite') return Routes.invites;
  if (entityType == 'Inspection') return Routes.inspectionDetail(entityId);
  if (entityType == 'Snag') return Routes.snagDetail(entityId);
  // Permit to Work: the link `/technician/permits/<id>` maps through the
  // prefix strip above; this covers a link-less one. `ptwService.ts` stamps
  // `entityType: "PermitToWork"`; `Permit` is kept too for symmetry with
  // `routeForNotification` in core/utils/notification_route.dart.
  if (entityType == 'Permit' || entityType == 'PermitToWork') {
    return Routes.permitDetail(entityId);
  }
  // AR install request: the link `/technician/ar/install?floorId=<id>` maps
  // through the prefix strip above; a link-less one names the floor. The
  // server stamps `ar_install_request` (installRequestService.ts).
  if (entityType == 'ar_install_request' || entityType == 'ArInstallRequest') {
    return Routes.arInstall(floorId: entityId);
  }

  final slug = switch (entityType) {
    'WorkOrder' => 'work-order',
    'PreventiveMaintenance' => 'preventive',
    'ReactiveMaintenance' => 'reactive',
    'AnnualMaintenance' => 'annual',
    _ => null,
  };
  return slug == null ? null : Routes.orderDetail(slug, entityId);
}

final pushServiceProvider = Provider<PushService>((ref) => PushService(ref));
