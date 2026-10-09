import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/fe_colors.dart';
import 'notification_images.dart';
import 'pending_push_actions.dart';
import 'push_content.dart';

/// "Mark read" pressed on a tray notification (Android, or an iOS banner the
/// app drew): flutter_local_notifications runs this in a background isolate
/// with no session, so it only parks the id for the app to send
/// ([PendingPushActions]); the plugin has already cleared the banner.
/// Top-level and `vm:entry-point` so the isolate can find it.
@pragma('vm:entry-point')
Future<void> onBackgroundNotificationAction(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (PushAction.fromId(response.actionId) != PushAction.markRead) return;
  final payload = response.payload;
  if (payload == null) return;
  try {
    final data = PushData.fromMap(Map<String, dynamic>.from(jsonDecode(payload) as Map));
    for (final id in [?data.notificationId, ...data.notificationIds]) {
      await PendingPushActions.addRead(id);
    }
  } catch (_) {}
}

/// Posts the system notification a push actually shows up as. FCM (Firebase
/// Cloud Messaging) messages here are data-only (see `notificationService.ts`
/// on the server) so nothing appears — and no sound plays — unless this draws
/// it itself. The sound is a short synthesized "ting"
/// (`android/app/src/main/res/raw/notification_ting.wav`); iOS plays a
/// byte-identical copy bundled as an app resource
/// (`ios/Runner/notification_ting.wav`), so replace both files together.
///
/// What it draws comes from the pure `push_content.dart` (2026-10-10, payload v2):
/// - **one channel per group** (Work, Snags, Permits, Messages, Schedules,
///   Other) plus a quiet channel for low-priority news and an alarm channel
///   for critical ones; a person can mute a group in system settings without
///   losing the rest;
/// - **BigPicture** when the push names a photo (downloaded with a timeout,
///   BigText when that fails), **BigText** otherwise, **Inbox** for a digest;
/// - **grouping**: every notification carries its group key, and a group
///   summary (InboxStyle, newest lines) appears once two or more are in the
///   tray; iOS threads by record (`threadIdentifier`);
/// - **buttons** (Accept / Decline, Open, Scan, Reply with typed text, Mark
///   read) — every one but Mark read opens the app, where [PushService] does
///   the work;
/// - **full-screen intent** for critical only (shows over the lock screen
///   when the OS allows it — see docs/push-notifications.md), the app badge
///   number, and iOS interruption levels (time-sensitive / passive).
class LocalNotifications {
  LocalNotifications._();

  /// The old single channel. Kept (a channel's id can't be renamed, and its
  /// sound is fixed at creation) and reused for "Other updates".
  static const _legacyChannelId = 'fcm_default_channel';
  static const _sound = RawResourceAndroidNotificationSound('notification_ting');

  static String channelIdFor(NoticeGroup group, NoticePriority priority) {
    if (priority == NoticePriority.critical) return 'fe_critical';
    if (priority == NoticePriority.low) return 'fe_quiet';
    return switch (group) {
      NoticeGroup.work => 'fe_work',
      NoticeGroup.snags => 'fe_snags',
      NoticeGroup.permits => 'fe_permits',
      NoticeGroup.messages => 'fe_messages',
      NoticeGroup.schedules => 'fe_schedules',
      NoticeGroup.system => _legacyChannelId,
    };
  }

  static List<AndroidNotificationChannel> _channels(String lang) => [
        for (final g in NoticeGroup.values)
          AndroidNotificationChannel(
            channelIdFor(g, NoticePriority.normal),
            noticeGroupLabel(g, lang: lang),
            description: pushText('channel.${g.wire}_desc', lang: lang),
            // Schedules are the only group that waits: a reminder can make a
            // sound without dropping over whatever the technician is doing.
            importance: g == NoticeGroup.schedules ? Importance.defaultImportance : Importance.high,
            sound: _sound,
          ),
        AndroidNotificationChannel(
          'fe_critical',
          pushText('channel.critical', lang: lang),
          description: pushText('channel.critical_desc', lang: lang),
          importance: Importance.max,
          sound: _sound,
          // Honoured only if the person grants Do Not Disturb access.
          bypassDnd: true,
          audioAttributesUsage: AudioAttributesUsage.alarm,
        ),
        AndroidNotificationChannel(
          'fe_quiet',
          lang == 'ar' ? 'تحديثات هادئة' : 'Quiet updates',
          description: lang == 'ar' ? 'معلومات لا تحتاج إلى إجراء. بدون صوت.' : 'For your information. No sound.',
          importance: Importance.low,
          playSound: false,
        ),
      ];

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// [onResponse] fires with the tapped notification's payload (the push
  /// data, JSON-encoded), the button pressed (null for a tap on the body) and
  /// the typed reply, if any — omit it in the background isolate, where there
  /// is no router to hand the result to.
  static Future<void> init({void Function(String? payload, String? actionId, String? input)? onResponse}) async {
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
          // With the app running, every response (Mark read too) comes here
          // and PushService does it directly with the live session.
          : (response) => onResponse(response.payload, response.actionId, response.input),
      onDidReceiveBackgroundNotificationResponse: onBackgroundNotificationAction,
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final lang = await _language();
      for (final c in _channels(lang)) {
        // Re-creating updates the name/description (a language switch) but
        // never the importance or sound, which Android fixes at creation.
        await android.createNotificationChannel(c);
      }
    }
  }

  /// The notification (and button, and typed text) that launched the app
  /// from a cold start (app was fully killed, technician tapped the tray
  /// entry) — checked once at startup since `onDidReceiveNotificationResponse`
  /// only fires for a tap while the plugin is already running.
  static Future<({String? payload, String? actionId, String? input})?> launchResponse() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    final r = details?.notificationResponse;
    return r == null ? null : (payload: r.payload, actionId: r.actionId, input: r.input);
  }

  static Future<void> show(RemoteMessage message) => showData(message.data, fallbackKey: message.messageId);

  /// Draws one push (or digest) from its flat data map.
  static Future<void> showData(Map<String, dynamic> raw, {String? fallbackKey}) async {
    await init();
    final data = PushData.fromMap(raw);
    final lang = await _language();
    final display = pushDisplayFor(data, lang: lang);
    final actions = pushActionsFor(data);
    final tone = pushToneFor(data);
    final group = pushGroupOf(data);
    final priority = pushPriorityOf(data);
    final thread = pushThreadFor(data);
    final tag = pushTagFor(data) ?? fallbackKey ?? '${raw.hashCode}';
    final id = pushIdFor(tag);
    final body = display.body;
    final channelId = channelIdFor(group, priority);
    final channel = _channels(lang).firstWhere((c) => c.id == channelId);

    // The photo, if any — never more than a few seconds of waiting.
    final Uint8List? image = await NotificationImages.download(data.imageUrl);
    String? attachment;
    if (image != null && Platform.isIOS) {
      attachment = await NotificationImages.saveForAttachment(image, data.imageUrl!, key: tag);
    }

    final StyleInformation? style;
    if (data.isDigest && data.lines.isNotEmpty) {
      final more = (data.count ?? data.lines.length) - data.lines.length;
      style = InboxStyleInformation(
        data.lines,
        contentTitle: display.title,
        summaryText: more > 0 ? pushText('summary.more', lang: lang).replaceAll('%n', '$more') : null,
      );
    } else if (image != null) {
      style = BigPictureStyleInformation(
        ByteArrayAndroidBitmap(image),
        largeIcon: ByteArrayAndroidBitmap(image),
        contentTitle: display.title,
        summaryText: body,
        hideExpandedLargeIcon: true,
      );
    } else if (body != null) {
      // The message names the job, asset and due date; let it expand
      // rather than cut off after one line.
      style = BigTextStyleInformation(body, contentTitle: display.title, summaryText: display.badge);
    } else {
      style = null;
    }

    final groupKey = _groupKey(group);
    await _plugin.show(
      id: id,
      title: display.title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: switch (priority) {
            NoticePriority.critical => Priority.max,
            NoticePriority.high => Priority.high,
            NoticePriority.normal => Priority.high,
            NoticePriority.low => Priority.low,
          },
          sound: channel.sound,
          playSound: channel.playSound,
          styleInformation: style,
          largeIcon: image == null ? null : ByteArrayAndroidBitmap(image),
          subText: [?display.badge, ?data.location].join(' · ').ifEmptyNull,
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
          groupKey: groupKey,
          category: switch (pushKindOf(data)) {
            _ when priority == NoticePriority.critical => AndroidNotificationCategory.alarm,
            PushKind.message || PushKind.mention => AndroidNotificationCategory.message,
            PushKind.schedule => AndroidNotificationCategory.reminder,
            _ when tone == PushTone.urgent => AndroidNotificationCategory.reminder,
            _ => AndroidNotificationCategory.status,
          },
          // Critical only: over the lock screen when the OS allows it
          // (Android 14+ needs USE_FULL_SCREEN_INTENT granted; without it the
          // OS shows a heads-up instead — docs/push-notifications.md).
          fullScreenIntent: priority == NoticePriority.critical,
          visibility: priority == NoticePriority.critical ? NotificationVisibility.public : null,
          number: data.badge,
          ticker: display.title,
          when: DateTime.now().millisecondsSinceEpoch,
          actions: [
            for (final a in actions)
              AndroidNotificationAction(
                a.id,
                pushActionLabel(a, data, lang: lang),
                // The work needs the session, the queue and the router, so
                // every button but Mark read brings the app up.
                showsUserInterface: !a.runsInBackground,
                cancelNotification: true,
                semanticAction: switch (a) {
                  PushAction.reply => SemanticAction.reply,
                  PushAction.markRead => SemanticAction.markAsRead,
                  _ => SemanticAction.none,
                },
                inputs: a == PushAction.reply
                    ? [AndroidNotificationActionInput(label: pushText('reply.placeholder', lang: lang))]
                    : const [],
              ),
          ],
        ),
        // Without Darwin details iOS shows nothing for a data-only push that
        // arrives while the app is open. `sound` names the bundled copy of the
        // Android ting (see the class doc).
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: priority != NoticePriority.low,
          presentList: true,
          presentSound: priority != NoticePriority.low,
          presentBadge: data.badge != null,
          badgeNumber: data.badge,
          sound: 'notification_ting.wav',
          subtitle: display.badge,
          threadIdentifier: thread,
          categoryIdentifier: actions.isEmpty ? null : darwinCategoryId(actions),
          // Time-sensitive needs the "Time Sensitive Notifications"
          // capability on the App ID; until it is enabled iOS treats it as
          // active (docs/push-notifications.md, pending).
          interruptionLevel: switch (priority) {
            NoticePriority.critical || NoticePriority.high => InterruptionLevel.timeSensitive,
            NoticePriority.normal => InterruptionLevel.active,
            NoticePriority.low => InterruptionLevel.passive,
          },
          attachments: attachment == null ? null : [DarwinNotificationAttachment(attachment, hideThumbnail: false)],
        ),
      ),
      payload: jsonEncode(raw),
    );

    if (Platform.isAndroid) await _updateGroupSummary(group, lang);
  }

  static String _groupKey(NoticeGroup g) => 'com.fusionapps.fieldops.${g.wire}';

  /// Android shows separate notifications from one group as a bundle only
  /// with a summary notification. Once a group has two or more in the tray,
  /// this posts (or refreshes) its summary: the group name, the count, and
  /// the newest titles as Inbox lines. Silent — the child already rang.
  static Future<void> _updateGroupSummary(NoticeGroup group, String lang) async {
    try {
      final key = _groupKey(group);
      final summaryId = pushIdFor('summary:${group.wire}');
      final active = (await _plugin.getActiveNotifications())
          .where((n) => n.groupKey == key && n.id != summaryId)
          .toList();
      if (active.length < 2) return;
      final lines = active.reversed.map((n) => n.title ?? '').where((t) => t.isNotEmpty).take(6).toList();
      final label = noticeGroupLabel(group, lang: lang);
      final channelId = channelIdFor(group, NoticePriority.normal);
      await _plugin.show(
        id: summaryId,
        title: label,
        body: '${active.length}',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            label,
            groupKey: key,
            setAsGroupSummary: true,
            groupAlertBehavior: GroupAlertBehavior.children,
            onlyAlertOnce: true,
            silent: true,
            number: active.length,
            styleInformation: InboxStyleInformation(
              lines,
              contentTitle: label,
              summaryText: '${active.length}',
            ),
          ),
        ),
        payload: jsonEncode({'kind': 'digest', 'entityType': 'digest', 'group': group.wire, 'v': '2'}),
      );
    } catch (_) {
      // Grouping is cosmetic; the children are already posted.
    }
  }

  /// Clears the tray entry for a notification read in the app (the bell list
  /// or a tap), so the tray and the list agree.
  static Future<void> cancelFor(PushData data) async {
    final tag = pushTagFor(data);
    if (tag == null) return;
    try {
      await _plugin.cancel(id: pushIdFor(tag));
    } catch (_) {}
  }

  /// Clears every FieldOps notification from the tray ("mark all read").
  static Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (_) {}
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

  /// One iOS category per distinct button set: `fe_` + the action ids. The
  /// server names the same id in the APNs `category`
  /// (`pushPayload.ts darwinCategoryFor`), so an alert iOS draws itself while
  /// the app is closed gets these buttons too.
  static String darwinCategoryId(List<PushAction> actions) => 'fe_${actions.map((a) => a.id).join('_')}';

  /// Every button set [pushActionsFor] can produce. iOS fixes a category's
  /// button titles when it is registered, so they are labelled in the
  /// language set at app start; a language switch takes effect next launch.
  static const darwinActionSets = <List<PushAction>>[
    [PushAction.acceptInvite, PushAction.declineInvite],
    [PushAction.open],
    [PushAction.open, PushAction.scan],
    [PushAction.open, PushAction.markRead],
    [PushAction.open, PushAction.myOrders],
    [PushAction.reply, PushAction.markRead],
    [PushAction.markRead],
  ];

  static Future<List<DarwinNotificationCategory>> _darwinCategories() async {
    final lang = await _language();
    // Generic labels: a category is shared by every kind with the same
    // buttons, so "Open" can't say "Open snag" here the way Android can.
    const generic = PushData();
    return [
      for (final set in darwinActionSets)
        DarwinNotificationCategory(
          darwinCategoryId(set),
          actions: [
            for (final a in set)
              if (a == PushAction.reply)
                DarwinNotificationAction.text(
                  a.id,
                  pushActionLabel(a, generic, lang: lang),
                  buttonTitle: pushText('reply.send', lang: lang),
                  placeholder: pushText('reply.placeholder', lang: lang),
                  options: {DarwinNotificationActionOption.foreground},
                )
              else
                DarwinNotificationAction.plain(
                  a.id,
                  pushActionLabel(a, generic, lang: lang),
                  // Mark read stays in the background; the rest open the app.
                  options: a.runsInBackground ? const {} : {DarwinNotificationActionOption.foreground},
                ),
          ],
          // Show the group/record in the hidden-preview summary.
          options: {DarwinNotificationCategoryOption.hiddenPreviewShowTitle},
        ),
    ];
  }
}

extension on String {
  String? get ifEmptyNull => isEmpty ? null : this;
}
