import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/fe_colors.dart';
import 'push_content.dart';

/// Posts the system notification a push actually shows up as. FCM (Firebase
/// Cloud Messaging) messages here are data-only (see `notificationService.ts`
/// on the server) so nothing appears — and no sound plays — unless this draws
/// it itself. One channel, one custom sound: a short synthesized "ting"
/// (`android/app/src/main/res/raw/notification_ting.wav`), not the OS default.
/// iOS plays a byte-identical copy bundled as an app resource
/// (`ios/Runner/notification_ting.wav`), so replace both files together.
///
/// What it draws (since 2026-10-07) comes from `push_content.dart`: the
/// server's message as the expandable body (it used to show the title only),
/// a short kind badge, a tone colour, and up to two action buttons (Accept /
/// Decline on an invite, Open job / My orders on new work, …). Every button
/// opens the app; [PushService] does the work there.
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

  /// [onResponse] fires with the tapped notification's payload (the push
  /// data, JSON-encoded) and the button pressed, null for a tap on the body —
  /// omit it in the background isolate, where there is no router to hand the
  /// result to.
  static Future<void> init({void Function(String? payload, String? actionId)? onResponse}) async {
    if (_initialized) return;
    _initialized = true;

    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        // iOS: permission is asked by FirebaseMessaging.requestPermission
        // (push_service.dart), so the plugin must not ask again here. iOS
        // buttons come from categories registered up front; the category a
        // notification uses is named per kind in [show].
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: await _darwinCategories(),
        ),
      ),
      onDidReceiveNotificationResponse: onResponse == null
          ? null
          : (response) => onResponse(response.payload, response.actionId),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
  }

  /// The notification (and button) that launched the app from a cold start
  /// (app was fully killed, technician tapped the tray entry) — checked once
  /// at startup since `onDidReceiveNotificationResponse` only fires for a tap
  /// while the plugin is already running.
  static Future<({String? payload, String? actionId})?> launchResponse() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    final r = details?.notificationResponse;
    return r == null ? null : (payload: r.payload, actionId: r.actionId);
  }

  static Future<void> show(RemoteMessage message) async {
    await init();
    final data = PushData.fromMap(message.data);
    final lang = await _language();
    final display = pushDisplayFor(data, lang: lang);
    final actions = pushActionsFor(data);
    final tone = pushToneFor(data);
    final tag = pushTagFor(data);
    final body = display.body;

    await _plugin.show(
      id: pushIdFor(tag ?? '${message.messageId ?? message.hashCode}'),
      title: display.title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: _channel.importance,
          priority: Priority.high,
          sound: _channel.sound,
          playSound: true,
          // The message names the job, asset and due date; let it expand
          // rather than cut off after one line.
          styleInformation: body == null ? null : BigTextStyleInformation(body, contentTitle: display.title, summaryText: display.badge),
          subText: display.badge,
          color: switch (tone) {
            PushTone.urgent => FeColors.danger,
            PushTone.good => FeColors.success,
            PushTone.normal => FeColors.primary,
          },
          // No Android `tag`: the id (hashed from [pushTagFor]) already makes
          // the same thing again (a snag rejected, then closed) replace its
          // banner. A tag would also stop a button from clearing it —
          // flutter_local_notifications 22.3.0 cancels a pressed button's
          // notification by id alone (`processForegroundNotificationAction`).
          category: tone == PushTone.urgent ? AndroidNotificationCategory.reminder : AndroidNotificationCategory.message,
          actions: [
            for (final a in actions)
              AndroidNotificationAction(
                a.id,
                pushActionLabel(a, data, lang: lang),
                // The work needs the session, the queue and the router, so
                // every button brings the app up (no background isolate).
                showsUserInterface: true,
                cancelNotification: true,
              ),
          ],
        ),
        // Without Darwin details iOS shows nothing for a data-only push that
        // arrives while the app is open. `sound` names the bundled copy of the
        // Android ting (see the class doc).
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: true,
          sound: 'notification_ting.wav',
          subtitle: display.badge,
          threadIdentifier: tag,
          categoryIdentifier: actions.isEmpty ? null : _darwinCategoryId(actions),
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }

  /// The language the technician picked in the app. The background isolate
  /// has no `LocaleController`, so this reads the same SharedPreferences
  /// entry flutter_localization 0.4.x persists the choice under
  /// (`PreferenceUtil._locale_key`). Anything unreadable means English.
  static Future<String> _language() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('translator_locale_key');
      if (raw == null) return 'en';
      final code = (jsonDecode(raw) as Map)['translator_language_code'];
      return code == 'ar' ? 'ar' : 'en';
    } catch (_) {
      return 'en';
    }
  }

  /// One iOS category per distinct button set. iOS fixes a category's button
  /// titles when it is registered, so they are labelled in the language set
  /// at app start; a language switch takes effect on the next launch.
  static String _darwinCategoryId(List<PushAction> actions) => 'fe_${actions.map((a) => a.id).join('_')}';

  static Future<List<DarwinNotificationCategory>> _darwinCategories() async {
    final lang = await _language();
    const sets = [
      [PushAction.acceptInvite, PushAction.declineInvite],
      [PushAction.open, PushAction.myOrders],
      [PushAction.open, PushAction.scan],
      [PushAction.open],
    ];
    // Generic labels: a category is shared by every kind with the same
    // buttons, so "Open" can't say "Open snag" here the way Android can.
    const generic = PushData();
    return [
      for (final set in sets)
        DarwinNotificationCategory(
          _darwinCategoryId(set),
          actions: [
            for (final a in set)
              DarwinNotificationAction.plain(
                a.id,
                pushActionLabel(a, generic, lang: lang),
                options: {DarwinNotificationActionOption.foreground},
              ),
          ],
        ),
    ];
  }
}
