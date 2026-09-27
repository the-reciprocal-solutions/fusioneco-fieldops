import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/capture/capture_services.dart';
import '../../core/ocr/nameplate_reader.dart';
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

  @override
  void initState() {
    super.initState();
    _observedSerial.addListener(_scheduleAutosave);
    _observedTag.addListener(_scheduleAutosave);
    _notes.addListener(_scheduleAutosave);
    _flagReason.addListener(_scheduleAutosave);
    unawaited(_loadDraft().then((_) => _attachArPhoto()));
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
    if (!_hasDraftableContent) {
      await db.deleteDraft(widget.assetId);
      return;
    }
    await db.saveDraft(widget.assetId, {
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
            },
    });
  }

  /// FR-3.4/3.10 — the in-app camera (torch + level) rather than
  /// `PhotoCapture.takeJobPhoto`'s OS camera app, so both are available on
  /// the same shot instead of only in a browser-only system camera UI.
  Future<void> _addPhoto() async {
    if (_photos.length >= _maxPhotos) return;
    final photo = await Navigator.of(
      context,
    ).push<CapturedPhoto>(MaterialPageRoute(builder: (_) => const CameraCaptureScreen()));
    if (photo == null || !mounted) return;
    setState(() => _photos.add(photo));
    _scheduleAutosave();
  }

  Future<void> _annotatePhoto(int index) async {
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

  bool get _canSubmit => _result != null && !_submitting;

  Future<void> _submit() async {
    final result = _result;
    if (result == null) return;

    setState(() => _submitting = true);
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
        flagForReinspection: _flagReinspection,
        flagReason: _flagReinspection ? _emptyToNull(_flagReason.text) : null,
        claimedSerial: widget.claimedSerial,
        claimedTag: widget.claimedTag,
        arContext: widget.arHandoff?.toArContext(),
      );

      final write = await ref
          .read(fieldVerificationRepositoryProvider)
          .submit(widget.assetId, request);

      // Queued offline or sent live, the check itself now owns this
      // evidence — the draft that kept it alive across a crash has done its
      // job and would otherwise resurrect a completed check as "unfinished"
      // next time this asset is opened.
      _autosaveTimer?.cancel();
      await ref.read(offlineDbProvider).deleteDraft(widget.assetId);

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
        child: ListView(
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
              claimed: widget.claimedSerial,
              onScan: _scanningNameplate ? null : _scanNameplate,
              scanning: _scanningNameplate,
            ),
            const SizedBox(height: 12),
            _ObservedField(
              label: 'fieldVerify.observed_tag'.getString(context),
              controller: _observedTag,
              claimed: widget.claimedTag,
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
      bottomNavigationBar: SafeArea(
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
              AppText.caption(
                context.formatString('fieldVerify.claimed_value'.getString(context), [claimed!]),
                color: FeColors.ink2,
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
