import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../app/router.dart';
import '../../core/capture/capture_services.dart';
import '../../core/network/api_exception.dart';
import '../../core/snag/snag_rules.dart';
import '../../data/snag_repository.dart';
import '../../domain/ar_handoff.dart';
import '../../domain/snag.dart';
import '../../state/snag_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/tech_popup.dart';
import '../../widgets/voice_waveform.dart';
import '../ar/widgets/ar_handoff_card.dart';
import '../field_verification/camera_capture_screen.dart';
import '../field_verification/photo_annotation_screen.dart';
import 'snag_plan_screen.dart';
import 'widgets/snag_sheets.dart';
import 'widgets/snag_visuals.dart';

/// UC-5 — one snag with full detail, usually raised from context: an asset
/// page ("the insulation on this chiller is torn") or a work order ("found
/// while doing this PM, but not part of it"). Context arrives pre-filled.
///
/// A defect found during a PM is raised *here*, as its own snag linked to
/// the work order — never folded into the work order's scope, which is how
/// out-of-scope defects stop being verified (docs/snag-assistant.md P7).
class SnagRaiseScreen extends ConsumerStatefulWidget {
  const SnagRaiseScreen({
    super.key,
    this.buildingId,
    this.floorId,
    this.assetId,
    this.assetName,
    this.assetReferenceId,
    this.workOrderId,
    this.contextWire,
    this.arHandoff,
  });

  final String? buildingId;
  final String? floorId;
  final String? assetId;
  final String? assetName;
  final String? assetReferenceId;
  final String? workOrderId;
  final String? contextWire;

  /// Raised from the AR workspace (P-006, AR-47): the AR capture becomes the
  /// first photo and the element (name + GlobalId) and alignment fill the
  /// "exact spot" line. `SnagDraft` has no structured AR field yet, so the
  /// GlobalId travels in that text until the snag model grows one.
  final ArHandoff? arHandoff;

  @override
  ConsumerState<SnagRaiseScreen> createState() => _SnagRaiseScreenState();
}

class _SnagRaiseScreenState extends ConsumerState<SnagRaiseScreen> {
  final _photos = <CapturedPhoto>[];
  late SnagContext _context;
  String? _buildingId;
  SnagFloor? _floor;
  SnagSpace? _space;
  SnagPin? _pin;
  String _trade = kSnagTrades.first;
  SnagPriority _priority = SnagPriority.minor;
  String _issueType = 'defect';
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _spot = TextEditingController();
  final _responsible = TextEditingController();
  DateTime? _due;
  SnagSuggestion? _suggestion;
  var _assisting = false;
  var _saving = false;

  final _voiceCapture = VoiceCapture();
  VoiceRecording? _voice;
  var _recording = false;
  Stream<Amplitude>? _amplitude;

  @override
  void initState() {
    super.initState();
    _context = widget.contextWire != null
        ? SnagContext.parse(widget.contextWire)
        : (widget.workOrderId != null || widget.assetId != null
              ? SnagContext.operations
              : SnagContext.fmTakeover);
    _buildingId = widget.buildingId ?? ref.read(snagBuildingIdProvider);
    final ar = widget.arHandoff;
    if (ar != null) {
      // After the first frame: the words are translated, and a translation
      // can't be read from initState.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _spot.text.isNotEmpty) return;
        _spot.text = ar.summaryLine(
          elementWord: 'ar.handoff.element_word'.getString(context),
          aligned: 'ar.handoff.aligned_word'.getString(context),
        );
      });
      unawaited(_attachArPhoto(ar));
    }
  }

  Future<void> _attachArPhoto(ArHandoff ar) async {
    final photo = await arHandoffPhoto(ar);
    if (photo == null || !mounted) return;
    if (_photos.any((p) => p.fileName == photo.fileName)) return;
    setState(() => _photos.insert(0, photo));
  }

  @override
  void dispose() {
    if (_recording) _voiceCapture.cancel();
    _voiceCapture.dispose();
    _title.dispose();
    _description.dispose();
    _spot.dispose();
    _responsible.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final photo = await Navigator.of(context).push<CapturedPhoto>(
      MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
    );
    if (photo != null && mounted) setState(() => _photos.add(photo));
  }

  Future<void> _pickPhoto() async {
    final photo = await PhotoCapture().pickFromGallery();
    if (photo != null && mounted) setState(() => _photos.add(photo));
  }

  Future<void> _annotate(int i) async {
    final marked = await Navigator.of(context).push<CapturedPhoto>(
      MaterialPageRoute(
        builder: (_) => PhotoAnnotationScreen(photo: _photos[i]),
      ),
    );
    if (marked != null && mounted) setState(() => _photos[i] = marked);
  }

  Future<void> _pickRoom(SnagLocationTree tree) async {
    final picked = await showRoomPicker(
      context,
      tree: tree,
      initialFloorId: _floor?.id ?? widget.floorId,
      allowFloorOnly: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (picked.floor.id != _floor?.id) _pin = null;
      _floor = picked.floor;
      _space = picked.space;
    });
  }

  Future<void> _pickPin() async {
    final floor = _floor;
    if (floor == null) return;
    final pin = await Navigator.of(context).push<SnagPin>(
      MaterialPageRoute(
        builder: (_) => SnagPlanScreen(
          floorId: floor.id,
          buildingId: _buildingId,
          pick: true,
          initial: _pin,
        ),
      ),
    );
    if (pin != null && mounted) setState(() => _pin = pin);
  }

  Future<void> _toggleVoice() async {
    if (_recording) {
      final clip = await _voiceCapture.stop();
      if (!mounted) return;
      setState(() {
        _recording = false;
        _amplitude = null;
        _voice = clip ?? _voice;
      });
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      await _voiceCapture.start(dir.path);
      if (!mounted) return;
      setState(() {
        _recording = true;
        _amplitude = _voiceCapture.amplitudeStream();
      });
    } on CaptureFailure catch (e) {
      if (mounted) showTechPopup(context, message: e.message, isError: true);
    }
  }

  Future<void> _assist() async {
    if (_photos.isEmpty || _assisting) return;
    setState(() => _assisting = true);
    final s = await ref
        .read(snagRepositoryProvider)
        .assist(
          _photos.first,
          voice: _voice,
          hint: _title.text.trim().isEmpty ? null : _title.text.trim(),
          context: _context,
        );
    if (!mounted) return;
    setState(() {
      _assisting = false;
      _suggestion = s;
      if (s == null) return;
      if (s.trade != null) _trade = s.trade!;
      if (s.priority != null) _priority = s.priority!;
      if (s.issueType != null) _issueType = s.issueType!;
      if (s.title != null && _title.text.trim().isEmpty) _title.text = s.title!;
      if (s.description != null && _description.text.trim().isEmpty) {
        _description.text = s.description!;
      }
    });
    if (s == null) {
      showTechPopup(
        context,
        message: 'snags.assist_unavailable'.getString(context),
      );
    }
  }

  String? _label(List<SnagBuilding> buildings) {
    String? buildingName;
    for (final b in buildings) {
      if (b.id == _buildingId) buildingName = b.name;
    }
    final parts = [?buildingName, ?_floor?.name, ?_space?.name];
    return parts.isEmpty ? null : parts.join(' › ');
  }

  Future<void> _save(List<SnagBuilding> buildings) async {
    final actor = ref.read(snagActorProvider);
    if (actor == null || _saving) return;
    if (_photos.isEmpty) {
      showTechPopup(
        context,
        message: 'snags.photo_required'.getString(context),
        isError: true,
      );
      return;
    }
    if (_recording) await _toggleVoice();
    setState(() => _saving = true);
    final repo = ref.read(snagRepositoryProvider);
    final draft = SnagDraft(
      id: repo.newId(),
      context: _context,
      trade: _trade,
      priority: _priority,
      issueType: _issueType,
      title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      description: _description.text.trim().isEmpty
          ? null
          : _description.text.trim(),
      buildingId: _buildingId,
      floorId: _floor?.id ?? widget.floorId,
      spaceId: _space?.id,
      locationLabel: _label(buildings),
      locationText: _spot.text.trim().isEmpty ? null : _spot.text.trim(),
      pin: _pin,
      assetId: widget.assetId,
      assetName: widget.assetName,
      assetReferenceId: widget.assetReferenceId,
      workOrderId: widget.workOrderId,
      responsibleParty: _responsible.text.trim().isEmpty
          ? null
          : _responsible.text.trim(),
      dueDate: _due,
      photos: List.of(_photos),
      voice: _voice,
    );
    try {
      final pool = await repo.local(buildingId: _buildingId);
      final candidates = SnagDuplicateFinder.find(
        draft.signature(raisedBy: actor.id),
        pool,
      );
      if (candidates.isNotEmpty && mounted) {
        final decision = await showDuplicateSheet(
          context,
          candidates: candidates,
          draftPhoto: Image.memory(_photos.first.bytes, fit: BoxFit.cover),
        );
        if (decision.choice == DuplicateChoice.sameIssue &&
            decision.snag != null) {
          final r = await repo.addEvidence(
            decision.snag!,
            actor,
            photos: _photos,
            duplicateReport: true,
          );
          if (!mounted) return;
          bumpSnags(ref);
          context.pushReplacement(Routes.snagDetail(r.snag.id));
          return;
        }
      }
      final r = await repo.raise(draft, actor);
      if (!mounted) return;
      bumpSnags(ref);
      showTechPopup(
        context,
        message: r.synced
            ? snagTr(context, 'snags.saved_ref', [r.snag.displayRef])
            : 'snags.saved_on_device'.getString(context),
        queued: !r.synced,
      );
      context.pushReplacement(Routes.snagDetail(r.snag.id));
    } on ApiFailure catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showTechPopup(context, message: e.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final buildings =
        ref.watch(snagBuildingsProvider).valueOrNull ?? const <SnagBuilding>[];
    final tree = _buildingId == null
        ? null
        : ref.watch(snagTreeProvider(_buildingId!)).valueOrNull;
    if (_floor == null && tree != null && widget.floorId != null) {
      final f = tree.floor(widget.floorId);
      if (f != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => setState(() => _floor ??= f),
        );
      }
    }
    final s = _suggestion;

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(title: 'snags.raise_title'.getString(context)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (widget.arHandoff != null) ...[
            ArHandoffCard(handoff: widget.arHandoff!, showLocationCheck: false),
            const SizedBox(height: 12),
          ],
          if (widget.assetName != null || widget.workOrderId != null)
            TechCard(
              tint: FeColors.infoSoft,
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    widget.workOrderId != null
                        ? LucideIcons.clipboardList
                        : LucideIcons.box,
                    color: FeColors.info,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppText.bodySmall(
                      widget.workOrderId != null
                          ? snagTr(context, 'snags.from_work_order', [
                              widget.assetName ??
                                  (widget.workOrderId!.length > 8
                                      ? widget.workOrderId!.substring(0, 8)
                                      : widget.workOrderId!),
                            ])
                          : snagTr(context, 'snags.from_asset', [
                              widget.assetName!,
                            ]),
                      color: FeColors.ink,
                      weight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            height: 108,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < _photos.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Stack(
                      children: [
                        GestureDetector(
                          onTap: () => _annotate(i),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.memory(
                              _photos[i].bytes,
                              width: 108,
                              height: 108,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: GestureDetector(
                            onTap: () => setState(() => _photos.removeAt(i)),
                            child: const CircleAvatar(
                              radius: 12,
                              backgroundColor: Colors.black54,
                              child: Icon(
                                LucideIcons.x,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        const Positioned(
                          left: 6,
                          bottom: 6,
                          child: Icon(
                            LucideIcons.pencilLine,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                _AddTile(
                  icon: LucideIcons.camera,
                  label: 'snags.camera'.getString(context),
                  onTap: _takePhoto,
                ),
                const SizedBox(width: 8),
                _AddTile(
                  icon: LucideIcons.images,
                  label: 'snags.gallery'.getString(context),
                  onTap: _pickPhoto,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _toggleVoice,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _recording
                        ? FeColors.danger
                        : FeColors.ink,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  icon: Icon(
                    _recording ? LucideIcons.square : LucideIcons.mic,
                    size: 16,
                  ),
                  label: Text(
                    _recording
                        ? 'snags.stop'.getString(context)
                        : (_voice != null
                              ? 'snags.voice_added'.getString(context)
                              : 'snags.voice'.getString(context)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _photos.isEmpty || _assisting ? null : _assist,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  icon: _assisting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(LucideIcons.sparkles, size: 16),
                  label: Text('snags.suggest'.getString(context)),
                ),
              ),
            ],
          ),
          if (_recording && _amplitude != null) ...[
            const SizedBox(height: 8),
            VoiceWaveform(amplitudeStream: _amplitude!, color: FeColors.danger),
          ],
          if (s?.transcript != null) ...[
            const SizedBox(height: 6),
            AppText.bodySmall('“${s!.transcript}”'),
          ],
          const SizedBox(height: 16),
          _Label('snags.what'.getString(context)),
          TradeChipRail(
            value: _trade,
            suggested: s?.trade,
            onChanged: (t) => setState(() => _trade = t),
          ),
          const SizedBox(height: 10),
          SeveritySelector(
            value: _priority,
            suggested: s?.priority,
            onChanged: (p) => setState(() => _priority = p),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in kSnagIssueTypes)
                ChoiceChip(
                  selected: t == _issueType,
                  onSelected: (_) => setState(() => _issueType = t),
                  showCheckmark: false,
                  label: Text(SnagVisuals.issueLabel(context, t)),
                  selectedColor: FeColors.ink,
                  labelStyle: TextStyle(
                    color: t == _issueType ? Colors.white : FeColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: _input('snags.title_hint'.getString(context)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: _input('snags.description_hint'.getString(context)),
          ),
          const SizedBox(height: 16),
          _Label('snags.where'.getString(context)),
          TechCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            // ListTiles need a Material ancestor inside TechCard's DecoratedBox
            // for their ink to show (Flutter asserts otherwise).
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      LucideIcons.building2,
                      color: FeColors.primary,
                    ),
                    title: AppText.bodyMedium(
                      buildings
                              .where((b) => b.id == _buildingId)
                              .map((b) => b.name)
                              .firstOrNull ??
                          'snags.pick_building'.getString(context),
                      weight: FontWeight.w700,
                    ),
                    trailing: const Icon(LucideIcons.chevronsUpDown, size: 16),
                    onTap: () async {
                      final b = await showModalBottomSheet<SnagBuilding>(
                        context: context,
                        showDragHandle: true,
                        builder: (context) => SafeArea(
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final b in buildings)
                                ListTile(
                                  title: Text(b.name),
                                  onTap: () => Navigator.of(context).pop(b),
                                ),
                            ],
                          ),
                        ),
                      );
                      if (b != null) {
                        setState(() {
                          _buildingId = b.id;
                          _floor = null;
                          _space = null;
                          _pin = null;
                        });
                      }
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    enabled: tree != null,
                    leading: const Icon(
                      LucideIcons.doorOpen,
                      color: FeColors.primary,
                    ),
                    title: AppText.bodyMedium(
                      [?_floor?.name, ?_space?.name].join(' › ').isEmpty
                          ? 'snags.pick_room'.getString(context)
                          : [?_floor?.name, ?_space?.name].join(' › '),
                      weight: FontWeight.w700,
                    ),
                    trailing: const Icon(LucideIcons.chevronRight, size: 16),
                    onTap: tree == null ? null : () => _pickRoom(tree),
                  ),
                  if (_floor?.hasPlan ?? false) ...[
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        LucideIcons.mapPin,
                        color: _pin == null ? FeColors.ink2 : FeColors.success,
                      ),
                      title: AppText.bodyMedium(
                        (_pin == null ? 'snags.pin_add' : 'snags.pin_set')
                            .getString(context),
                        weight: FontWeight.w700,
                      ),
                      trailing: const Icon(LucideIcons.chevronRight, size: 16),
                      onTap: _pickPin,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _spot,
            decoration: _input('snags.spot_hint'.getString(context)),
          ),
          const SizedBox(height: 16),
          _Label('snags.who_when'.getString(context)),
          SegmentedButton<SnagContext>(
            segments: [
              for (final c in SnagContext.values)
                ButtonSegment(
                  value: c,
                  icon: Icon(SnagVisuals.contextIcon(c), size: 16),
                  tooltip: SnagVisuals.contextLabel(context, c),
                ),
            ],
            selected: {_context},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _context = v.first),
          ),
          const SizedBox(height: 4),
          AppText.caption(
            SnagVisuals.contextLabel(context, _context),
            color: FeColors.ink2,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _responsible,
            decoration: _input('snags.responsible_hint'.getString(context)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              alignment: Alignment.centerLeft,
            ),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 730)),
                initialDate:
                    _due ?? DateTime.now().add(const Duration(days: 14)),
              );
              if (d != null) setState(() => _due = d);
            },
            icon: const Icon(LucideIcons.calendarClock, size: 16),
            label: Text(
              _due == null
                  ? 'snags.due_add'.getString(context)
                  : snagTr(context, 'snags.due_on', [
                      DateFormat.yMMMd().format(_due!),
                    ]),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            onPressed: _saving ? null : () => _save(buildings),
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(LucideIcons.flag),
            label: Text(
              'snags.raise'.getString(context),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _input(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: FeColors.panel,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: FeColors.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: FeColors.line),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: AppText.labelMedium(
      text.toUpperCase(),
      color: FeColors.ink2,
      weight: FontWeight.w800,
    ),
  );
}

class _AddTile extends StatelessWidget {
  const _AddTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 96,
    child: TechCard(
      onTap: onTap,
      radius: 16,
      borderColor: FeColors.line,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: FeColors.primary),
          const SizedBox(height: 6),
          AppText.caption(label, weight: FontWeight.w700),
        ],
      ),
    ),
  );
}
