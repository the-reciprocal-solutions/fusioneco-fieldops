import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/fe_colors.dart';
import 'push_content.dart';

/// Draws pushes in the tray. The server sends data-only messages on Android
/// (services/push/pushPayload.ts), so without this nothing shows at all; on
/// iOS the server's APNs alert shows while the app is in the background and
/// this only draws the foreground banner. A slimmer copy of FieldOps'
/// lib/core/push/local_notifications.dart.
abstract final class LocalNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// The language the app last ran in (flutter_localization saves it); the
  /// background isolate has no other way to know it.
  static Future<bool> _arabic() async {
    try {
      // flutter_localization's PreferenceUtil key.
      final raw = (await SharedPreferences.getInstance()).getString('translator_locale_key');
      return raw != null && (jsonDecode(raw) as Map)['translator_language_code'] == 'ar';
    } catch (_) {
      return false;
    }
  }

  static List<AndroidNotificationChannel> _channels(bool ar) => [
        AndroidNotificationChannel(
          'fe_alerts_critical',
          ar ? 'تنبيهات حرجة' : 'Critical alerts',
          description: ar ? 'تنبيهات المباني الحرجة.' : 'Critical building alerts.',
          importance: Importance.max,
          bypassDnd: true,
          audioAttributesUsage: AudioAttributesUsage.alarm,
        ),
        AndroidNotificationChannel(
          'fe_alerts',
          ar ? 'التنبيهات' : 'Alerts',
          description: ar ? 'تنبيهات جديدة ومصعّدة في مبانيك.' : 'New and escalated alerts in your buildings.',
          importance: Importance.high,
        ),
        AndroidNotificationChannel(
          'fe_updates',
          ar ? 'التحديثات' : 'Updates',
          description: ar ? 'إشعارات أخرى من Fusion Eco.' : 'Other Fusion Eco notifications.',
          importance: Importance.defaultImportance,
        ),
      ];

  /// [onTap] gets the tapped push's data (JSON). Omit it in the background isolate.
  static Future<void> init({void Function(String? payload)? onTap}) async {
    if (_initialized) return;
    _initialized = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // FirebaseMessaging.requestPermission asks on iOS; don't ask twice.
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
      onDidReceiveNotificationResponse: onTap == null ? null : (r) => onTap(r.payload),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final ar = await _arabic();
      for (final c in _channels(ar)) {
        await android.createNotificationChannel(c);
      }
    }
  }

  /// The tray entry that cold-started the app, if any.
  static Future<String?> launchPayload() async {
    final d = await _plugin.getNotificationAppLaunchDetails();
    return d?.didNotificationLaunchApp == true ? d?.notificationResponse?.payload : null;
  }

  static Future<void> show(RemoteMessage message) async {
    await init();
    final data = message.data;
    final title = (data['title'] as String?)?.trim();
    if (title == null || title.isEmpty) return;
    final body = (data['body'] as String?)?.trim();
    final ar = await _arabic();
    final channel = _channels(ar).firstWhere((c) => c.id == channelIdFor(data));
    final critical = channel.id == 'fe_alerts_critical';
    // One banner per alert: a re-push (escalation) replaces it.
    final tag = (data['alertKey'] as String?) ?? (data['notificationId'] as String?) ?? message.messageId ?? title;
    await _plugin.show(
      id: tag.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: critical ? Priority.max : Priority.high,
          styleInformation: body == null ? null : BigTextStyleInformation(body, contentTitle: title),
          subText: data['location'] as String?,
          color: critical ? FeColors.danger : FeColors.primary,
          category: critical ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.status,
        ),
        iOS: DarwinNotificationDetails(threadIdentifier: data['threadId'] as String?),
      ),
      payload: jsonEncode(data),
    );
  }
}
