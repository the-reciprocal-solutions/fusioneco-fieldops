import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../catalog/catalog_guard.dart';
import '../../state/alerts_controller.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import 'local_notifications.dart';
import 'push_content.dart';

// Firebase is started, and the one background handler registered, by
// FieldOps' main(): an app has a single background handler, and FieldOps'
// (lib/core/push/push_service.dart) hands a message to this side's
// LocalNotifications while an admin is the one signed in on the phone.

/// FCM for the admin app (FE-mobile.md 0.4): asks permission, gives the device
/// token to the server (`POST /api/notifications/register-device`, the user
/// comes from the token), draws foreground pushes, and opens the alert a
/// push is about. The server decides who gets what (services/alerts/mobilePush.ts).
class PushService {
  PushService(this._ref);
  final Ref _ref;

  Future<bool>? _attached;
  String? _token;

  bool get available => Firebase.apps.isNotEmpty;

  /// Every time the signed-in shell opens (sign-in, cold start). Listeners
  /// attach once; the token is re-sent each time, which also moves this
  /// phone to whoever signed in last.
  Future<void> init() async {
    if (!available) return;
    final first = _attached == null;
    final ok = await (_attached ??= _attach());
    if (!ok) {
      _attached = null;
      return;
    }
    // The notifications plugin is one per app: a technician who signed in
    // earlier in this run took its tap callback (and, on iOS, its categories).
    if (!first) await LocalNotifications.init(onTap: respond);
    await _register(await _fcmToken());
  }

  /// The listeners outlive a sign-out (FCM streams can't be detached per
  /// user), and FieldOps' technician side has its own: only the side that is
  /// signed in acts (lib/core/push/push_service.dart checks the reverse).
  bool get _active => _ref.read(authControllerProvider).isAuthenticated;

  /// Before sign-out, while the session still works: this phone stops
  /// getting this user's pushes. Best effort, never blocks sign-out long.
  Future<void> unregister() async {
    if (!available) return;
    try {
      final token = _token ?? await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await _ref.read(apiClientProvider).post('/api/notifications/unregister-device', body: {'token': token}).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('push unregister failed: $e');
    }
  }

  Future<bool> _attach() async {
    final m = FirebaseMessaging.instance;
    final settings = await m.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return false;

    await LocalNotifications.init(onTap: respond);
    m.onTokenRefresh.listen((t) {
      if (_active) _register(t);
    });
    FirebaseMessaging.onMessage.listen((message) {
      if (!_active) return;
      LocalNotifications.show(message);
      if (pushTargetOf(message.data) is AlertTarget) _ref.read(alertsTickProvider.notifier).state++;
    });
    // iOS: a tap on the APNs alert iOS drew itself.
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      if (_active) open(pushTargetOf(msg.data));
    });
    final initial = await m.getInitialMessage();
    if (initial != null) open(pushTargetOf(initial.data));
    // Android: the tray entry (or its Acknowledge button) cold-started the app.
    final launch = await LocalNotifications.launchResponse();
    if (launch != null) await respond(launch.$1, launch.$2);
    return true;
  }

  Future<String?> _fcmToken() async {
    try {
      if (Platform.isIOS) {
        // FCM has no token until APNs gives one.
        for (var i = 0; i < 10 && await FirebaseMessaging.instance.getAPNSToken() == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('FCM token unavailable: $e');
      return null;
    }
  }

  Future<void> _register(String? token) async {
    if (token == null) return;
    _token = token;
    try {
      await _ref.read(apiClientProvider).post('/api/notifications/register-device', body: {'token': token, 'platform': Platform.isIOS ? 'ios' : 'android'});
    } catch (e) {
      debugPrint('push register failed: $e');
    }
  }

  /// A tap on a tray entry we drew; [actionId] is the button, if any.
  /// Acknowledge runs with the live session, then the alert opens either way
  /// (it shows the new status, or still "active" when the call failed).
  @visibleForTesting
  Future<void> respond(String? payload, String? actionId) async {
    if (payload == null) return;
    final PushTarget target;
    try {
      target = pushTargetOf((jsonDecode(payload) as Map).cast<String, dynamic>());
    } catch (_) {
      return;
    }
    if (actionId == ackActionId && target is AlertTarget) {
      try {
        await _ref.read(alertsRepositoryProvider).act(target.key, 'acknowledge');
        _ref.read(alertsTickProvider.notifier).state++;
      } catch (e) {
        debugPrint('tray acknowledge failed: $e');
      }
    }
    open(target);
  }

  /// The catalog guard still decides: an alert opens only if Alerts is on.
  void open(PushTarget target) {
    final router = _ref.read(routerProvider);
    switch (target) {
      case AlertTarget(:final key):
        router.push(alertPath(key));
      case NotificationsTarget():
        router.push(modulePath('notifications'));
    }
  }
}

final pushServiceProvider = Provider<PushService>((ref) => PushService(ref));
