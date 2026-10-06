import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../core/capture/capture_services.dart';
import '../../core/network/api_exception.dart';
import '../../core/snag/snag_rules.dart';
import '../../core/snag/snag_send_state.dart';
import '../../data/snag_repository.dart';
import '../../domain/conversation.dart';
import '../../domain/snag.dart';
import '../../state/snag_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/tech_popup.dart';
import '../../widgets/voice_note_player.dart';
import '../conversation/conversation_preview_card.dart';
import 'ghost_camera_screen.dart';
import 'snag_plan_screen.dart';
import 'widgets/snag_sheets.dart';
import 'widgets/snag_region_overlay.dart';
import 'widgets/snag_visuals.dart';

/// UC-10 — one snag: its photos, where it is, where it is in its life, and
/// the one or two things the viewer can do about it right now.
class SnagDetailScreen extends ConsumerStatefulWidget {
  const SnagDetailScreen({super.key, required this.snagId, this.messageId});
  final String snagId;

  /// A notification deep link to one message (`/snags/<id>?message=<mid>`):
  /// the thread opens on top, scrolled to it.
  final String? messageId;

  @override
  ConsumerState<SnagDetailScreen> createState() => _SnagDetailScreenState();
}

class _SnagDetailScreenState extends ConsumerState<SnagDetailScreen> {
  var _busy = false;

  @override
  void initState() {
    super.initState();
    // Opens from the local copy at once, then reads the server's full copy
    // in the background: list pulls are lean (no timeline), and a snag whose
    // queued create already synced gets its SN- number here even if the
    // replay follow-up missed it. Offline this is a no-op.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final repo = ref.read(snagRepositoryProvider);
        final before = await repo.localById(widget.snagId);
        await repo.fetchOne(widget.snagId);
        final after = await repo.localById(widget.snagId);
        if (mounted && before != null && after != null && jsonEncode(before.toJson()) != jsonEncode(after.toJson())) {
          bumpSnags(ref);
        }
      } catch (_) {
        // Background freshness only; the local copy is already on screen.
      }
    });
    final message = widget.messageId;
    if (message != null && message.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.push(Routes.conversation(ConvEntity.snag.wire, widget.snagId, messageId: message));
      });
    }
  }

  Future<void> _run(Future<SnagWriteResult> Function(SnagRepository repo, SnagActor actor) op) async {
    final actor = ref.read(snagActorProvider);
    if (actor == null || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await op(ref.read(snagRepositoryProvider), actor);
      if (!mounted) return;
      bumpSnags(ref);
      showTechPopup(
        context,
        message: r.synced ? 'snags.saved'.getString(context) : 'snags.saved_on_device'.getString(context),
        queued: !r.synced,
      );
    } on SnagRuleException catch (e) {
      if (mounted) showTechPopup(context, message: e.failure.message, isError: true);
    } on ApiFailure catch (e) {
      if (mounted) {
        bumpSnags(ref);
        showTechPopup(context, message: e.message, isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retrySend(Snag s) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(snagRepositoryProvider).retrySend(s);
      if (!mounted) return;
      bumpSnags(ref);
      showTechPopup(context, message: 'snags.send.retry_started'.getString(context));
    } catch (_) {
      if (mounted) showTechPopup(context, message: 'snags.send.retry_failed'.getString(context), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start(Snag s) => _run((repo, a) => repo.transition(s, SnagAction.start, a));

  Future<void> _markReady(Snag s) async {
    final photo = await Navigator.of(context).push<CapturedPhoto>(
      MaterialPageRoute(
        builder: (_) => GhostCameraScreen(before: s.coverPhoto, title: 'snags.after_photo_title'.getString(context)),
      ),
    );
    if (photo == null || !mounted) return;
    await _run((repo, a) => repo.transition(s, SnagAction.ready, a, photos: [photo]));
  }

  Future<void> _verify(Snag s) => _run((repo, a) => repo.transition(s, SnagAction.verify, a));

  Future<void> _reject(Snag s, SnagAction action) async {
    final reason = await showReasonSheet(
      context,
      title: action == SnagAction.reopen
          ? 'snags.reopen_title'.getString(context)
          : 'snags.reject_title'.getString(context),
    );
    if (reason == null || !mounted) return;
    await _run((repo, a) => repo.transition(s, action, a, reason: reason));
  }

  Future<void> _addPhoto(Snag s) async {
    final photo = await PhotoCapture().takeJobPhoto();
    if (photo == null || !mounted) return;
    await _run((repo, a) => repo.addEvidence(s, a, photos: [photo]));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(snagByIdProvider(widget.snagId));
    final me = ref.watch(snagActorProvider)?.id ?? '';
    final pending = ref.watch(pendingSnagIdsProvider).valueOrNull ?? const <String>{};
    final flushing = ref.watch(snagQueueFlushingProvider);
    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: async.valueOrNull?.displayRef ?? 'snags.title'.getString(context),
        actions: [
          if (async.valueOrNull?.pin != null)
            IconButton(
              tooltip: 'snags.show_on_plan'.getString(context),
              icon: const Icon(LucideIcons.map),
              onPressed: () {
                final s = async.valueOrNull!;
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SnagPlanScreen(floorId: s.pin!.floorId, buildingId: s.buildingId, focusSnagId: s.id),
                ));
              },
            ),
        ],
      ),
      body: async.when(
        loading: () => const TechSpinner(),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: TechEmptyState(icon: LucideIcons.cloudOff, title: 'snags.load_failed'.getString(context)),
        ),
        data: (s) {
          if (s == null) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: TechEmptyState(icon: LucideIcons.searchX, title: 'snags.not_found'.getString(context)),
            );
          }
          final send = snagSendStatus(s, queued: pending.contains(s.id), flushing: flushing);
          final actions = s.localOnly ? const <SnagAction>[] : SnagRules.actionsFor(s, me);
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    _Gallery(snag: s),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        TechChip(
                          label: SnagVisuals.priorityLabel(context, s.priority),
                          style: SnagVisuals.chip(SnagVisuals.priorityColor(s.priority)),
                        ),
                        TechChip(
                          label: SnagVisuals.statusLabel(context, s.status),
                          style: SnagVisuals.chip(SnagVisuals.statusColor(s.status)),
                        ),
                        TechChip(
                          label: SnagVisuals.tradeLabel(context, s.trade),
                          style: SnagVisuals.chip(FeColors.ink2),
                          uppercase: false,
                        ),
                        TechChip(
                          label: SnagVisuals.issueLabel(context, s.issueType),
                          style: SnagVisuals.chip(FeColors.ink2),
                          uppercase: false,
                        ),
                        TechChip(
                          label: SnagVisuals.contextLabel(context, s.context),
                          style: SnagVisuals.chip(FeColors.dashboardAccent),
                          uppercase: false,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    AppText.title(s.title),
                    if (s.description != null) ...[
                      const SizedBox(height: 6),
                      AppText.bodyMedium(s.description!, color: FeColors.ink2),
                    ],
                    if (!send.state.isSynced) ...[
                      const SizedBox(height: 12),
                      _SendBanner(status: send, busy: _busy, onRetry: () => _retrySend(s)),
                    ],
                    const SizedBox(height: 16),
                    TechCard(child: SnagStatusStepper(snag: s)),
                    const SizedBox(height: 12),
                    TechCard(
                      child: Column(
                        children: [
                          _Fact(icon: LucideIcons.mapPin, label: 'snags.location'.getString(context), value: [
                            ?s.locationLabel,
                            ?s.locationText,
                          ].join('\n')),
                          if (s.assetName != null || s.assetReferenceId != null)
                            _Fact(
                              icon: LucideIcons.box,
                              label: 'snags.asset'.getString(context),
                              value: [?s.assetName, ?s.assetReferenceId].join(' · '),
                              onTap: s.assetId == null ? null : () => context.push(Routes.assetDetail(s.assetId!)),
                            ),
                          _Fact(
                            icon: LucideIcons.briefcase,
                            label: 'snags.responsible'.getString(context),
                            value: s.responsibleParty ?? s.assigneeName ?? 'snags.unassigned'.getString(context),
                          ),
                          if (s.dueDate != null)
                            _Fact(
                              icon: LucideIcons.calendarClock,
                              label: 'snags.due'.getString(context),
                              value: DateFormat.yMMMd().format(s.dueDate!),
                              danger: s.isOverdue(DateTime.now()),
                            ),
                          _Fact(
                            icon: LucideIcons.user,
                            label: 'snags.raised_by'.getString(context),
                            value: '${s.raisedByName ?? '—'} · ${DateFormat.yMMMd().add_jm().format(s.createdAt)}',
                          ),
                          if (s.reportCount > 1)
                            _Fact(
                              icon: LucideIcons.users,
                              label: 'snags.also_reported'.getString(context),
                              value: snagTr(context, 'snags.reported_times', [s.reportCount]),
                            ),
                          if (s.workOrderId != null)
                            _Fact(
                              icon: LucideIcons.clipboardList,
                              label: 'snags.work_order'.getString(context),
                              value: s.workOrderId!.length > 8 ? s.workOrderId!.substring(0, 8) : s.workOrderId!,
                              onTap: () => context.push(Routes.orderDetail('work-order', s.workOrderId!)),
                            ),
                        ],
                      ),
                    ),
                    for (final audio in s.evidence.where((e) => !e.isPhoto))
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: TechCard(
                          padding: const EdgeInsets.all(10),
                          child: _AudioEvidence(evidence: audio),
                        ),
                      ),
                    const SizedBox(height: 16),
                    // The snag's comments ARE its conversation (server:
                    // the thread is this snag's `activity` comments, see
                    // documentation/conversations.md "Stores"), so they show
                    // in the Conversation card and the timeline keeps the
                    // life events only. A snag still only on this phone has
                    // no server thread yet.
                    if (s.localOnly)
                      TechCard(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(LucideIcons.messagesSquare, size: 18, color: FeColors.ink2),
                            const SizedBox(width: 8),
                            Expanded(child: AppText.bodySmall('conv.snag_local_only'.getString(context))),
                          ],
                        ),
                      )
                    else
                      ConversationPreviewCard(entity: ConvEntity.snag, id: s.id),
                    const SizedBox(height: 16),
                    AppText.titleMedium('snags.activity'.getString(context)),
                    const SizedBox(height: 8),
                    _Timeline(
                      activity: s.localOnly ? s.activity : s.activity.where((a) => a.type != 'comment').toList(),
                    ),
                  ],
                ),
              ),
              _ActionBar(
                snag: s,
                actions: actions,
                busy: _busy,
                onStart: () => _start(s),
                onReady: () => _markReady(s),
                onVerify: () => _verify(s),
                onReject: () => _reject(s, SnagAction.reject),
                onReopen: () => _reject(s, SnagAction.reopen),
                onAddPhoto: s.localOnly ? null : () => _addPhoto(s),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Gallery extends StatefulWidget {
  const _Gallery({required this.snag});
  final Snag snag;
  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  var _compare = true;

  @override
  Widget build(BuildContext context) {
    final s = widget.snag;
    final before = s.beforePhotos;
    final after = s.afterPhotos;
    if (before.isNotEmpty && after.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, icon: const Icon(LucideIcons.columns2, size: 16), label: Text('snags.compare'.getString(context))),
                ButtonSegment(value: false, icon: const Icon(LucideIcons.images, size: 16), label: Text('snags.photos'.getString(context))),
              ],
              selected: {_compare},
              onSelectionChanged: (v) => setState(() => _compare = v.first),
              showSelectedIcon: false,
            ),
          ),
          const SizedBox(height: 8),
          if (_compare) CompareSlider(before: before.first, after: after.last) else _Strip(photos: s.photos),
        ],
      );
    }
    return _Strip(photos: s.photos);
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.photos});
  final List<SnagEvidence> photos;

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) {
      return Container(
        height: 180,
        decoration: BoxDecoration(color: FeColors.line, borderRadius: BorderRadius.circular(18)),
        alignment: Alignment.center,
        child: const Icon(LucideIcons.imageOff, color: FeColors.ink2),
      );
    }
    return SizedBox(
      height: 260,
      child: PageView.builder(
        controller: PageController(viewportFraction: photos.length > 1 ? 0.9 : 1),
        itemCount: photos.length,
        itemBuilder: (context, i) {
          final p = photos[i];
          return Padding(
            padding: EdgeInsets.only(right: photos.length > 1 ? 8 : 0),
            child: GestureDetector(
              onTap: () => _openFull(context, p),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Kept defect highlights (2026-10-06) ride on the photo.
                  SnagPhoto(evidence: p, radius: 18, showRegions: true),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: TechChip(
                      label: 'snags.stage.${p.stage}'.getString(context),
                      style: SnagVisuals.chip(p.isAfter ? FeColors.success : FeColors.ink),
                    ),
                  ),
                  if (p.capturedByName != null)
                    Positioned(
                      left: 10,
                      bottom: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                        child: Text(
                          '${p.capturedByName} · ${DateFormat.MMMd().add_jm().format(p.capturedAt)}',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openFull(BuildContext context, SnagEvidence p) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FullPhoto(evidence: p),
    ));
  }
}

/// Full-screen photo viewer: pinch to zoom, highlights drawn on the photo
/// itself (so they zoom with it) and a show/hide toggle when it has any.
class _FullPhoto extends StatefulWidget {
  const _FullPhoto({required this.evidence});
  final SnagEvidence evidence;

  @override
  State<_FullPhoto> createState() => _FullPhotoState();
}

class _FullPhotoState extends State<_FullPhoto> {
  var _highlights = true;

  @override
  Widget build(BuildContext context) {
    final p = widget.evidence;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: const FeHeader(title: '', variant: FeHeaderVariant.immersive),
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: SnagPhoto(evidence: p, fit: BoxFit.contain, dark: true, showRegions: _highlights),
              ),
            ),
          ),
          if (p.regions.isNotEmpty)
            PositionedDirectional(
              bottom: 24 + MediaQuery.paddingOf(context).bottom,
              start: 0,
              end: 0,
              child: Center(
                child: SnagHighlightsToggle(
                  count: p.regions.length,
                  visible: _highlights,
                  onChanged: (v) => setState(() => _highlights = v),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AudioEvidence extends ConsumerWidget {
  const _AudioEvidence({required this.evidence});
  final SnagEvidence evidence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<File?>(
      future: ref.read(snagMediaProvider).localFile(evidence),
      builder: (context, snap) {
        final local = snap.data;
        final source = local != null ? Uri.file(local.path).toString() : evidence.url;
        if (source == null) {
          return AppText.bodySmall('snags.voice_pending'.getString(context));
        }
        return VoiceNotePlayer(audioUrl: source);
      },
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, required this.value, this.onTap, this.danger = false});
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: danger ? FeColors.danger : FeColors.ink2),
            const SizedBox(width: 10),
            SizedBox(width: 96, child: AppText.bodySmall(label)),
            Expanded(
              child: AppText.bodyMedium(
                value,
                weight: FontWeight.w600,
                color: danger ? FeColors.danger : (onTap != null ? FeColors.primary : FeColors.ink),
              ),
            ),
            if (onTap != null) const Icon(LucideIcons.chevronRight, size: 16, color: FeColors.ink2),
          ],
        ),
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.activity});
  final List<SnagActivity> activity;

  static IconData _icon(String type) => switch (type) {
    'raised' => LucideIcons.flag,
    'started' => LucideIcons.hammer,
    'ready' => LucideIcons.circleCheck,
    'verified' => LucideIcons.badgeCheck,
    'rejected' => LucideIcons.circleX,
    'reopened' => LucideIcons.rotateCcw,
    'waived' => LucideIcons.signature,
    'evidence' => LucideIcons.camera,
    'duplicate-report' => LucideIcons.users,
    'edited' => LucideIcons.pencil,
    _ => LucideIcons.messageSquare,
  };

  static Color _color(String type) => switch (type) {
    'verified' || 'ready' => FeColors.success,
    'rejected' || 'reopened' => FeColors.danger,
    'duplicate-report' => FeColors.info,
    _ => FeColors.ink2,
  };

  @override
  Widget build(BuildContext context) {
    final items = [...activity]..sort((a, b) => b.at.compareTo(a.at));
    return Column(
      children: [
        for (var i = 0; i < items.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 28,
                  child: Column(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(color: _color(items[i].type).withValues(alpha: 0.12), shape: BoxShape.circle),
                        child: Icon(_icon(items[i].type), size: 14, color: _color(items[i].type)),
                      ),
                      if (i < items.length - 1) Expanded(child: Container(width: 2, color: FeColors.line)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText.bodyMedium(
                          snagTr(context, 'snags.event.${items[i].type}', [items[i].byName ?? '—']),
                          weight: FontWeight.w600,
                        ),
                        AppText.caption(DateFormat.yMMMd().add_jm().format(items[i].at), color: FeColors.ink2),
                        if (items[i].reason != null) ...[
                          const SizedBox(height: 2),
                          AppText.bodySmall(items[i].reason!, color: FeColors.danger),
                        ],
                        if (items[i].note != null) ...[
                          const SizedBox(height: 2),
                          AppText.bodySmall(items[i].note!),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.snag,
    required this.actions,
    required this.busy,
    required this.onStart,
    required this.onReady,
    required this.onVerify,
    required this.onReject,
    required this.onReopen,
    required this.onAddPhoto,
  });

  final Snag snag;
  final List<SnagAction> actions;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onReady;
  final VoidCallback onVerify;
  final VoidCallback onReject;
  final VoidCallback onReopen;
  final VoidCallback? onAddPhoto;

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[];
    Widget primary(String label, IconData icon, VoidCallback onTap, {Color? color}) => Expanded(
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          backgroundColor: color ?? FeColors.primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: busy ? null : onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
    Widget secondary(String label, IconData icon, VoidCallback onTap, {Color? color}) => Expanded(
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          foregroundColor: color ?? FeColors.ink,
          side: BorderSide(color: (color ?? FeColors.ink2).withValues(alpha: 0.5)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: busy ? null : onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );

    for (final a in actions) {
      switch (a) {
        case SnagAction.start:
          buttons.add(secondary('snags.action.start'.getString(context), LucideIcons.hammer, onStart));
        case SnagAction.ready:
          buttons.add(primary('snags.action.ready'.getString(context), LucideIcons.camera, onReady));
        case SnagAction.verify:
          buttons.add(primary('snags.action.verify'.getString(context), LucideIcons.badgeCheck, onVerify,
              color: FeColors.success));
        case SnagAction.reject:
          buttons.add(secondary('snags.action.reject'.getString(context), LucideIcons.circleX, onReject,
              color: FeColors.danger));
        case SnagAction.reopen:
          buttons.add(secondary('snags.action.reopen'.getString(context), LucideIcons.rotateCcw, onReopen,
              color: FeColors.danger));
        case SnagAction.waive:
          break;
      }
    }
    if (buttons.isEmpty && onAddPhoto == null) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 10 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(
        color: FeColors.panel,
        border: Border(top: BorderSide(color: FeColors.line)),
      ),
      child: Row(
        children: [
          if (onAddPhoto != null) ...[
            IconButton.filledTonal(
              tooltip: 'snags.add_photo'.getString(context),
              onPressed: busy ? null : onAddPhoto,
              icon: const Icon(LucideIcons.imagePlus),
            ),
            if (buttons.isNotEmpty) const SizedBox(width: 8),
          ],
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            buttons[i],
          ],
          if (buttons.isEmpty)
            Expanded(
              child: AppText.bodySmall(
                snag.status == SnagStatus.ready
                    ? 'snags.waiting_other_verifier'.getString(context)
                    : 'snags.no_actions'.getString(context),
              ),
            ),
        ],
      ),
    );
  }
}


/// Honest send state on the detail screen (2026-10-06): what is happening
/// to this snag on its way to the server, why, in plain words, and a Retry.
class _SendBanner extends StatelessWidget {
  const _SendBanner({required this.status, required this.busy, required this.onRetry});
  final SnagSendStatus status;
  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final color = SnagVisuals.sendColor(status.state);
    final soft = switch (status.state) {
      SnagSendState.notSent => FeColors.dangerSoft,
      SnagSendState.sending => FeColors.infoSoft,
      _ => FeColors.warningSoft,
    };
    return TechCard(
      tint: soft,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: status.state == SnagSendState.sending
                ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                : Icon(SnagVisuals.sendIcon(status.state), color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodyMedium(status.labelKey.getString(context), weight: FontWeight.w700, color: FeColors.ink),
                if (status.reasonKey != null) ...[
                  const SizedBox(height: 2),
                  AppText.bodySmall(status.reasonKey!.getString(context), color: FeColors.ink),
                ],
              ],
            ),
          ),
          if (status.state.canRetry) ...[
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: busy ? null : onRetry,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: Text('snags.send.retry'.getString(context)),
            ),
          ],
        ],
      ),
    );
  }
}
