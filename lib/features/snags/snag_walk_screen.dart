import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:vibration/vibration.dart';

import '../../app/router.dart';
import '../../core/capture/capture_services.dart';
import '../../core/snag/snag_photo_quality.dart';
import '../../core/snag/snag_rules.dart';
import '../../core/snag/snag_send_state.dart';
import '../../data/snag_repository.dart';
import '../../domain/snag.dart';
import '../../domain/snag_ai.dart';
import '../../state/snag_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/tech_popup.dart';
import '../field_verification/photo_annotation_screen.dart';
import 'widgets/snag_region_overlay.dart';
import 'widgets/snag_sheets.dart';
import 'widgets/snag_visuals.dart';
import 'widgets/snag_walk_sheet.dart';

/// UC-1 — walk mode. The camera stays live for the whole walk; a snag is a
/// shutter press, a trade chip and a severity pill, then straight back to the
/// viewfinder. Location is picked once per room and sticks until "Room done".
///
/// Redesign 2026-10-06 (owner iPhone test: "overwhelming… the UI is fully
/// blocked with no frame displayed"): after the shot the photo keeps the
/// screen — laid out above the details sheet's lowest resting height, so
/// dragging the sheet down shows the WHOLE frame — with the AI's defect
/// highlights drawn on it. The details live in a draggable bottom sheet
/// ([SnagWalkComposeSheet]): AI line, trade, severity and Save & next up
/// front, everything else behind "More details".
///
/// Why a live [CameraController] instead of `image_picker`: `image_picker`
/// hands off to the OS camera app and back for every photo — two full
/// screen transitions per snag, which on a 150-snag takeover survey is the
/// difference between a morning and a day. Same reasoning, and the same
/// lifecycle handling, as `camera_capture_screen.dart`.
class SnagWalkScreen extends ConsumerStatefulWidget {
  const SnagWalkScreen({super.key, required this.surveyId});

  final String surveyId;

  @override
  ConsumerState<SnagWalkScreen> createState() => _SnagWalkScreenState();
}

class _SnagWalkScreenState extends ConsumerState<SnagWalkScreen> with WidgetsBindingObserver {
  CameraController? _camera;
  String? _cameraError;
  var _torch = false;
  var _shooting = false;

  SnagSurvey? _survey;
  SnagLocationTree? _tree;
  SnagFloor? _floor;
  SnagSpace? _space;
  var _pickerShown = false;

  // Compose state — non-null [_photo] means the compose card is up.
  CapturedPhoto? _photo;
  String _trade = kSnagTrades.first;
  SnagPriority _priority = SnagPriority.minor;
  String _issueType = 'defect';
  final _title = TextEditingController();
  String? _description;
  VoiceRecording? _voice;
  SnagSuggestion? _suggestion;
  var _assisting = false;

  // AI assist after the snap (2026-10-06): starts by itself on each shot,
  // marks its picks with ✨ on the chips (one tap accepts each), never
  // blocks Save & next. [_aiRun] drops an answer for a photo already saved.
  SnagAiResult? _ai;
  var _aiRunning = false;
  var _aiRun = 0;
  var _saving = false;

  /// The AI's defect highlights on the current shot, minus any the
  /// technician removed; saved with the photo.
  var _regions = <SnagRegion>[];
  var _highlights = true;
  final _sheet = DraggableScrollableController();

  final _voiceCapture = VoiceCapture();
  var _recording = false;
  Stream<Amplitude>? _amplitude;

  /// Most recent first — the next snag in a room is usually the same trade.
  final _recentTrades = <String>[];
  double? _lat;
  double? _lng;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _load();
    // Evidence geo without blocking the walk on a fresh fix: the last known
    // position is instant and good enough to say which site a photo is from.
    Geolocator.getLastKnownPosition().then((p) {
      _lat = p?.latitude;
      _lng = p?.longitude;
    }).catchError((Object _) => null);
  }

  Future<void> _load() async {
    final repo = ref.read(snagRepositoryProvider);
    final survey = await repo.surveyById(widget.surveyId);
    if (!mounted) return;
    setState(() => _survey = survey);
    final buildingId = survey?.buildingId;
    if (buildingId == null) return;
    try {
      final tree = await ref.read(snagTreeProvider(buildingId).future);
      if (!mounted) return;
      setState(() => _tree = tree);
      if (!_pickerShown) {
        _pickerShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _pickRoom());
      }
    } catch (_) {
      // No tree cached and no signal: the walk still works at building level.
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _cameraError = 'no camera');
        return;
      }
      final rear = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(rear, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (e) {
      if (mounted) setState(() => _cameraError = e.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _camera;
    if (state == AppLifecycleState.inactive) {
      if (controller != null && controller.value.isInitialized) {
        controller.dispose();
        setState(() {
          _camera = null;
          _torch = false;
        });
      }
    } else if (state == AppLifecycleState.resumed && _camera == null) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    if (_recording) _voiceCapture.cancel();
    _voiceCapture.dispose();
    _title.dispose();
    _sheet.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Location
  // -------------------------------------------------------------------------

  String? get _locationLabel {
    final parts = [?_survey?.buildingName, ?_floor?.name, ?_space?.name];
    return parts.isEmpty ? null : parts.join(' › ');
  }

  Future<void> _pickRoom() async {
    final tree = _tree;
    if (tree == null) return;
    final picked = await showRoomPicker(
      context,
      tree: tree,
      survey: _survey,
      initialFloorId: _floor?.id,
      allowFloorOnly: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _floor = picked.floor;
      _space = picked.space;
    });
  }

  List<Snag> _roomSnags(List<Snag> all) => all
      .where((s) =>
          s.surveyId == widget.surveyId &&
          (_space == null ? s.floorId == _floor?.id && s.spaceId == null : s.spaceId == _space!.id))
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// UC-2 — records the room as inspected, then asks for the next one.
  Future<void> _roomDone(int count) async {
    final survey = _survey;
    final floor = _floor;
    final space = _space;
    final actor = ref.read(snagActorProvider);
    if (survey == null || floor == null || space == null || actor == null) {
      await _pickRoom();
      return;
    }
    final next = await ref
        .read(snagRepositoryProvider)
        .sweep(survey, floor: floor, space: space, snagCount: count, actor: actor);
    if (!mounted) return;
    bumpSnags(ref);
    setState(() => _survey = next);
    showTechPopup(
      context,
      message: count == 0
          ? snagTr(context, 'snags.room_marked_clear', [space.name])
          : snagTr(context, 'snags.room_marked_done', [space.name, count]),
    );
    await _pickRoom();
  }

  // -------------------------------------------------------------------------
  // Capture + compose
  // -------------------------------------------------------------------------

  Future<void> _toggleTorch() async {
    final c = _camera;
    if (c == null) return;
    try {
      await c.setFlashMode(_torch ? FlashMode.off : FlashMode.torch);
      if (mounted) setState(() => _torch = !_torch);
    } catch (_) {
      // No flash unit on this lens — nothing to toggle.
    }
  }

  Future<void> _shoot() async {
    final c = _camera;
    if (c == null || _shooting || _photo != null) return;
    setState(() => _shooting = true);
    try {
      final file = await c.takePicture();
      final raw = await file.readAsBytes();
      final bytes = await compute(downscaleJpeg, raw);
      if (!mounted) return;
      setState(() {
        _photo = CapturedPhoto(bytes: bytes, fileName: 'snag.jpg');
        _shooting = false;
        if (_recentTrades.isNotEmpty) _trade = _recentTrades.first;
      });
      unawaited(_runAi());
    } catch (_) {
      if (mounted) setState(() => _shooting = false);
    }
  }

  void _resetCompose() {
    _title.clear();
    _photo = null;
    _description = null;
    _voice = null;
    _suggestion = null;
    _ai = null;
    _aiRunning = false;
    _aiRun++;
    _issueType = 'defect';
    _regions = <SnagRegion>[];
    _highlights = true;
  }

  Future<void> _annotate() async {
    final photo = _photo;
    if (photo == null) return;
    final marked = await Navigator.of(context).push<CapturedPhoto>(
      MaterialPageRoute(builder: (_) => PhotoAnnotationScreen(photo: photo)),
    );
    if (marked != null && mounted) setState(() => _photo = marked);
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

  Future<void> _runAi() async {
    final photo = _photo;
    if (photo == null) return;
    final run = ++_aiRun;
    setState(() => _aiRunning = true);
    SnagPhotoPrep? prep;
    try {
      prep = await compute(prepareSnagPhotoForAi, photo.bytes);
    } catch (_) {
      prep = null;
    }
    if (!mounted || run != _aiRun) return;
    final result = prep == null
        ? const SnagAiResult.unavailable()
        : await ref.read(snagRepositoryProvider).aiAssist(
            aiJpeg: prep.jpeg,
            deviceTips: prep.deviceTips,
            brightness: prep.brightness,
            sharpness: prep.sharpness,
            context: _survey?.context ?? SnagContext.operations,
            buildingId: _survey?.buildingId,
            floorId: _floor?.id,
            spaceId: _space?.id,
            locationLabel: _locationLabel,
            currentTitle: _title.text.trim().isEmpty ? null : _title.text.trim(),
          );
    if (!mounted || run != _aiRun) return;
    setState(() {
      _aiRunning = false;
      _ai = result;
      _regions = List.of(result.regions);
    });
  }

  /// "Apply all" on the walk's AI strip; each chip can also be tapped alone.
  void _applyAllAi() {
    final r = _ai;
    if (r == null) return;
    setState(() {
      if (r.trade != null) _trade = r.trade!;
      if (r.priority != null) _priority = r.priority!;
      if (r.issueType != null) _issueType = r.issueType!;
      if (r.title != null && _title.text.trim().isEmpty) _title.text = r.title!;
      final parts = [
        ?r.description,
        if (r.likelyCause != null) '${'snags.ai.cause_prefix'.getString(context)}: ${r.likelyCause}',
        if (r.recommendedFix != null) '${'snags.ai.fix_prefix'.getString(context)}: ${r.recommendedFix}',
      ];
      if (parts.isNotEmpty && _description == null) _description = parts.join('\n');
    });
  }

  /// UC-11 — a proposal, never a write. Anything missing from the answer
  /// leaves what the inspector already chose.
  Future<void> _assist() async {
    final photo = _photo;
    if (photo == null || _assisting) return;
    setState(() => _assisting = true);
    final s = await ref.read(snagRepositoryProvider).assist(
      photo,
      voice: _voice,
      hint: _title.text.trim().isEmpty ? null : _title.text.trim(),
      context: _survey?.context ?? SnagContext.operations,
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
      _description = s.description ?? _description;
    });
    if (s == null) showTechPopup(context, message: 'snags.assist_unavailable'.getString(context));
  }

  Future<void> _save() async {
    final photo = _photo;
    final survey = _survey;
    final actor = ref.read(snagActorProvider);
    if (photo == null || survey == null || actor == null || _saving) return;
    if (_recording) await _toggleVoice();
    setState(() => _saving = true);
    final repo = ref.read(snagRepositoryProvider);
    final draft = SnagDraft(
      id: repo.newId(),
      context: survey.context,
      trade: _trade,
      priority: _priority,
      issueType: _issueType,
      title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      description: _description,
      buildingId: survey.buildingId,
      floorId: _floor?.id,
      spaceId: _space?.id,
      locationLabel: _locationLabel,
      surveyId: survey.id,
      photos: [photo],
      voice: _voice,
      lat: _lat,
      lng: _lng,
      photoRegions: List.of(_regions),
    );
    try {
      // UC-3 — the duplicate guard runs against everything this device
      // knows about the building, offline included.
      final pool = await repo.local(buildingId: survey.buildingId);
      final candidates = SnagDuplicateFinder.find(draft.signature(raisedBy: actor.id), pool);
      var decision = const DuplicateDecision(DuplicateChoice.different);
      if (candidates.isNotEmpty && mounted) {
        decision = await showDuplicateSheet(
          context,
          candidates: candidates,
          draftPhoto: Image.memory(photo.bytes, fit: BoxFit.cover),
        );
      }
      final String message;
      if (decision.choice == DuplicateChoice.sameIssue && decision.snag != null) {
        final r = await repo.addEvidence(
          decision.snag!,
          actor,
          photos: [photo],
          duplicateReport: true,
          firstPhotoRegions: List.of(_regions),
        );
        if (!mounted) return;
        message = snagTr(context, 'snags.added_to', [r.snag.displayRef]);
      } else {
        // Local save + queue only (outbox first): back to the camera at
        // once. The film strip shows each snag's send state.
        final r = await repo.raise(draft, actor);
        if (!mounted) return;
        message = r.synced
            ? snagTr(context, 'snags.saved_ref', [r.snag.displayRef])
            : 'snags.saved_sending'.getString(context);
      }
      _recentTrades
        ..remove(_trade)
        ..insert(0, _trade);
      if (!mounted) return;
      bumpSnags(ref);
      setState(() {
        _resetCompose();
        _saving = false;
      });
      unawaited(Vibration.vibrate(duration: 40));
      showTechPopup(context, message: message);
    } catch (_) {
      // Anything at all (the photo could not be written, the local database
      // refused): say so plainly and give the Save button back. This used to
      // catch ApiFailure only, so any other error left Save spinning for the
      // rest of the walk.
      if (!mounted) return;
      setState(() => _saving = false);
      showTechPopup(context, message: 'snags.save_failed'.getString(context), isError: true);
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final buildingId = _survey?.buildingId;
    final all = buildingId == null
        ? const <Snag>[]
        : (ref.watch(snagsProvider(buildingId)).valueOrNull ?? const <Snag>[]);
    final walkCount = all.where((s) => s.surveyId == widget.surveyId).length;
    final room = _roomSnags(all);
    final composing = _photo != null;

    return PopScope(
      canPop: !composing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _photo != null) setState(_resetCompose);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, c) {
            final sizes = SnagWalkSheetSizes.forHeight(c.maxHeight);
            // The frozen shot sits above the sheet's lowest resting height
            // (its rounded top overlaps a little), so at peek nothing of the
            // frame is hidden.
            final photoBottom = (sizes.peek * c.maxHeight - 18).clamp(0.0, c.maxHeight);
            return Stack(
              fit: StackFit.expand,
              children: [
                if (!composing) _preview(),
                if (composing)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    bottom: photoBottom,
                    child: GestureDetector(
                      // Tap the photo to drop the sheet and see the whole frame.
                      onTap: () {
                        if (_sheet.isAttached) {
                          _sheet.animateTo(sizes.peek, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
                        }
                      },
                      child: _frozenPhoto(),
                    ),
                  ),
                // Scrims so the white overlay text stays legible on a bright wall.
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black54, Colors.transparent],
                        stops: [0, 0.2],
                      ),
                    ),
                  ),
                ),
                if (!composing)
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                          stops: [0.6, 1],
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      _topBar(walkCount, room.length, composing),
                      if (composing) ...[const SizedBox(height: 8), _aiPhotoChip()],
                    ],
                  ),
                ),
                if (!composing)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SafeArea(top: false, child: _bottomBar(room)),
                  ),
                if (composing)
                  SnagWalkComposeSheet(
                    sizes: sizes,
                    controller: _sheet,
                    aiRunning: _aiRunning,
                    ai: _ai,
                    onApplyAllAi: _applyAllAi,
                    onRetryAi: _runAi,
                    trade: _trade,
                    tradeOrder: [..._recentTrades, ...kSnagTrades.where((t) => !_recentTrades.contains(t))],
                    onTrade: (t) => setState(() => _trade = t),
                    priority: _priority,
                    onPriority: (p) => setState(() => _priority = p),
                    issueType: _issueType,
                    onIssueType: (t) => setState(() => _issueType = t),
                    title: _title,
                    description: _description,
                    saving: _saving,
                    onSave: _save,
                    onMarkUp: _annotate,
                    onVoice: _toggleVoice,
                    onSuggest: _assist,
                    recording: _recording,
                    voiceAdded: _voice != null,
                    amplitude: _amplitude,
                    suggesting: _assisting,
                    suggested: _suggestion != null,
                    transcript: _suggestion?.transcript,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The shot just taken, whole (`contain`), with the AI's highlights.
  Widget _frozenPhoto() {
    final image = MemoryImage(_photo!.bytes);
    return ColoredBox(
      color: Colors.black,
      child: SnagRegionLayer(
        image: image,
        regions: _regions,
        fit: BoxFit.contain,
        visible: _highlights,
        onDelete: (i) => setState(() => _regions.removeAt(i)),
        child: SizedBox.expand(child: Image(image: image, fit: BoxFit.contain, gaplessPlayback: true)),
      ),
    );
  }

  /// The AI's presence on the photo itself: "looking…" while it works, then
  /// a show/hide toggle for the highlights it drew.
  Widget _aiPhotoChip() {
    if (_aiRunning) {
      return Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: FeColors.ai.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Text(
              'snags.ai.step_photo'.getString(context),
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );
    }
    if (_regions.isEmpty) return const SizedBox.shrink();
    return SnagHighlightsToggle(
      count: _regions.length,
      visible: _highlights,
      onChanged: (v) => setState(() => _highlights = v),
    );
  }

  Widget _preview() {
    if (_cameraError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppText(
            'fieldVerify.camera_unavailable'.getString(context),
            align: TextAlign.center,
            color: Colors.white,
          ),
        ),
      );
    }
    final c = _camera;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: c.value.previewSize?.height ?? 1080,
        height: c.value.previewSize?.width ?? 1920,
        child: CameraPreview(c),
      ),
    );
  }

  Widget _topBar(int walkCount, int roomCount, bool composing) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(LucideIcons.x, color: Colors.white),
                tooltip: (composing ? 'snags.discard' : 'snags.finish_walk').getString(context),
                onPressed: () => composing ? setState(_resetCompose) : context.pop(),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: composing ? null : _pickRoom,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      children: [
                        const Icon(LucideIcons.mapPin, color: Colors.white, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _space?.name ?? _floor?.name ?? 'snags.pick_room'.getString(context),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                          ),
                        ),
                        if (_space != null && _floor != null)
                          Flexible(
                            child: Text(
                              _floor!.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        if (!composing) ...[
                          const SizedBox(width: 4),
                          const Icon(LucideIcons.chevronDown, color: Colors.white70, size: 16),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (!composing)
                IconButton(
                  icon: Icon(
                    _torch ? LucideIcons.flashlight : LucideIcons.flashlightOff,
                    color: _torch ? FeColors.warning : Colors.white,
                  ),
                  onPressed: _toggleTorch,
                )
              else
                const SizedBox(width: 48),
            ],
          ),
          // Counters only while shooting: after the shot the frame matters more.
          if (!composing) ...[
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                _Counter(icon: LucideIcons.doorOpen, label: snagTr(context, 'snags.count_room', [roomCount])),
                _Counter(icon: LucideIcons.footprints, label: snagTr(context, 'snags.count_walk', [walkCount])),
                if (_survey != null)
                  _Counter(
                    icon: LucideIcons.check,
                    label: snagTr(context, 'snags.count_rooms_checked', [_survey!.inspectedSpaces.length]),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _bottomBar(List<Snag> room) {
    final count = room.length;
    final pending = ref.watch(pendingSnagIdsProvider).valueOrNull ?? const <String>{};
    final flushing = ref.watch(snagQueueFlushingProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (room.isNotEmpty)
          SizedBox(
            height: 64,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: room.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final s = room[i];
                // Each thumbnail carries its own send state, so a walk that
                // never waits on the network still shows what has gone.
                final send = snagSendStatus(s, queued: pending.contains(s.id), flushing: flushing).state;
                return GestureDetector(
                  onTap: () => context.push(Routes.snagDetail(s.id)),
                  child: Stack(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: SnagVisuals.priorityColor(s.priority), width: 2),
                        ),
                        child: SnagPhoto(
                          evidence: s.coverPhoto,
                          radius: 10,
                          dark: true,
                          showRegions: true,
                          compactRegions: true,
                        ),
                      ),
                      Positioned(
                        right: 3,
                        bottom: 3,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: Icon(SnagVisuals.sendIcon(send), size: 12, color: SnagVisuals.sendColor(send)),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Row(
            children: [
              Expanded(
                child: _GhostButton(
                  icon: count == 0 ? LucideIcons.circleCheck : LucideIcons.listChecks,
                  label: _space == null
                      ? 'snags.pick_room'.getString(context)
                      : (count == 0
                            ? 'snags.room_clear_btn'.getString(context)
                            : snagTr(context, 'snags.room_done_btn', [count])),
                  onTap: () => _space == null ? _pickRoom() : _roomDone(count),
                ),
              ),
              const SizedBox(width: 16),
              Semantics(
                button: true,
                label: 'snags.walk.shutter'.getString(context),
                child: GestureDetector(
                  onTap: _shoot,
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    padding: const EdgeInsets.all(5),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _shooting ? Colors.white54 : Colors.white,
                      ),
                      child: _shooting
                          ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: CircularProgressIndicator(strokeWidth: 2, color: FeColors.primary),
                            )
                          : const Icon(LucideIcons.plus, color: FeColors.ink, size: 28),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _GhostButton(
                  icon: LucideIcons.flag,
                  label: 'snags.finish_walk'.getString(context),
                  onTap: () => context.pushReplacement(Routes.snagSurvey(widget.surveyId)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.white70),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );
}
