import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../domain/conversation.dart';
import '../../state/conversation_controller.dart';
import '../../state/invites_controller.dart';
import '../../state/locale_controller.dart';
import '../../state/notifications_controller.dart';
import '../../state/order_detail_controller.dart';
import '../../state/providers.dart';
import '../../widgets/tech_popup.dart';
import '../conversation/conversation_links.dart';
import '../conversation/conversation_outbox.dart';
import '../network/api_exception.dart';
import '../utils/notification_route.dart';
import 'local_notifications.dart';
import 'native_push_actions.dart';
import 'pending_push_actions.dart';
import 'push_content.dart';

/// Runs in a separate isolate when a data message arrives while the app is
/// backgrounded or killed, so it must re-init Firebase itself. Top-level (not
/// a method) and `@pragma('vm:entry-point')` are both required by the plugin
/// so the background isolate can find this function after tree-shaking.
///
/// The message is data-only (see `notificationService.ts`), so without this
/// the OS shows nothing at all on Android — no banner, no sound. This is what
/// actually posts the ting. (iOS: the server's APNs alert is what shows while
/// the app is in the background; this handler isn't woken for it.)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await LocalNotifications.show(message);
}

/// Wires FCM (Firebase Cloud Messaging) into the app: asks permission, hands
/// the device token to the server, shows the locally-drawn notification (with
/// sound) on receipt, and handles every way a notification is answered —
/// a tap, a button, a typed reply — from any state (foreground, background,
/// cold start; drawn by the app, or by iOS from the server's APNs alert).
/// Where a tap goes is the one rule in `core/utils/notification_route.dart`.
class PushService {
  PushService(this._ref);

  final Ref _ref;
  // Lazy, because FirebaseMessaging.instance throws when no Firebase app
  // exists (an iOS build without GoogleService-Info.plist, see main.dart).
  // This object is built on every login and session restore
  // (auth_controller.dart), so an eager field would break both.
  late final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// The one-time listener setup, shared by concurrent callers (session
  /// restore and login can both call [init] in the same launch). Completes
  /// false when permission is denied, and is then cleared so a later call
  /// asks again.
  Future<bool>? _attached;

  /// Notifications answered in the last few seconds. On a cold start iOS can
  /// report one tap twice (a button through the app delegate, and the same
  /// alert through firebase_messaging's initial message); the second is
  /// dropped here instead of navigating twice.
  final _recent = <String, DateTime>{};

  /// Safe to call on every login, session restore and app resume. Listeners
  /// are attached once per process, but the token is sent to the server every
  /// time. It used to be sent only on the first call, so a failed first
  /// attempt (iOS APNs token still pending, offline at launch, a 401) left
  /// the device unregistered until the token itself rotated, and a second
  /// user signing in on the same phone never claimed it.
  Future<void> init() async {
    if (Firebase.apps.isEmpty) return;
    final attached = await (_attached ??= _attach());
    if (!attached) {
      _attached = null;
      return;
    }
    await syncToken();
  }

  /// Sends the current FCM token to the server. The server upserts on the
  /// token and takes the user from the auth header, so repeating this is
  /// harmless and also moves the device to whoever is signed in now. Also
  /// sends any "Mark read" pressed in the tray while the app was closed.
  Future<void> syncToken() async {
    if (_attached == null) return;
    final token = await _fcmToken();
    if (token != null) await _register(token);
    await flushPendingReads();
  }

  Future<bool> _attach() async {
    final settings = await _messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return false;

    await LocalNotifications.init(
      onResponse: (payload, actionId, input) => _handleResponse(payload, actionId, input: input),
    );

    // Attached before the first token fetch so a token FCM produces while
    // [_fcmToken] is still waiting for APNs is not missed.
    _messaging.onTokenRefresh.listen(_register);

    FirebaseMessaging.onMessage.listen((message) {
      LocalNotifications.show(message);
      _ref.invalidate(unseenNotificationCountProvider);
      // The bell list too, if it is open, so the new row is there to tap.
      if (_ref.exists(notificationsControllerProvider)) {
        _ref.read(notificationsControllerProvider.notifier).refresh();
      }
    });

    // Tapped a tray notification (or one of its buttons) and that launched
    // the app from cold.
    final launch = await LocalNotifications.launchResponse();
    if (launch != null) _handleResponse(launch.payload, launch.actionId, input: launch.input);

    // iOS: a button on an alert iOS drew itself (app in the background or
    // closed) — the app delegate hands it over with the typed reply.
    final pending = await NativePushActions.listen(
      (a) => _handleResponse(jsonEncode(a.data), a.actionId, input: a.input),
    );
    for (final a in pending) {
      _handleResponse(jsonEncode(a.data), a.actionId, input: a.input);
    }

    // iOS: a tap on the body of the server's APNs alert arrives through FCM,
    // not the local-notifications plugin. Android pushes are data-only and
    // never reach these.
    FirebaseMessaging.onMessageOpenedApp.listen((m) => _handleResponse(jsonEncode(m.data), null));
    final initial = await _messaging.getInitialMessage();
    if (initial != null) _handleResponse(jsonEncode(initial.data), null);
    return true;
  }

  /// The FCM token, or null when there isn't one yet. On iOS, `getToken()`
  /// throws `apns-token-not-set` until APNs has handed the app its device
  /// token (firebase_messaging_platform_interface `_APNSTokenCheck`), and that
  /// can lag the permission prompt by a few seconds on a first launch. Offline
  /// at launch it throws on both platforms. Either throw used to abort
  /// [init] before any listener was set up, so that process never showed a
  /// foreground push or routed a tap. A null here is not fatal: once FCM has
  /// a token, `onTokenRefresh` hands it to [_register], and the next
  /// [syncToken] (app resume) tries again.
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
    if (_attached == null) return;
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        await _ref.read(notificationsRepositoryProvider).unregisterDevice(token);
      }
    } catch (_) {
      // Not worth failing logout over.
    }
  }

  /// Sends the "Mark read" taps parked while the app wasn't running
  /// ([PendingPushActions]). Offline, they are put back for the next try.
  Future<void> flushPendingReads() async {
    final ids = await PendingPushActions.takeReads();
    if (ids.isEmpty) return;
    final repo = _ref.read(notificationsRepositoryProvider);
    final failed = <String>[];
    for (final id in ids) {
      try {
        await repo.markRead(id);
      } on HttpFailure {
        // 404 = gone or not theirs: nothing to retry.
      } catch (_) {
        failed.add(id);
      }
    }
    if (failed.isNotEmpty) await PendingPushActions.restoreReads(failed);
    _refreshBell();
  }

  /// A tap on a notification ([actionId] null) or on one of its buttons
  /// (`push_content.dart` [PushAction]), with the typed text for Reply.
  /// Every button but Mark read opens the app, so this runs here, signed in,
  /// with the router and the offline queue.
  Future<void> _handleResponse(String? payload, String? actionId, {String? input}) async {
    if (payload == null) return;
    final PushData data;
    try {
      data = PushData.fromMap(Map<String, dynamic>.from(jsonDecode(payload) as Map));
    } catch (_) {
      return;
    }
    if (_isRepeat(data, actionId)) return;

    final action = PushAction.fromId(actionId);
    if (action == PushAction.markRead) {
      for (final id in [?data.notificationId, ...data.notificationIds]) {
        _markRead(id);
      }
      await LocalNotifications.cancelFor(data);
      return;
    }
    _markRead(data.notificationId);

    final router = _ref.read(routerProvider);
    switch (action) {
      case PushAction.acceptInvite:
        await acceptInvite(data);
      // Declining needs a reason, which the inbox asks for.
      case PushAction.declineInvite:
        router.go(Routes.invites);
      case PushAction.myOrders:
        router.go(Routes.orders);
      case PushAction.scan:
        router.go(Routes.scan);
      case PushAction.reply:
        await _reply(data, input);
      case PushAction.markRead:
        break; // handled above
      case PushAction.open:
      case null:
        router.go(targetFor(data));
    }
  }

  /// Where a tap on [data] goes: its screen, or — when the app has none —
  /// the notifications list with its details sheet open (never a dead tap).
  static String targetFor(PushData data) {
    final route = routeForNotificationFields(
      link: data.link,
      entityId: data.entityId,
      entityType: data.entityType,
      title: data.title,
      route: data.route,
      group: data.group?.wire,
    );
    if (route != null) return route;
    return Routes.notificationsFor(open: data.notificationId, group: data.notificationId == null ? data.group?.wire : null);
  }

  bool _isRepeat(PushData data, String? actionId) {
    final key = data.notificationId ?? data.threadId;
    if (key == null) return false;
    final now = DateTime.now();
    _recent.removeWhere((_, at) => now.difference(at) > const Duration(seconds: 10));
    // A button and then the plain tap of the same alert: keep the button.
    if (_recent.containsKey(key) && actionId == null) return true;
    _recent[key] = now;
    return false;
  }

  /// Accept from the tray, the same call the inbox makes
  /// (`InvitesController.respond`) — queued when offline like any other
  /// write. On success the job opens; on a refusal (already answered, or
  /// passed to the next technician) the inbox opens with the server's reason.
  Future<void> acceptInvite(PushData data) async {
    final router = _ref.read(routerProvider);
    final type = orderTypeForEntity(data.entityType);
    final id = data.entityId;
    if (type == null || id == null) {
      router.go(Routes.invites);
      return;
    }
    final lang = _ref.read(localeControllerProvider);
    try {
      final write = await _ref.read(assignmentRepositoryProvider).respond(type, id, accept: true);
      _ref.invalidate(invitesControllerProvider);
      router.go(Routes.orderDetail(type.slug, id));
      _popup(
        pushResultText(write.synced ? 'result.accepted' : 'result.accepted_offline', lang: lang),
        queued: !write.synced,
      );
    } on HttpFailure catch (e) {
      _ref.invalidate(invitesControllerProvider);
      router.go(Routes.invites);
      _popup(e.message.isEmpty ? pushResultText('result.accept_failed', lang: lang) : e.message, isError: true);
    } catch (_) {
      router.go(Routes.invites);
      _popup(pushResultText('result.accept_failed', lang: lang), isError: true);
    }
  }

  /// Reply typed in the notification: posted through the same conversation
  /// API the thread uses (`ConversationRepository.post` → `syncRequest`, so
  /// with no signal it parks in the offline queue and sends itself later),
  /// as a reply to the message the notification was about. The thread opens
  /// either way, so the technician sees it land (or "waiting for signal").
  Future<void> _reply(PushData data, String? input) async {
    final router = _ref.read(routerProvider);
    final threadRoute = targetFor(data);
    final text = input?.trim() ?? '';
    if (replyTargetOf(data) == null || text.isEmpty) {
      router.go(threadRoute);
      return;
    }
    final lang = _ref.read(localeControllerProvider);
    try {
      final outcome = await postReply(data, text);
      router.go(threadRoute);
      final queued = outcome is PostQueued;
      _popup(pushResultText(queued ? 'result.reply_queued' : 'result.reply_sent', lang: lang), queued: queued);
    } catch (_) {
      router.go(threadRoute);
      _popup(pushResultText('result.reply_failed', lang: lang), isError: true);
    }
  }

  /// Posts [text] as a reply to the thread message [data] is about. Throws
  /// on a server refusal; a [PostQueued] outcome means no signal (it sends
  /// itself later). Also used by the Reply button on a card in the list.
  Future<PostOutcome> postReply(PushData data, String text) async {
    final target = replyTargetOf(data);
    final entity = ConvEntity.fromWire(target?.entity);
    if (target == null || entity == null) throw StateError('not a thread message');
    return _ref.read(conversationRepositoryProvider).post(
          entity,
          target.id,
          body: text.trim(),
          clientId: _ref.read(apiClientProvider).newMutationId(),
          replyTo: messageIdFromLink(data.link),
        );
  }

  /// Opening a notification from the tray reads it, as tapping it in the
  /// bell list does. Best-effort: offline, it is parked and sent later.
  void _markRead(String? notificationId) {
    if (notificationId == null) return;
    _ref
        .read(notificationsRepositoryProvider)
        .markRead(notificationId)
        .then((_) => _refreshBell())
        .catchError((Object e) {
          if (e is! HttpFailure) PendingPushActions.addRead(notificationId);
        });
  }

  void _refreshBell() {
    _ref.invalidate(unseenNotificationCountProvider);
    if (_ref.exists(notificationsControllerProvider)) {
      _ref.read(notificationsControllerProvider.notifier).refresh();
    }
  }

  /// The result toast, once the screen just navigated to has built (a cold
  /// start may not have a navigator yet; then the screen itself says enough).
  void _popup(String message, {bool queued = false, bool isError = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      showTechPopup(context, message: message, queued: queued, isError: isError);
    });
  }
}

final pushServiceProvider = Provider<PushService>((ref) => PushService(ref));
