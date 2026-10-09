import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/conversation/conversation_links.dart';
import '../../core/notifications/notice_list.dart';
import '../../core/push/push_content.dart';
import '../../core/utils/dates.dart';
import '../../domain/app_notification.dart';
import '../../theme/fe_colors.dart';

/// Icon and colour per notification — the same families the tray uses
/// (push_content.dart), so a technician recognises a snag or a permit the
/// same way in both places. AI teammates are violet, as on the web.
({IconData icon, Color accent, Color soft}) noticeVisual(AppNotification n) {
  final data = n.asPushData();
  final kind = pushKindOf(data);
  final priority = pushPriorityOf(data);
  if (priority == NoticePriority.critical) {
    return (icon: LucideIcons.siren, accent: FeColors.danger, soft: FeColors.dangerSoft);
  }
  final family = noticeFamily(n.entityType, category: n.category);
  switch (family) {
    case NoticeFamily.scheduleFailed:
      return (icon: LucideIcons.calendarX, accent: FeColors.danger, soft: FeColors.dangerSoft);
    case NoticeFamily.scheduleDone:
      return (icon: LucideIcons.calendarCheck, accent: FeColors.ai, soft: FeColors.aiSoft);
    case NoticeFamily.scheduleStarted:
      return (icon: LucideIcons.calendarClock, accent: FeColors.ai, soft: FeColors.aiSoft);
    case NoticeFamily.agentReply:
      return (icon: LucideIcons.sparkles, accent: FeColors.ai, soft: FeColors.aiSoft);
    case NoticeFamily.mention:
      return (icon: LucideIcons.atSign, accent: FeColors.primary, soft: FeColors.infoSoft);
    case NoticeFamily.conversation:
      return (icon: LucideIcons.messageSquare, accent: FeColors.primary, soft: FeColors.infoSoft);
    case NoticeFamily.other:
      break;
  }
  final urgent = n.type == 'warning' || n.type == 'error' || priority == NoticePriority.high && kind != PushKind.invite;
  final good = n.type == 'success';
  Color accent(Color normal) => n.type == 'error'
      ? FeColors.danger
      : urgent
          ? FeColors.warning
          : good
              ? FeColors.success
              : normal;
  Color soft(Color normal) => n.type == 'error'
      ? FeColors.dangerSoft
      : urgent
          ? FeColors.warningSoft
          : good
              ? FeColors.successSoft
              : normal;
  final IconData icon = switch (kind) {
    PushKind.invite => LucideIcons.briefcase,
    PushKind.inviteWithdrawn => LucideIcons.userX,
    PushKind.newWork => n.entityType == 'Inspection' || n.entityType == 'InspectionAssignment'
        ? LucideIcons.clipboardCheck
        : LucideIcons.wrench,
    PushKind.atRisk => LucideIcons.triangleAlert,
    PushKind.route => LucideIcons.route,
    PushKind.snag || PushKind.finding => LucideIcons.construction,
    PushKind.permit => n.type == 'error' ? LucideIcons.shieldAlert : LucideIcons.shieldCheck,
    PushKind.arInstall => LucideIcons.scanLine,
    PushKind.certification => LucideIcons.award,
    PushKind.alert => LucideIcons.siren,
    PushKind.message || PushKind.mention => LucideIcons.messageSquare,
    PushKind.agentSession => LucideIcons.bot,
    PushKind.schedule => LucideIcons.calendarClock,
    PushKind.digest => LucideIcons.layers,
    PushKind.general => n.type == 'warning' || n.type == 'error' ? LucideIcons.circleAlert : LucideIcons.info,
  };
  return (icon: icon, accent: accent(FeColors.primary), soft: soft(FeColors.infoSoft));
}

IconData groupIcon(NoticeGroup? g) => switch (g) {
      null => LucideIcons.inbox,
      NoticeGroup.work => LucideIcons.wrench,
      NoticeGroup.snags => LucideIcons.construction,
      NoticeGroup.permits => LucideIcons.shieldCheck,
      NoticeGroup.messages => LucideIcons.messageSquare,
      NoticeGroup.schedules => LucideIcons.calendarClock,
      NoticeGroup.system => LucideIcons.bell,
    };

String groupLabel(BuildContext context, NoticeGroup? g) =>
    (g == null ? 'notifications.tab_all' : 'notifications.group_${g.wire}').getString(context);

/// "5 min ago", "Yesterday", or the date.
String relativeTimeLabel(BuildContext context, DateTime? at, DateTime now) {
  final r = relativeTimeOf(at, now);
  return switch (r.key) {
    'now' => 'notifications.time_now'.getString(context),
    'minutes' => context.formatString('notifications.time_minutes'.getString(context), ['${r.n}']),
    'hours' => context.formatString('notifications.time_hours'.getString(context), ['${r.n}']),
    'yesterday' => 'notifications.time_yesterday'.getString(context),
    'days' => context.formatString('notifications.time_days'.getString(context), ['${r.n}']),
    _ => at == null ? '' : formatDateTimeShort(at.toLocal()),
  };
}
