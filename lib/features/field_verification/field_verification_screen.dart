import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/c2o/asset_detail.dart';
import '../../core/c2o/claims_freshness.dart';
import '../../core/c2o/route_progress.dart';
import '../../core/c2o/route_walk_context.dart';
import '../../core/capture/capture_services.dart';
import '../../core/ocr/nameplate_reader.dart';
import '../../core/offline/offline_db.dart' show CachedC2oAsset, OfflineDb;
import '../../core/offline/sync_client.dart' show kOfflineQueuedMessage;
import '../../data/field_verification_repository.dart';
import '../../domain/ar_handoff.dart';
import '../ar/widgets/ar_handoff_card.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/fe_header.dart';
import 'camera_capture_screen.dart';
import 'photo_annotation_screen.dart';
import 'voice_note_capture.dart';

const _maxPhotos = 8;

/// FR-3 — capturing the check. Reached from the asset detail screen's
/// "Verify Asset" button after a scan (FR-1) has shown what the register
/// claims (FR-2). This screen records what the technician actually observes:
/// FR-3.1 result, FR-3.2 observed serial/tag, FR-3.3 condition, FR-3.4
/// photos, FR-3.7 identity (from the session, never typed) and FR-3.9 GPS +
/// the floor already known from the scan. FR-3.5/3.6/3.11 (annotation, voice
/// notes, re-inspection flag) and FR-3.8/3.12 (signature, measurements) are
/// later phases — see the plan's own priority split.
class FieldVerificationScreen extends ConsumerStatefulWidget {
  const FieldVerificationScreen({
    super.key,
    required this.assetId,
    this.assetName,
    this.claimedSerial,
    this.claimedTag,
    this.floorId,
    this.arHandoff,
    this.route,
  });

  final String assetId;
  final String? assetName;
  final String? claimedSerial;
  final String? claimedTag;
  final String? floorId;

  /// Opened from the AR workspace's Verify mode (P-006): its location check
  /// is shown, its capture attached as a photo, and it is submitted as the
  /// request's `arContext` (docs/ar-bim-overlay.md §8). Null otherwise.
  final ArHandoff? arHandoff;

  /// FR-5.4 — the route this check was started from, if any. Kept in the
  /// draft too, so a check resumed from the Sync Center still carries it.
  final RouteWalkContext? route;

  @override
  ConsumerState<FieldVerificationScreen> createState() => _FieldVerificationScreenState();
}

class _FieldVerificationScreenState extends ConsumerState<FieldVerificationScreen> {
  final _nameplateReader = NameplateReader();
  final _location = LocationCapture();

  final _observedSerial = TextEditingController();
  final _observedTag = TextEditingController();
  final _notes = TextEditingController();
  final _flagReason = TextEditingController();

  VerificationResult? _result;
  ObservedCondition? _condition;
  final _photos = <CapturedPhoto>[];

  /// FR-3.11 — independent of [_result]: a check that could not be finished
  /// at all (blocked access, missing tool) has nothing to disagree with the
  /// register about, so it needs its own way to ask for a return visit.
  var _flagReinspection = false;

  CapturedLocation? _fix;
  var _locating = false;
  String? _locationError;

  var _scanningNameplate = false;
  var _submitting = false;

  /// FR-4.2 — continuous autosave so a force-quit or an OS kill never costs a
  /// half-filled check. Debounced rather than saved on every keystroke: a
  /// draft that's a few hundred milliseconds stale is fine, hitting sqlite on
  /// every character typed into Notes is not.
  Timer? _autosaveTimer;
  var _draftLoaded = false;

  /// FR-5.7 — the cached claims this check would be compared against, when
  /// they are past the agreed window. Non-null blocks the form until a
  /// refresh succeeds. Checked here, not at each entry point, so every way
  /// in (scan, search, route, BIM, AR, a resumed draft) hits it.
  CachedC2oAsset? _staleClaims;
  var _refreshingClaims = false;
  ClaimsRefreshOutcome? _refreshOutcome;

  /// What the register claims, shown beside the observed fields and sent
  /// with the check. Starts as what the opening screen passed in; a refresh
  /// replaces it with the fresh claims, or the check would be compared
  /// against the very values the refresh replaced.
  late String? _claimedSerial = widget.claimedSerial;
  late String? _claimedTag = widget.claimedTag;
  late RouteWalkContext? _route = widget.route;

  @override
  void initState() {
    super.initState();
    _observedSerial.addListener(_scheduleAutosave);
    _observedTag.addListener(_scheduleAutosave);
    _notes.addListener(_scheduleAutosave);
    _flagReason.addListener(_scheduleAutosave);
    unawaited(_loadDraft().then((_) => _attachArPhoto()));
    unawaited(_checkClaimsAge());
  }

  Future<void> _checkClaimsAge() async {
    try {
      final cached = await ref.read(offlineDbProvider).getC2oAsset(widget.assetId);
      // Nothing cached (a BIM/AR asset never scanned): nothing stale to
      // compare against — the server checks the live register itself.
      if (cached == null || !claimsAreStale(cached) || !mounted) return;
      setState(() => _staleClaims = cached);
    } catch (_) {}
  }

  Future<void> _refreshClaims() async {
    final stale = _staleClaims;
    if (stale == null) return;
    setState(() {
      _refreshingClaims = true;
      _refreshOutcome = null;
    });
    final db = ref.read(offlineDbProvider);
    final ticks = ref.read(routePacksTickProvider.notifier);
    final outcome = await ref.read(claimsRefresherProvider).refresh(stale);
    final fresh = outcome == ClaimsRefreshOutcome.refreshed ? await db.getC2oAsset(widget.assetId) : null;
    // A route download changes route rows; let open route screens re-read.
    if (outcome == ClaimsRefreshOutcome.refreshed) ticks.state++;
    if (!mounted) return;
    final detail = fresh == null ? null : AssetDetail.fromClaims(fresh.claims);
    setState(() {
      _refreshingClaims = false;
      _refreshOutcome = outcome;
      if (fresh != null) {
        _staleClaims = null;
        if (detail != null) {
          _claimedSerial = detail.serialNumber;
          _claimedTag = detail.assetReferenceId ?? detail.supplierTagNumber;
        }
      }
    });
    if (fresh != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('fieldVerify.claims_refreshed'.getString(context))),
      );
    }
  }

  /// The AR capture joins the photos once (after a restored draft, which may
  /// already hold it under the same `ar-…` name).
  Future<void> _attachArPhoto() async {
    final photo = await arHandoffPhoto(widget.arHandoff);
    if (photo == null || !mounted) return;
    if (_photos.any((p) => p.fileName == photo.fileName) || _photos.length >= _maxPhotos) return;
    setState(() => _photos.insert(0, photo));
    _scheduleAutosave();
  }

  @override
  void dispose() {
    // A pending debounce still means unsaved edits — flush them rather than
    // just cancelling, or backing out right after typing (well within the
    // 600ms window) would silently drop what was just entered.
    if (_autosaveTimer?.isActive ?? false) {
      _autosaveTimer!.cancel();
      unawaited(_saveDraft());
    }
    _nameplateReader.dispose();
    _observedSerial.dispose();
    _observedTag.dispose();
    _notes.dispose();
    _flagReason.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    final draft = await ref.read(offlineDbProvider).getDraft(widget.assetId);
    if (!mounted) return;
    if (draft == null) {
      // Nothing to restore — but the load attempt is done, so autosave can
      // switch on. Without this, a brand new draft (the common case: no
      // prior crash) would leave `_draftLoaded` false forever and every
      // future edit on this screen would silently never be saved.
      setState(() => _draftLoaded = true);
      return;
    }
    final payload = draft.payload;

    final result = payload['result'] as String?;
    final condition = payload['condition'] as String?;
    final photos = (payload['photos'] as List?) ?? const [];
    final fix = payload['fix'] as Map<String, dynamic>?;

    setState(() {
      _result = result == null ? null : VerificationResult.values.byName(result);
      _condition = condition == null ? null : ObservedCondition.values.byName(condition);
      _observedSerial.text = payload['observedSerial'] as String? ?? '';
      _observedTag.text = payload['observedTag'] as String? ?? '';
      _notes.text = payload['notes'] as String? ?? '';
      _flagReinspection = payload['flagForReinspection'] as bool? ?? false;
      _flagReason.text = payload['flagReason'] as String? ?? '';
      _route ??= RouteWalkContext.fromJson(payload['routeContext']);
      _photos
        ..clear()
        ..addAll(
          photos.map(
            (p) => CapturedPhoto(
              bytes: base64Decode(p['bytesBase64'] as String),
              fileName: p['fileName'] as String,
            ),
          ),
        );
      if (fix != null) {
        _fix = CapturedLocation(
          latitude: fix['latitude'] as double,
          longitude: fix['longitude'] as double,
          city: fix['city'] as String?,
          district: fix['district'] as String?,
          accuracyMeters: (fix['accuracyMeters'] as num?)?.toDouble(),
        );
      }
      _draftLoaded = true;
    });
  }

  /// Skips writing an all-empty draft — nothing worth surviving a crash for,
  /// and it would otherwise leave a phantom "resume?" row for every asset a
  /// technician merely opened and backed out of.
  bool get _hasDraftableContent =>
      _result != null ||
      _condition != null ||
      _observedSerial.text.trim().isNotEmpty ||
      _observedTag.text.trim().isNotEmpty ||
      _notes.text.trim().isNotEmpty ||
      _flagReason.text.trim().isNotEmpty ||
      _flagReinspection ||
      _photos.isNotEmpty ||
      _fix != null;

  void _scheduleAutosave() {
    // Ignore the burst of listener callbacks `_loadDraft`'s own setState
    // fires while populating the controllers — that would just resave the
    // draft it was reading a moment ago.
    if (!_draftLoaded) return;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 600), _saveDraft);
  }

  Future<void> _saveDraft() async {
    if (!mounted) return;
    final db = ref.read(offlineDbProvider);
    // Read now, not after the await: the last save runs from dispose(), and
    // ref is unusable once the screen is gone.
    final bus = ref.read(queueBusProvider);
    if (!_hasDraftableContent) {
      await db.deleteDraft(widget.assetId);
      bus.notify();
      return;
    }
    await db.saveDraft(widget.assetId, {
      // FR-4.10 — so the Sync Center can name this draft and reopen the form
      // with the same claims; the form itself never reads these back.
      'assetName': widget.assetName,
      'claimedSerial': _claimedSerial,
      'claimedTag': _claimedTag,
      'floorId': widget.floorId,
      'routeContext': ?_route?.toJson(),
      'result': _result?.name,
      'condition': _condition?.name,
      'observedSerial': _observedSerial.text,
      'observedTag': _observedTag.text,
      'notes': _notes.text,
      'flagForReinspection': _flagReinspection,
      'flagReason': _flagReason.text,
      'photos': [
        for (final p in _photos)
          {'bytesBase64': base64Encode(p.bytes), 'fileName': p.fileName},
      ],
      'fix': _fix == null
          ? null
          : {
              'latitude': _fix!.latitude,
              'longitude': _fix!.longitude,
              'city': _fix!.city,
              'district': _fix!.district,
              'accuracyMeters': _fix!.accuracyMeters,
            },
    });
    // FR-4.10 — drafts are not queue rows, so nudge the bus by hand: the
    // "left on this device" count (dashboard card, Sync Center) re-reads.
    bus.notify();
  }

  /// FR-3.4/3.10 — the in-app camera (torch + level) rather than
  /// `PhotoCapture.takeJobPhoto`'s OS camera app, so both are available on
  /// the same shot instead of only in a browser-only system camera UI.
  Future<void> _addPhoto() async {
    if (_photos.length >= _maxPhotos) return;
    _dropFocus();
    final photo = await Navigator.of(
      context,
    ).push<CapturedPhoto>(MaterialPageRoute(builder: (_) => const CameraCaptureScreen()));
    if (photo == null || !mounted) return;
    setState(() => _photos.add(photo));
    _scheduleAutosave();
  }

  /// A popped route hands focus back to whichever field last had it, so a
  /// field typed in before the camera/annotation screen re-opened the
  /// keyboard on return. Unfocusing the focused field itself (not the
  /// route's FocusScope, which keeps the field in its own history) clears
  /// that history, so there is nothing left to restore.
  void _dropFocus() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _annotatePhoto(int index) async {
    _dropFocus();
    final annotated = await Navigator.of(context).push<CapturedPhoto>(
      MaterialPageRoute(builder: (_) => PhotoAnnotationScreen(photo: _photos[index])),
    );
    if (annotated != null && mounted) {
      setState(() => _photos[index] = annotated);
      _scheduleAutosave();
    }
  }

  void _removePhoto(int index) {
    setState(() => _photos.removeAt(index));
    _scheduleAutosave();
  }

  void _setResult(VerificationResult result) {
    setState(() => _result = result);
    _scheduleAutosave();
  }

  void _setCondition(ObservedCondition condition) {
    setState(() => _condition = condition);
    _scheduleAutosave();
  }

  void _setFlagReinspection(bool value) {
    setState(() => _flagReinspection = value);
    _scheduleAutosave();
  }

  Future<void> _scanNameplate() async {
    _dropFocus();
    final shot = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 2000,
      imageQuality: 90,
    );
    if (shot == null || !mounted) return;
    setState(() => _scanningNameplate = true);
    try {
      final fields = await _nameplateReader.read(shot.path);
      if (!mounted) return;
      if (fields.serial != null && fields.serial!.isNotEmpty) {
        _observedSerial.text = fields.serial!;
      }
    } catch (_) {
      // No recognized text is not an error — the field is still there to
      // fill in by hand, same fallback as FR-1.5's own OCR screen.
    } finally {
      if (mounted) setState(() => _scanningNameplate = false);
    }
  }

  Future<void> _captureLocation() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final fix = await _location.current();
      if (mounted) {
        setState(() => _fix = fix);
        _scheduleAutosave();
      }
    } on CaptureFailure catch (e) {
      if (mounted) setState(() => _locationError = e.message);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  bool get _canSubmit => _result != null && !_submitting && _staleClaims == null;

  /// FR-4.8 — what the asset screen showed for this asset: the cached copy
  /// it was opened from. Read at submit (= capture time; a queued check
  /// keeps this body), and best-effort: no cached copy just means fewer
  /// fields are compared on arrival.
  Future<Map<String, Object?>> _shownRegister() async {
    try {
      final cached = await ref.read(offlineDbProvider).getC2oAsset(widget.assetId);
      final asset = cached?.claims['asset'];
      return captureClaimsFrom(asset is Map ? Map<String, dynamic>.from(asset) : null);
    } catch (_) {
      return const {};
    }
  }

  Future<void> _submit() async {
    final result = _result;
    if (result == null) return;

    setState(() => _submitting = true);
    // Read up front: over a weak link the send can take a while, and a
    // technician who backs out meanwhile disposes this screen — after which
    // `ref` throws. That used to skip the draft delete below, leaving a check
    // that was queued AND listed as "unfinished" (seen on device 2026-10-08).
    final db = ref.read(offlineDbProvider);
    final bus = ref.read(queueBusProvider);
    final repository = ref.read(fieldVerificationRepositoryProvider);
    try {
      final request = FieldVerificationRequest(
        result: result,
        observedSerial: _emptyToNull(_observedSerial.text),
        observedTag: _emptyToNull(_observedTag.text),
        observedCondition: _condition,
        notes: _emptyToNull(_notes.text),
        photos: [
          for (final p in _photos)
            VerificationPhoto(bytes: p.bytes, fileName: p.fileName, contentType: p.mimeType),
        ],
        latitude: _fix?.latitude,
        longitude: _fix?.longitude,
        gpsAccuracy: _fix?.accuracyMeters,
        flagForReinspection: _flagReinspection,
        flagReason: _flagReinspection ? _emptyToNull(_flagReason.text) : null,
        claimedSerial: _claimedSerial,
        claimedTag: _claimedTag,
        shownRegister: await _shownRegister(),
        arContext: widget.arHandoff?.toArContext(),
        routeContext: _route,
      );

      final write = await repository.submit(widget.assetId, request);

      // Queued offline or sent live, the check itself now owns this
      // evidence — the draft that kept it alive across a crash has done its
      // job and would otherwise resurrect a completed check as "unfinished"
      // next time this asset is opened.
      _autosaveTimer?.cancel();
      await db.deleteDraft(widget.assetId);
      await _markChecked(db, result);
      bus.notify();

      if (!mounted) return;
      final message = write.synced
          ? 'fieldVerify.submitted'.getString(context)
          : kOfflineQueuedMessage;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      context.pop(true);
    } catch (_) {
      if (mounted) _showError('fieldVerify.submit_failed'.getString(context));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// FR-5.3 — the route count moves now, not at the next pack download.
  /// Best effort: the check is already safe, and a failure here only means
  /// the count waits for that download.
  Future<void> _markChecked(OfflineDb db, VerificationResult result) async {
    try {
      final cached = await db.getC2oAsset(widget.assetId);
      if (cached == null) return;
      await db.upsertC2oAsset(
        withLocalVerificationStatus(cached, verificationStatusForResult(result.name)),
      );
    } catch (_) {}
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String? _emptyToNull(String v) => v.trim().isEmpty ? null : v.trim();

  @override
  Widget build(BuildContext context) {
    final technicianName = ref.watch(authControllerProvider).session?.name;

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        showBack: true,
        title: widget.assetName ?? 'fieldVerify.title'.getString(context),
      ),
      body: SafeArea(
        child: _staleClaims != null
            ? _StaleClaimsBlock(
                cachedAt: _staleClaims!.cachedAt,
                refreshing: _refreshingClaims,
                outcome: _refreshOutcome,
                onRefresh: _refreshClaims,
              )
            : ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            if (widget.arHandoff != null) ...[
              ArHandoffCard(handoff: widget.arHandoff!),
              const SizedBox(height: 20),
            ],
            _SectionLabel('fieldVerify.result'.getString(context)),
            const SizedBox(height: 10),
            _ResultGrid(value: _result, onChanged: _setResult),
            const SizedBox(height: 24),

            _SectionLabel('fieldVerify.observed'.getString(context)),
            const SizedBox(height: 10),
            _ObservedField(
              label: 'fieldVerify.observed_serial'.getString(context),
              controller: _observedSerial,
              claimed: _claimedSerial,
              onScan: _scanningNameplate ? null : _scanNameplate,
              scanning: _scanningNameplate,
            ),
            const SizedBox(height: 12),
            _ObservedField(
              label: 'fieldVerify.observed_tag'.getString(context),
              controller: _observedTag,
              claimed: _claimedTag,
            ),
            const SizedBox(height: 24),

            _SectionLabel('fieldVerify.condition'.getString(context)),
            const SizedBox(height: 10),
            _ConditionRow(value: _condition, onChanged: _setCondition),
            const SizedBox(height: 24),

            _SectionLabel(
              '${'fieldVerify.photos'.getString(context)} (${_photos.length}/$_maxPhotos)',
            ),
            const SizedBox(height: 10),
            _PhotoGrid(
              photos: _photos,
              onAdd: _photos.length >= _maxPhotos ? null : _addPhoto,
              onRemove: _removePhoto,
              onAnnotate: _annotatePhoto,
            ),
            const SizedBox(height: 24),

            _SectionLabel('fieldVerify.notes'.getString(context)),
            const SizedBox(height: 10),
            TextField(
              controller: _notes,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'fieldVerify.notes_hint'.getString(context),
                filled: true,
                fillColor: FeColors.panel,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: FeColors.line),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const VoiceNoteCapture(),
            const SizedBox(height: 24),

            _ReinspectionCard(
              flagged: _flagReinspection,
              onChanged: _setFlagReinspection,
              reasonController: _flagReason,
            ),
            const SizedBox(height: 24),

            _SectionLabel('fieldVerify.location'.getString(context)),
            const SizedBox(height: 10),
            _LocationCard(
              fix: _fix,
              locating: _locating,
              error: _locationError,
              onCapture: _captureLocation,
            ),
            const SizedBox(height: 16),

            if (technicianName != null)
              Row(
                children: [
                  const Icon(LucideIcons.userCheck, size: 14, color: FeColors.ink2),
                  const SizedBox(width: 6),
                  AppText.caption(
                    context.formatString('fieldVerify.recorded_as'.getString(context), [technicianName]),
                    color: FeColors.ink2,
                  ),
                ],
              ),
          ],
        ),
      ),
      bottomNavigationBar: _staleClaims != null ? null : SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _canSubmit ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: FeColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                    )
                  : AppText.label(
                      'fieldVerify.submit'.getString(context),
                      color: Colors.white,
                      weight: FontWeight.w700,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// FR-5.7 — shown instead of the form while the claims are too old. Any
/// draft for this asset is untouched underneath and comes back after the
/// refresh.
class _StaleClaimsBlock extends StatelessWidget {
  const _StaleClaimsBlock({
    required this.cachedAt,
    required this.refreshing,
    required this.outcome,
    required this.onRefresh,
  });

  final DateTime cachedAt;
  final bool refreshing;
  final ClaimsRefreshOutcome? outcome;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final age = DateTime.now().difference(cachedAt);
    final ageText = age.inDays >= 1
        ? context.formatString(
            'fieldVerify.claims_age_days'.getString(context),
            [age.inDays],
          )
        : context.formatString(
            'fieldVerify.claims_age_hours'.getString(context),
            [age.inHours],
          );
    final error = switch (outcome) {
      ClaimsRefreshOutcome.failed =>
        'fieldVerify.claims_refresh_failed'.getString(context),
      ClaimsRefreshOutcome.noWayToRefresh =>
        'fieldVerify.claims_refresh_no_way'.getString(context),
      _ => null,
    };
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        const Icon(LucideIcons.clockAlert, size: 48, color: FeColors.warning),
        const SizedBox(height: 16),
        AppText.title(
          'fieldVerify.claims_stale_title'.getString(context),
          weight: FontWeight.w800,
          align: TextAlign.center,
        ),
        const SizedBox(height: 8),
        AppText.bodyMedium(
          context.formatString(
            'fieldVerify.claims_stale_body'.getString(context),
            [ageText],
          ),
          color: FeColors.ink2,
          align: TextAlign.center,
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: refreshing ? null : onRefresh,
            icon: refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(LucideIcons.refreshCw, size: 18),
            label: AppText.label(
              'fieldVerify.claims_refresh'.getString(context),
              color: Colors.white,
              weight: FontWeight.w700,
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 16),
          AppText.bodySmall(
            error,
            color: FeColors.danger,
            align: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      AppText.labelMedium(text.toUpperCase(), color: FeColors.ink2, weight: FontWeight.w800);
}

/// FR-3.1 — five large single-tap result buttons, gloved-hand sized.
class _ResultGrid extends StatelessWidget {
  const _ResultGrid({required this.value, required this.onChanged});

  final VerificationResult? value;
  final ValueChanged<VerificationResult> onChanged;

  static const _options = <(VerificationResult, IconData, Color)>[
    (VerificationResult.verified, LucideIcons.circleCheck, FeColors.success),
    (VerificationResult.mismatch, LucideIcons.circleAlert, FeColors.warning),
    (VerificationResult.missing, LucideIcons.circleX, FeColors.danger),
    (VerificationResult.damaged, LucideIcons.triangleAlert, FeColors.danger),
    (VerificationResult.inaccessible, LucideIcons.ban, FeColors.ink2),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (result, icon, color) in _options)
          _ResultTile(
            result: result,
            icon: icon,
            color: color,
            selected: value == result,
            onTap: () => onChanged(result),
          ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final VerificationResult result;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.of(context).size.width - 32 - 20) / 3;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: width.clamp(96, 160),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : FeColors.panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? color : FeColors.line, width: selected ? 2 : 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: selected ? color : FeColors.ink2),
            const SizedBox(height: 8),
            AppText.bodySmall(
              'fieldVerify.result_${result.name}'.getString(context),
              align: TextAlign.center,
              weight: selected ? FontWeight.w800 : FontWeight.w600,
              color: selected ? color : FeColors.ink,
            ),
          ],
        ),
      ),
    );
  }
}

/// FR-3.2 — an observed value field plus a one-tap "Same as claimed"
/// shortcut, and (on the serial field only) an OCR scan shortcut.
class _ObservedField extends StatelessWidget {
  const _ObservedField({
    required this.label,
    required this.controller,
    this.claimed,
    this.onScan,
    this.scanning = false,
  });

  final String label;
  final TextEditingController controller;
  final String? claimed;
  final VoidCallback? onScan;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            filled: true,
            fillColor: FeColors.panel,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: FeColors.line),
            ),
            suffixIcon: onScan == null
                ? null
                : IconButton(
                    icon: scanning
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.scanLine, size: 18),
                    tooltip: 'fieldVerify.scan_nameplate'.getString(context),
                    onPressed: onScan,
                  ),
          ),
        ),
        if (claimed != null && claimed!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              // Flexible + ellipsis: a long claimed id (e.g. a GUID tag)
              // otherwise overflowed the row and pushed the button off-screen.
              Flexible(
                child: AppText.caption(
                  context.formatString('fieldVerify.claimed_value'.getString(context), [claimed!]),
                  color: FeColors.ink2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => controller.text = claimed!,
                child: AppText.caption(
                  'fieldVerify.same_as_claimed'.getString(context),
                  color: FeColors.primary,
                  weight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// FR-3.3 — good / fair / poor / damaged.
class _ConditionRow extends StatelessWidget {
  const _ConditionRow({required this.value, required this.onChanged});

  final ObservedCondition? value;
  final ValueChanged<ObservedCondition> onChanged;

  static const _colors = {
    ObservedCondition.good: FeColors.success,
    ObservedCondition.fair: FeColors.warning,
    ObservedCondition.poor: FeColors.danger,
    ObservedCondition.damaged: FeColors.danger,
  };

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in ObservedCondition.values)
          ChoiceChip(
            label: Text('fieldVerify.condition_${c.name}'.getString(context)),
            selected: value == c,
            onSelected: (_) => onChanged(c),
            selectedColor: _colors[c]!.withValues(alpha: 0.16),
            labelStyle: TextStyle(
              color: value == c ? _colors[c] : FeColors.ink,
              fontWeight: value == c ? FontWeight.w800 : FontWeight.w500,
            ),
            side: BorderSide(color: value == c ? _colors[c]! : FeColors.line),
            backgroundColor: FeColors.panel,
          ),
      ],
    );
  }
}

/// FR-3.4 — up to 8 in-app photos, each already downscaled to 1600px by
/// `PhotoCapture.takeJobPhoto` before it ever reaches this grid.
class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid({
    required this.photos,
    required this.onAdd,
    required this.onRemove,
    required this.onAnnotate,
  });

  final List<CapturedPhoto> photos;
  final VoidCallback? onAdd;
  final ValueChanged<int> onRemove;

  /// FR-3.5 — tapping a captured photo (not the add tile, not the X) opens
  /// it for annotation.
  final ValueChanged<int> onAnnotate;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: photos.length + (onAdd != null ? 1 : 0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemBuilder: (context, i) {
        if (i == photos.length) {
          return InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              decoration: BoxDecoration(
                color: FeColors.panel,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: FeColors.line, style: BorderStyle.solid),
              ),
              child: const Icon(LucideIcons.camera, color: FeColors.ink2),
            ),
          );
        }
        final photo = photos[i];
        return GestureDetector(
          onTap: () => onAnnotate(i),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(photo.bytes, fit: BoxFit.cover),
              ),
              Positioned(
                bottom: 2,
                left: 2,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(LucideIcons.pencil, size: 11, color: Colors.white),
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: InkWell(
                  onTap: () => onRemove(i),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(LucideIcons.x, size: 12, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// FR-3.11 — a technician who could not finish the check flips this on to
/// ask for the asset to be requeued for a return visit, with an optional
/// reason (blocked access, no ladder, room locked, etc.).
class _ReinspectionCard extends StatelessWidget {
  const _ReinspectionCard({
    required this.flagged,
    required this.onChanged,
    required this.reasonController,
  });

  final bool flagged;
  final ValueChanged<bool> onChanged;
  final TextEditingController reasonController;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: flagged ? FeColors.warning.withValues(alpha: 0.08) : FeColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: flagged ? FeColors.warning : FeColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => onChanged(!flagged),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(
                  LucideIcons.flag,
                  size: 18,
                  color: flagged ? FeColors.warning : FeColors.ink2,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AppText.bodySmall(
                    'fieldVerify.reinspection_flag'.getString(context),
                    weight: FontWeight.w700,
                    color: flagged ? FeColors.warning : FeColors.ink,
                  ),
                ),
                Switch(
                  value: flagged,
                  onChanged: onChanged,
                  activeThumbColor: FeColors.warning,
                ),
              ],
            ),
          ),
          if (flagged) ...[
            const SizedBox(height: 10),
            TextField(
              controller: reasonController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'fieldVerify.reinspection_reason_hint'.getString(context),
                filled: true,
                fillColor: FeColors.page,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: FeColors.line),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// FR-3.9 — GPS fix with accuracy context; the floor half of "GPS + floor"
/// is already known from the route (`AssetDetail.floorId`) rather than
/// captured here.
class _LocationCard extends StatelessWidget {
  const _LocationCard({
    required this.fix,
    required this.locating,
    required this.error,
    required this.onCapture,
  });

  final CapturedLocation? fix;
  final bool locating;
  final String? error;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: FeColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: FeColors.line),
      ),
      child: Row(
        children: [
          Icon(
            fix != null ? LucideIcons.mapPin : LucideIcons.locateFixed,
            size: 18,
            color: fix != null ? FeColors.success : FeColors.ink2,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: fix == null
                ? AppText.bodySmall(
                    error ?? 'fieldVerify.location_prompt'.getString(context),
                    color: error != null ? FeColors.danger : FeColors.ink2,
                  )
                : AppText.bodySmall(
                    fix!.placeLabel ??
                        '${fix!.latitude.toStringAsFixed(5)}, ${fix!.longitude.toStringAsFixed(5)}',
                    weight: FontWeight.w700,
                  ),
          ),
          TextButton(
            onPressed: locating ? null : onCapture,
            child: locating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : AppText.bodySmall(
                    (fix == null ? 'fieldVerify.capture_location' : 'fieldVerify.recapture')
                        .getString(context),
                    color: FeColors.primary,
                    weight: FontWeight.w700,
                  ),
          ),
        ],
      ),
    );
  }
}
