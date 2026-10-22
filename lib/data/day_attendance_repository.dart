// ignore_for_file: prefer_initializing_formals — named params cannot be private
import 'package:uuid/uuid.dart';

import '../core/attendance/day_rules.dart';
import '../core/network/api_client.dart';
import '../core/network/api_exception.dart';
import '../core/network/envelope.dart';
import '../core/offline/flush_policy.dart';
import '../core/offline/offline_db.dart';
import '../core/offline/sync_client.dart';
import '../core/capture/capture_media.dart';
import '../core/capture/capture_photo.dart';
import '../domain/day_attendance.dart';
import '../domain/capture.dart';

/// Daily attendance data access (docs/daily-attendance-shift-plan.md): start my
/// day / end my day, for payroll.
///
/// **Phone first, outbox
/// first:** a tap writes the picture to disk, then the day row, then parks the
/// request in the offline queue and starts a flush in the background. Nothing
/// waits on the network, so it works the same in a basement with no signal, and
/// the server judges late or not from the TAP time, never from when the request
/// arrived.
///
/// "Today" (the shift and the moments the card counts to) is cached from the
/// server and rolled forward by the shift's own rules when the phone has been
/// offline across midnight, so the card is right the next morning with no signal.
class DayAttendanceRepository {
  DayAttendanceRepository({
    required SyncClient sync,
    required ApiClient api,
    required DayAttendanceStore store,
    required CaptureMedia media,
    Future<String?> Function()? deviceId,
    Future<Set<String>> Function(String entityType)? pendingIds,
    String? appVersion,
    DateTime Function()? now,
    Uuid? uuid,
  }) : _sync = sync,
       _api = api,
       _store = store,
       _media = media,
       _deviceId = deviceId,
       _pendingIds = pendingIds,
       _appVersion = appVersion,
       _now = now ?? DateTime.now,
       _uuid = uuid ?? const Uuid();

  /// Queue entity types: one per end, so a replay hook knows which end it is.
  static const inEntityType = 'DayIn';
  static const outEntityType = 'DayOut';

  static const _todayUrl = '/api/fm/technicians/me/day/today';
  static const _checkInUrl = '/api/fm/technicians/me/day/check-in';
  static const _checkOutUrl = '/api/fm/technicians/me/day/check-out';

  final SyncClient _sync;
  final ApiClient _api;
  final DayAttendanceStore _store;
  final CaptureMedia _media;
  final Future<String?> Function()? _deviceId;
  final Future<Set<String>> Function(String entityType)? _pendingIds;
  final String? _appVersion;
  final DateTime Function() _now;
  final Uuid _uuid;

  /// The queue ids: `<userId>|<date>|in` and `<userId>|<date>|out`.
  static String queueId(String userId, String date, {required bool isStart}) => '$userId|$date|${isStart ? 'in' : 'out'}';

  /// The picture for the local UI.
  CaptureMedia get media => _media;

  Future<String?> _device() async {
    try {
      return await _deviceId?.call();
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ reads

  /// The technician's own start / end of [date], from the phone.
  Future<DayLocal?> localFor(String userId, String date) async {
    final row = await _store.getDayRow(userId, 'rec:$date');
    return row == null ? null : DayLocal.fromJson(row);
  }

  /// The cached description of today, rolled forward if the phone has been
  /// offline across a day. Null when the phone has never heard of a shift.
  Future<DayToday?> cachedToday(String userId) async {
    final row = await _store.getDayRow(userId, 'today');
    if (row == null) return null;
    return rollForward(DayToday.fromCache(row), _now());
  }

  /// Asks the server for today and caches the answer; offline, answers from the
  /// cache. Also merges the server's day record into the phone's copy, which is
  /// how late / absent / worked minutes reach the card.
  Future<DayToday?> loadToday(String userId) async {
    try {
      final res = await _api.get(_todayUrl);
      final data = unwrap(res.data);
      if (data is Map) {
        final today = DayToday.fromServer(Map<String, dynamic>.from(data), fetchedAt: _now());
        await _store.putDayRow(userId, 'today', today.toJson());
        final rec = today.serverRecord;
        if (today.hasShift && today.date != null && rec != null) {
          await _mergeServerRecord(userId, today.date!, rec, today);
        }
        return today;
      }
    } on ApiFailure {
      // Offline or refused: the cached day is what we have.
    }
    return cachedToday(userId);
  }

  // ----------------------------------------------------------------- writes

  Future<void> _save(DayLocal d) => _store.putDayRow(d.userId, 'rec:${d.date}', d.toJson());

  /// Start my day. Returns as soon as it is on the phone and queued.
  ///
  /// [at] is the tap time; it defaults to now. A job check-in that also starts
  /// the day passes its own tap time so the two agree.
  Future<DayLocal> startDay({
    required String userId,
    required DayToday today,
    required CaptureFix fix,
    CapturePhoto? photo,
    String? reason,
    DateTime? at,
  }) async {
    final date = today.date;
    if (date == null) throw StateError('No shift date: the day cannot be started.');
    final id = _uuid.v4();
    final tap = at ?? _now();

    // 1. The picture to disk first.
    final photoPath = photo == null ? null : await _media.save(id, photo.bytes, isCheckIn: true);

    // 2. The day row. From here the card says "On duty".
    final existing = await localFor(userId, date);
    final local = (existing ?? DayLocal(userId: userId, date: date)).copyWith(
      shiftName: today.shift?.name,
      inAt: tap,
      inFix: fix,
      inPhotoPath: photoPath,
      inReason: reason,
      inSync: SendState.queued,
      clearInIssue: true,
      status: estimateStatus(today, tap),
      lateMinutes: estimateLateMinutes(today, tap),
    );
    await _save(local);

    // 3. The queued request. The picture rides as a placeholder swapped for the uploaded URL at flush time.
    final placeholder = photo == null ? null : '__pending_photo_${_uuid.v4()}__';
    await _sync.queueRequest(
      'POST',
      _checkInUrl,
      data: buildDayCheckInBody(
        eventId: id,
        at: tap,
        queuedAt: _now(),
        fix: fix,
        photoPlaceholder: placeholder,
        reason: reason,
        deviceId: await _device(),
        appVersion: _appVersion,
      ),
      label: 'Start of day',
      attachments: [
        if (photo != null && placeholder != null)
          QueuedAttachment(bytes: photo.bytes, fileName: photo.fileName, placeholder: placeholder, field: 'image'),
      ],
      entityType: inEntityType,
      entityId: queueId(userId, date, isStart: true),
    );
    return local;
  }

  /// End my day. Same order as [startDay]; carries a copy of the start so a lost start request never loses the day.
  Future<DayLocal> endDay({
    required String userId,
    required DayLocal local,
    required CaptureFix fix,
    CapturePhoto? photo,
    String? reason,
  }) async {
    final startAt = local.inAt;
    if (startAt == null) throw StateError('The day was not started.');
    final id = _uuid.v4();
    final tap = _now();

    final photoPath = photo == null ? null : await _media.save(id, photo.bytes, isCheckIn: false);
    final ended = local.copyWith(
      outAt: tap,
      outFix: fix,
      outPhotoPath: photoPath,
      outReason: reason,
      outSync: SendState.queued,
      clearOutIssue: true,
    );
    await _save(ended);

    final placeholder = photo == null ? null : '__pending_photo_${_uuid.v4()}__';
    await _sync.queueRequest(
      'POST',
      _checkOutUrl,
      data: buildDayCheckOutBody(
        eventId: id,
        date: local.date,
        at: tap,
        queuedAt: _now(),
        fix: fix,
        startEventId: _uuid.v4(),
        startAt: startAt,
        startFix: local.inFix ?? const CaptureFix.none(),
        startReason: local.inReason,
        photoPlaceholder: placeholder,
        reason: reason,
        deviceId: await _device(),
        appVersion: _appVersion,
      ),
      label: 'End of day',
      attachments: [
        if (photo != null && placeholder != null)
          QueuedAttachment(bytes: photo.bytes, fileName: photo.fileName, placeholder: placeholder, field: 'image'),
      ],
      entityType: outEntityType,
      entityId: queueId(userId, local.date, isStart: false),
    );
    return ended;
  }

  // ------------------------------------------------------- replay callbacks

  ({String userId, String date})? _parse(String entityId) {
    final parts = entityId.split('|');
    if (parts.length < 3) return null;
    return (userId: parts[0], date: parts[1]);
  }

  /// A queued end reached the server (registered per entity type).
  Future<void> afterReplay(String entityId, {required bool isStart}) async {
    final k = _parse(entityId);
    if (k == null) return;
    final d = await localFor(k.userId, k.date);
    if (d == null) return;
    await _save(
      isStart ? d.copyWith(inSync: SendState.synced, clearInIssue: true) : d.copyWith(outSync: SendState.synced, clearOutIssue: true),
    );
    // The server has judged the day now: bring back late / worked / status.
    await loadToday(k.userId);
  }

  /// A queued end failed on replay. Only a final refusal is shown; "no
  /// signal", "sign in again" and "server busy" stay quietly queued.
  Future<void> afterReplayFailed(String entityId, ReplayFailure failure, {required bool isStart}) async {
    if (failure.outcome != FlushOutcome.drop) return;
    final k = _parse(entityId);
    if (k == null) return;
    final d = await localFor(k.userId, k.date);
    if (d == null) return;
    final why = plainDayIssue(status: failure.status, code: failure.code);
    await _save(
      isStart ? d.copyWith(inSync: SendState.rejected, inIssue: why) : d.copyWith(outSync: SendState.rejected, outIssue: why),
    );
  }

  /// After the app was closed: the Android background engine may have sent queued
  /// ends with nobody listening, so the phone's copy still says "waiting". An end
  /// that is marked queued but is no longer in the queue either reached the
  /// server or was dropped; the server's own description of today settles which.
  /// Offline, nothing can be told, so nothing is changed.
  Future<void> reconcile(String userId) async {
    final pending = _pendingIds;
    if (pending == null) return;
    final cached = await _store.getDayRow(userId, 'today');
    final date = cached?['date'] as String?;
    if (date == null) return;
    final d = await localFor(userId, date);
    if (d == null) return;
    final waitingIn = await pending(inEntityType);
    final waitingOut = await pending(outEntityType);
    final lostIn = d.inSync == SendState.queued && !waitingIn.contains(queueId(userId, date, isStart: true));
    final lostOut = d.outSync == SendState.queued && !waitingOut.contains(queueId(userId, date, isStart: false));
    if (!lostIn && !lostOut) return;

    final today = await loadToday(userId); // merges what the server has
    if (today == null || today.date != date) return;
    final after = await localFor(userId, date);
    if (after == null) return;
    final serverRec = today.serverRecord;
    final stillIn = lostIn && after.inSync == SendState.queued;
    final stillOut = lostOut && after.outSync == SendState.queued;
    // loadToday answered but the server does not have this end: it was dropped.
    if (serverRec != null && (stillIn || stillOut)) {
      await _save(
        after.copyWith(
          inSync: stillIn ? SendState.rejected : null,
          inIssue: stillIn ? 'The server did not receive your start of day.' : null,
          outSync: stillOut ? SendState.rejected : null,
          outIssue: stillOut ? 'The server did not receive your end of day.' : null,
        ),
      );
    }
  }

  // ----------------------------------------------------------- server merge

  Future<void> _mergeServerRecord(String userId, String date, Map<String, dynamic> server, DayToday today) async {
    final local = await localFor(userId, date);
    final merged = mergeServerDay(userId: userId, date: date, local: local, server: server, shiftName: today.shift?.name);
    if (merged != null) await _save(merged);
  }
}

/// Pure merge of the server's day record into the phone's copy (or adoption of
/// a day started on another phone).
///
/// Rules: an end still queued on the phone is never overwritten (the phone is
/// ahead of the server); an end the server has and the phone thought queued
/// becomes `synced`; status, late minutes, worked minutes, flags and the review
/// state always come from the server. Public for tests.
DayLocal? mergeServerDay({
  required String userId,
  required String date,
  required DayLocal? local,
  required Map<String, dynamic> server,
  String? shiftName,
}) {
  final status = server['status'] as String?;
  final flags = [for (final f in (server['flags'] as List? ?? const [])) '$f'];
  final review = server['reviewStatus'] as String?;
  final late = (server['lateMinutes'] as num?)?.toInt();
  final worked = (server['workedMinutes'] as num?)?.toInt();
  final serverIn = server['inAt'] == null ? null : DateTime.tryParse('${server['inAt']}')?.toLocal();
  final serverOut = server['outAt'] == null ? null : DateTime.tryParse('${server['outAt']}')?.toLocal();

  if (local != null) {
    return local.copyWith(
      shiftName: shiftName,
      status: status,
      lateMinutes: late,
      workedMinutes: worked,
      flags: flags,
      reviewStatus: review,
      inSync: serverIn != null && local.inSync == SendState.queued ? SendState.synced : null,
      outSync: serverOut != null && local.outSync == SendState.queued ? SendState.synced : null,
    );
  }
  // Nothing on this phone. Only a day somebody actually started is worth keeping.
  if (serverIn == null) return null;
  CaptureFix fixOf(String p) => CaptureFix(
    kind: FixKind.fromWire(server['${p}FixKind'] as String?),
    lat: asDouble(server['${p}Lat']),
    lng: asDouble(server['${p}Lng']),
    accuracyM: asDouble(server['${p}AccuracyM']),
  );
  return DayLocal(
    userId: userId,
    date: date,
    shiftName: shiftName,
    inAt: serverIn,
    inFix: fixOf('in'),
    inReason: server['inReason'] as String?,
    outAt: serverOut,
    outFix: serverOut == null ? null : fixOf('out'),
    outReason: server['outReason'] as String?,
    inSync: SendState.synced,
    outSync: serverOut == null ? SendState.none : SendState.synced,
    status: status,
    lateMinutes: late,
    workedMinutes: worked,
    flags: flags,
    reviewStatus: review,
  );
}
