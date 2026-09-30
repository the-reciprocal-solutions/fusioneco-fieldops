import 'package:intl/intl.dart';

import '../../domain/user_schedule.dart';

/// Plain words for when a schedule runs ("Every Monday 08:00"), used by the
/// schedule card in a thread and the My schedules list.
///
/// Pure: `t` looks up an i18n template (`schedules.cadence.*`) and `%a`
/// placeholders are filled in order, like `context.formatString`. Tests pass
/// the English map; the app passes `key.getString(context)`.
///
/// `locale` stays null in the app: `main()` never initialises intl locale
/// data (no `initializeDateFormatting`), so asking DateFormat for 'ar' or
/// even 'en' throws LocaleDataException. Dates use the default locale, like
/// every other date in this app.
typedef Lookup = String Function(String key);

String fillArgs(String template, List<Object> args) {
  var i = 0;
  return template.replaceAllMapped('%a', (_) => i < args.length ? '${args[i++]}' : '');
}

const _dayOrder = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// Localised full day name for `mon`…`sun` (2024-01-01 was a Monday).
String dayName(String key, {String? locale}) {
  final i = _dayOrder.indexOf(key);
  if (i < 0) return key;
  return DateFormat.EEEE(locale).format(DateTime(2024, 1, 1 + i));
}

/// "08:00" stays as written: the server sends the time in the schedule's
/// own zone, and re-formatting it through the phone's zone would move it.
String _at(String? at) => (at ?? '').trim();

String describeCadence(UserSchedule s, Lookup t, {String? locale}) {
  final server = s.cadenceText?.trim();
  if (server != null && server.isNotEmpty) return server;
  final c = s.cadence;
  final at = _at(c.at);
  String withAt(String key, [List<Object> args = const []]) =>
      at.isEmpty ? fillArgs(t('$key.no_time'), args) : fillArgs(t(key), [...args, at]);

  switch (c.freq) {
    case 'once':
    case 'one-off':
    case 'oneoff':
      final when = c.date ?? s.nextRunAt;
      return when == null
          ? t('schedules.cadence.once_unknown')
          : fillArgs(t('schedules.cadence.once'), [DateFormat.MMMEd(locale).add_Hm().format(when)]);
    case 'hourly':
      return c.interval <= 1
          ? t('schedules.cadence.hourly')
          : fillArgs(t('schedules.cadence.every_hours'), [c.interval]);
    case 'daily':
      return c.interval <= 1 ? withAt('schedules.cadence.daily') : withAt('schedules.cadence.every_days', [c.interval]);
    case 'weekdays':
      return withAt('schedules.cadence.weekdays');
    case 'weekly':
      final days = [..._dayOrder.where(c.days.contains)];
      if (days.length == 5 && !days.contains('sat') && !days.contains('sun')) {
        return withAt('schedules.cadence.weekdays');
      }
      final names = days.isEmpty ? '' : days.map((d) => dayName(d, locale: locale)).join(', ');
      if (names.isEmpty) return withAt('schedules.cadence.weekly_plain');
      return withAt('schedules.cadence.weekly', [names]);
    case 'monthly':
      return withAt('schedules.cadence.monthly');
  }
  // Unknown shape: say when it next runs rather than guessing a pattern.
  final next = s.nextRunAt;
  return next == null
      ? t('schedules.cadence.unknown')
      : fillArgs(t('schedules.cadence.next_only'), [DateFormat.MMMEd(locale).add_Hm().format(next)]);
}

/// "in 3 h", "tomorrow 09:00", "Mon 6 Oct 08:00" — for "Next run".
String describeNextRun(DateTime? next, Lookup t, {DateTime? now, String? locale}) {
  if (next == null) return t('schedules.next_none');
  final n = now ?? DateTime.now();
  final diff = next.difference(n);
  if (diff.isNegative) return t('schedules.next_due');
  if (diff.inMinutes < 60) return fillArgs(t('schedules.next_in_min'), [diff.inMinutes < 1 ? 1 : diff.inMinutes]);
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(next.year, next.month, next.day);
  final hm = DateFormat.Hm(locale).format(next);
  if (day == today) return fillArgs(t('schedules.next_today'), [hm]);
  if (day.difference(today).inDays == 1) return fillArgs(t('schedules.next_tomorrow'), [hm]);
  return DateFormat.MMMEd(locale).add_Hm().format(next);
}
