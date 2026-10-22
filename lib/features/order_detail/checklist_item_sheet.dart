import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/capture/capture_services.dart';
import '../../core/utils/dates.dart';
import '../../domain/checklist.dart';
import '../../state/checklist_controller.dart';
import '../../state/order_detail_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/tech_popup.dart';
import '../../widgets/voice_note_player.dart';
import '../../widgets/voice_waveform.dart';
import 'verification_sheet.dart';

/// Everything a technician does to one task: run its timer, tick it off, add
/// notes and photos.
class ChecklistItemSheet extends ConsumerStatefulWidget {
  const ChecklistItemSheet({
    super.key,
    required this.orderKey,
    required this.index,
    required this.requireFaceCapture,
    required this.requireLocation,
  });

  final OrderKey orderKey;
  final int index;
  final bool requireFaceCapture;
  final bool requireLocation;

  @override
  ConsumerState<ChecklistItemSheet> createState() => _ChecklistItemSheetState();
}

class _ChecklistItemSheetState extends ConsumerState<ChecklistItemSheet> {
  final _noteController = TextEditingController();
  final _voice = VoiceCapture();
  bool _recording = false;
  Stream<Amplitude>? _amplitudeStream;

  @override
  void dispose() {
    _noteController.dispose();
    _voice.dispose();
    super.dispose();
  }

  ChecklistController get _controller =>
      ref.read(checklistControllerProvider(widget.orderKey).notifier);

  void _report(ActionOutcome? outcome) {
    if (outcome == null || !mounted) return;
    showTechPopup(
      context,
      message: outcome.text,
      queued: outcome.queued,
      isError: !outcome.queued,
    );
  }

  /// A session start or end may be gated behind a photo and a location fix.
  Future<VerificationResult?> _verify(VerificationMode mode) async {
    if (!widget.requireFaceCapture && !widget.requireLocation) {
      return const VerificationResult();
    }
    return showModalBottomSheet<VerificationResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: FeColors.panel,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.radii.sheet),
        ),
      ),
      builder: (context) => VerificationSheet(
        mode: mode,
        requireFaceCapture: widget.requireFaceCapture,
        requireLocation: widget.requireLocation,
      ),
    );
  }

  Future<void> _toggleTimer(ChecklistItem item) async {
    final mode = item.isRunning ? VerificationMode.end : VerificationMode.start;

    final verification = await _verify(mode);
    if (verification == null) return;

    _report(
      mode == VerificationMode.end
          ? await _controller.stopSession(
              widget.index,
              facePhoto: verification.photo,
              location: verification.location,
            )
          : await _controller.startSession(
              widget.index,
              facePhoto: verification.photo,
              location: verification.location,
            ),
    );
  }

  Future<void> _addPhoto({required bool fromGallery}) async {
    final capture = ref.read(photoCaptureProvider);
    final photo = fromGallery
        ? await capture.pickFromGallery()
        : await capture.takeJobPhoto();
    if (photo == null) return;
    _report(await _controller.addPhoto(widget.index, photo));
  }

  Future<void> _sendNote() async {
    final text = _noteController.text.trim();
    if (text.isEmpty) return;
    _noteController.clear();
    _report(await _controller.addNote(widget.index, text: text));
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      final recording = await _voice.stop();
      if (!mounted) return;
      setState(() {
        _recording = false;
        _amplitudeStream = null;
      });
      if (recording == null) {
        _report(
          ActionOutcome.failed(
            'order_detail.nothing_recorded'.getString(context),
          ),
        );
        return;
      }
      _report(
        await _controller.addNote(
          widget.index,
          text: _noteController.text.trim(),
          voice: recording,
        ),
      );
      _noteController.clear();
      return;
    }

    try {
      final directory = await getTemporaryDirectory();
      await _voice.start(directory.path);
      if (!mounted) return;
      setState(() {
        _recording = true;
        _amplitudeStream = _voice.amplitudeStream();
      });
    } on CaptureFailure catch (e) {
      _report(ActionOutcome.failed(e.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(checklistControllerProvider(widget.orderKey));
    if (widget.index >= state.items.length) return const SizedBox.shrink();

    final item = state.items[widget.index];
    final busy = state.busyIndex == widget.index;

    // Digital-signature sign-off (2026-09-09): the signature is a normal
    // checklist item everywhere else (Tasks list, close guard), but there is
    // nothing to time, complete, attach a photo to, or note on it — its
    // detail sheet is read-only and shows the drawn signature instead. See
    // `checklistCloseGuard.ts` (server) and `close_sheet.dart` (where it is
    // created) for the rest of this feature.
    if (item.isSignature) {
      return _SignatureItemSheet(item: item);
    }

    // The modal route caps this sheet at a fixed fraction of the screen and
    // never accounts for the keyboard itself — without this padding the
    // keyboard just overlaps the sheet's bottom edge, hiding the note
    // composer entirely instead of the Flexible list above it shrinking to
    // make room (mirrors order_chat_sheet.dart's composer).
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppText.titleMedium(
                      item.title,
                      weight: FontWeight.w700,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons.x, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: busy || (item.isCompleted && !item.isRunning)
                          ? null
                          : () => _toggleTimer(item),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: item.isRunning
                            ? FeColors.danger
                            : FeColors.primary,
                      ),
                      icon: Icon(
                        item.isRunning ? LucideIcons.pause : LucideIcons.play,
                        size: 16,
                      ),
                      label: AppText(
                        item.isRunning
                            ? 'order_detail.pause'.getString(context)
                            : item.sessions.isEmpty
                            ? 'order_detail.start_timer'.getString(context)
                            : 'order_detail.start_new_session'.getString(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy || (!item.isCompleted && item.isRunning)
                          ? null
                          : () async =>
                                _report(await _controller.toggle(widget.index)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: item.isCompleted
                            ? FeColors.success
                            : null,
                        foregroundColor: item.isCompleted
                            ? Colors.white
                            : FeColors.ink2,
                      ),
                      child: AppText(
                        item.isCompleted
                            ? 'order_detail.mark_incomplete'.getString(context)
                            : 'order_detail.mark_complete'.getString(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!item.isCompleted && item.isRunning)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: AppText.caption(
                  'order_detail.stop_timer_to_complete'.getString(context),
                  color: FeColors.warning,
                ),
              ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                children: [
                  _TimeLog(item: item),
                  const SizedBox(height: 16),
                  _Notes(item: item),
                  const SizedBox(height: 16),
                  _Attachments(
                    item: item,
                    onAdd: () => _addPhoto(fromGallery: false),
                    onPick: () => _addPhoto(fromGallery: true),
                    onRemove: (url) async => _report(
                      await _controller.removePhoto(widget.index, url),
                    ),
                  ),
                ],
              ),
            ),
            _NoteComposer(
              controller: _noteController,
              recording: _recording,
              amplitudeStream: _amplitudeStream,
              enabled: !busy,
              onSend: _sendNote,
              onToggleRecording: _toggleRecording,
            ),
          ],
        ),
      ),
    );
  }
}

/// Detail sheet for the one synthetic checklist item that holds the
/// technician's sign-off. No timer, no complete toggle, no photos, no note
/// composer — those all mutate a task; a signature is a record of a fact
/// that already happened, so this sheet only ever displays it.
class _SignatureItemSheet extends StatelessWidget {
  const _SignatureItemSheet({required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppText.titleMedium(
                    item.title,
                    weight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons.x, size: 20),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              child: SignatureDetail(item: item),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The signature image, signer name, and signed date/time — read-only
/// rendering of the synthetic sign-off item, for this sheet's own header
/// (pen icon + "Signature" label). The Details tab's "Signature" section
/// (`order_detail_screen.dart`) wants the same image+caption content under
/// its own icon-in-circle section header instead of this one, so that part
/// is factored out into [SignatureImageAndCaption] below and reused as-is.
class SignatureDetail extends StatelessWidget {
  const SignatureDetail({super.key, required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.penLine, size: 16, color: FeColors.ink2),
            const SizedBox(width: 8),
            AppText.titleSmall(
              'order_detail.signature_label'.getString(context),
              weight: FontWeight.w700,
            ),
          ],
        ),
        const SizedBox(height: 12),
        SignatureImageAndCaption(item: item),
      ],
    );
  }
}

/// The signature image plus "Signed by X" / signed-date caption — no header
/// of its own, so any call site supplies its own heading. Shared by
/// [SignatureDetail] above and the Details tab's "Signature" section
/// (`order_detail_screen.dart`), matching the web portal's read-only "Signed
/// confirmation" panel (image + "Signed by X" + date).
class SignatureImageAndCaption extends StatelessWidget {
  const SignatureImageAndCaption({super.key, required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    final url = item.signatureUrl;
    final signerName = item.signerName;
    final signedAt = item.signedAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (url != null && url.isNotEmpty)
          GestureDetector(
            onTap: () => showPhotoViewer(context, urls: [url], initial: url),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(context.radii.card),
                border: Border.all(color: FeColors.line),
              ),
              child: Image.network(
                url,
                height: 140,
                fit: BoxFit.contain,
                errorBuilder: (context, _, _) => Container(
                  height: 140,
                  alignment: Alignment.center,
                  child: const Icon(
                    LucideIcons.image,
                    size: 24,
                    color: FeColors.ink2,
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        AppText.bodyMedium(
          signerName != null && signerName.isNotEmpty
              ? context.formatString(
                  'order_detail.signed_by'.getString(context),
                  [signerName],
                )
              : 'order_detail.signed'.getString(context),
          weight: FontWeight.w700,
        ),
        if (signedAt != null) ...[
          const SizedBox(height: 4),
          AppText.caption(
            formatHistoryTimestamp(signedAt),
            color: FeColors.ink2,
          ),
        ],
      ],
    );
  }
}

class _TimeLog extends StatelessWidget {
  const _TimeLog({required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = item.sessions.reversed.toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: FeColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(context.radii.xl),
        boxShadow: FeElevation.tinted(FeColors.primary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.clock, size: 16, color: FeColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: AppText.titleSmall(
                  'order_detail.time_tracking'.getString(context),
                  color: FeColors.primary,
                  weight: FontWeight.w700,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: FeColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(context.radii.md),
                ),
                child: AppText(
                  context.formatString(
                    'order_detail.total_time'.getString(context),
                    [formatMinutesAsHours(item.timeSpent ?? 0)],
                  ),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: FeColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (sessions.isEmpty)
            AppText.bodySmall(
              'order_detail.no_sessions'.getString(context),
              color: FeColors.primary,
            )
          else
            for (var i = 0; i < sessions.length; i++)
              _SessionRow(session: sessions[i], number: sessions.length - i),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.number});

  final ChecklistSession session;
  final int number;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasGeo = session.latitude != null && session.longitude != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TechCard(
        padding: const EdgeInsets.all(12),
        radius: context.radii.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: FeColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(context.radii.sm),
                  ),
                  child: AppText(
                    context.formatString(
                      'order_detail.session_number'.getString(context),
                      [number],
                    ),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: FeColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Verified in and verified out. `cameraOff` used to mark the
                // end capture, which read as "no photo was taken" — the exact
                // opposite of what its presence means.
                if (session.faceCaptureUrl != null)
                  const Icon(
                    LucideIcons.logIn,
                    size: 12,
                    color: FeColors.primary,
                  ),
                if (session.endFaceCaptureUrl != null)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(
                      LucideIcons.logOut,
                      size: 12,
                      color: FeColors.primary,
                    ),
                  ),
                const Spacer(),
                AppText.caption(
                  session.isRunning
                      ? 'order_detail.running'.getString(context)
                      : formatMinutesAsHours(session.timeSpent ?? 0),
                  color: session.isRunning ? FeColors.warning : FeColors.ink2,
                  weight: FontWeight.w700,
                ),
              ],
            ),
            const SizedBox(height: 8),
            AppText(
              session.startTime == null
                  ? '—'
                  : '${formatSessionDate(session.startTime!)} '
                        '${formatSessionTime(session.startTime!)}'
                        '${session.endTime == null ? '' : ' → ${formatSessionTime(session.endTime!)}'}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: FeColors.ink2,
              ),
            ),
            if (hasGeo) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    LucideIcons.mapPin,
                    size: 11,
                    color: FeColors.ink2,
                  ),
                  const SizedBox(width: 4),
                  // The place name where one was resolved, the coordinates
                  // otherwise — a technician reading their own history wants
                  // "where was I", and the numbers only answer that on a map.
                  Expanded(
                    child: AppText(
                      session.placeLabel ??
                          '${session.latitude!.toStringAsFixed(4)}, '
                              '${session.longitude!.toStringAsFixed(4)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: FeColors.ink2,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Notes extends StatelessWidget {
  const _Notes({required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    final notes = [
      if (item.legacyComment != null) ChecklistNote(text: item.legacyComment!),
      ...item.comments,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              LucideIcons.messageSquare,
              size: 16,
              color: FeColors.ink2,
            ),
            const SizedBox(width: 8),
            AppText.titleSmall(
              'order_detail.notes_label'.getString(context),
              weight: FontWeight.w700,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (notes.isEmpty)
          AppText.bodySmall(
            'order_detail.no_notes'.getString(context),
            color: FeColors.ink2,
          )
        else
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TechCard(
                padding: const EdgeInsets.all(12),
                radius: context.radii.card,
                borderColor: FeColors.line,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (note.text.isNotEmpty) AppText.bodySmall(note.text),
                    if (note.audioUrl != null) ...[
                      if (note.text.isNotEmpty) const SizedBox(height: 8),
                      VoiceNotePlayer(
                        audioUrl: note.audioUrl!,
                        durationSeconds: note.durationSeconds,
                      ),
                    ],
                    if (note.createdAt != null) ...[
                      const SizedBox(height: 6),
                      AppText.caption(
                        formatHistoryTimestamp(note.createdAt!),
                        color: FeColors.ink2,
                      ),
                    ],
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.item,
    required this.onAdd,
    required this.onPick,
    required this.onRemove,
  });

  final ChecklistItem item;
  final VoidCallback onAdd;
  final VoidCallback onPick;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.paperclip, size: 16, color: FeColors.ink2),
            const SizedBox(width: 8),
            Expanded(
              child: AppText.titleSmall(
                'order_detail.photos_label'.getString(context),
                weight: FontWeight.w700,
              ),
            ),
            IconButton(
              onPressed: onPick,
              tooltip: 'order_detail.choose_from_gallery'.getString(context),
              icon: const Icon(LucideIcons.image, size: 18),
            ),
            IconButton(
              onPressed: onAdd,
              tooltip: 'order_detail.take_a_photo'.getString(context),
              icon: const Icon(LucideIcons.camera, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (item.attachments.isEmpty)
          AppText.bodySmall(
            'order_detail.no_photos'.getString(context),
            color: FeColors.ink2,
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final url in item.attachments)
                _AttachmentTile(
                  url: url,
                  urls: item.attachments,
                  onRemove: () => onRemove(url),
                ),
            ],
          ),
      ],
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.url,
    required this.urls,
    required this.onRemove,
  });

  final String url;
  final List<String> urls;
  final VoidCallback onRemove;

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: FeColors.panel,
        title: AppText('order_detail.remove_photo_title'.getString(context)),
        content: AppText('order_detail.remove_photo_body'.getString(context)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: AppText('common.cancel'.getString(context)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: FeColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: AppText('common.remove'.getString(context)),
          ),
        ],
      ),
    );
    if (confirmed == true) onRemove();
  }

  @override
  Widget build(BuildContext context) {
    final pending = url.startsWith('__pending_photo_');

    return SizedBox(
      height: 88,
      width: 88,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: pending
                ? null
                : () => showPhotoViewer(context, urls: urls, initial: url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.radii.card),
              child: pending
                  ? Container(
                      color: FeColors.page,
                      alignment: Alignment.center,
                      child: const Icon(
                        LucideIcons.cloudUpload,
                        size: 20,
                        color: FeColors.ink2,
                      ),
                    )
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, _) => Container(
                        color: FeColors.page,
                        alignment: Alignment.center,
                        child: const Icon(
                          LucideIcons.image,
                          size: 20,
                          color: FeColors.ink2,
                        ),
                      ),
                    ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: () => _confirmRemove(context),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.circle,
                ),
                child: const Icon(LucideIcons.x, size: 12, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteComposer extends StatelessWidget {
  const _NoteComposer({
    required this.controller,
    required this.recording,
    required this.amplitudeStream,
    required this.enabled,
    required this.onSend,
    required this.onToggleRecording,
  });

  final TextEditingController controller;
  final bool recording;
  final Stream<Amplitude>? amplitudeStream;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onToggleRecording;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    decoration: const BoxDecoration(
      color: FeColors.panel,
      border: Border(top: BorderSide(color: FeColors.line)),
    ),
    child: Row(
      children: [
        Expanded(
          child: recording && amplitudeStream != null
              ? VoiceWaveform(
                  amplitudeStream: amplitudeStream!,
                  color: FeColors.primary,
                )
              : TextField(
                  controller: controller,
                  enabled: enabled && !recording,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: 'order_detail.add_note_hint'.getString(context),
                    isDense: true,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: enabled ? onToggleRecording : null,
          tooltip: recording
              ? 'order_detail.stop_recording'.getString(context)
              : 'order_detail.record_voice_note_tooltip'.getString(context),
          style: IconButton.styleFrom(
            backgroundColor: recording ? FeColors.dangerSoft : null,
          ),
          icon: Icon(
            recording ? LucideIcons.square : LucideIcons.mic,
            size: 20,
            color: recording ? FeColors.danger : FeColors.primary,
          ),
        ),
        IconButton(
          onPressed: enabled && !recording ? onSend : null,
          tooltip: 'order_detail.send_note'.getString(context),
          icon: const Icon(LucideIcons.send, size: 20),
        ),
      ],
    ),
  );
}
