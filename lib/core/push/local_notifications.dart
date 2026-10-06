import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Posts the system notification a push actually shows up as. FCM (Firebase
/// Cloud Messaging) messages here are data-only (see `notificationService.ts`
/// on the server) so nothing appears — and no sound plays — unless this draws
/// it itself. One channel, one custom sound: a short synthesized "ting"
/// (`android/app/src/main/res/raw/notification_ting.wav`), not the OS default.
/// iOS plays a byte-identical copy bundled as an app resource
/// (`ios/Runner/notification_ting.wav`), so replace both files together.
class LocalNotifications {
  LocalNotifications._();

  static const _channel = AndroidNotificationChannel(
    'fcm_default_channel',
    'Notifications',
    description: 'Work order and assignment alerts.',
    importance: Importance.high,
    sound: RawResourceAndroidNotificationSound('notification_ting'),
  );

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// [onTap] fires with the tapped notification's payload (the push data,
  /// JSON-encoded) — omit it in the background isolate, where there is no
  /// router to hand the result to.
  static Future<void> init({void Function(String? payload)? onTap}) async {
    if (_initialized) return;
    _initialized = true;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // iOS: permission is asked by FirebaseMessaging.requestPermission
        // (push_service.dart), so the plugin must not ask again here.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: onTap == null
          ? null
          : (response) => onTap(response.payload),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
  }

  /// Payload of the notification that launched the app from a cold start
  /// (app was fully killed, technician tapped the tray entry) — checked once
  /// at startup since `onDidReceiveNotificationResponse` only fires for a tap
  /// while the plugin is already running.
  static Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse?.payload;
  }

  static Future<void> show(RemoteMessage message) async {
    await init();
    final data = message.data;
    await _plugin.show(
      id: message.hashCode,
      title: (data['title'] as String?)?.trim().isNotEmpty == true
          ? data['title'] as String
          : 'Fusion Eco',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: _channel.importance,
          priority: Priority.high,
          sound: _channel.sound,
          playSound: true,
        ),
        // Without Darwin details iOS shows nothing for a data-only push that
        // arrives while the app is open. `sound` names the bundled copy of the
        // Android ting (see the class doc).
        iOS: const DarwinNotificationDetails(presentAlert: true, presentBanner: true, presentList: true, presentSound: true, sound: 'notification_ting.wav'),
      ),
      payload: jsonEncode(data),
    );
  }
}
