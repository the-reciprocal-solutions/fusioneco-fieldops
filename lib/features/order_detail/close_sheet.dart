import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:signature/signature.dart';

import '../../core/offline/sync_client.dart';
import '../../core/utils/checklist_status.dart';
import '../../core/utils/dates.dart';
import '../../domain/checklist.dart';
import '../../domain/downtime.dart';
import '../../domain/maintenance_record.dart';
import '../../state/auth_controller.dart';
import '../../state/checklist_controller.dart';
import '../../state/close_controller.dart';
import '../../state/order_detail_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/tech_popup.dart';

/// The one screen that closes a job: how long the asset was down, and — for
/// Critical and High priority — why it went wrong. Submitting runs root cause,
/// then downtime, then the completion call.
class CloseSheet extends ConsumerStatefulWidget {
  const CloseSheet({
    super.key,
    required this.orderKey,
    required this.record,
    required this.predictedStart,
    this.manualHours,
  });

  final OrderKey orderKey;
  final MaintenanceRecord record;

  /// When the first checklist item was started. The downtime window defaults to
  /// this rather than to blank, because it is nearly always the right answer.
  final DateTime? predictedStart;
  final double? manualHours;

  @override
  ConsumerState<CloseSheet> createState() => _CloseSheetState();
}

class _CloseSheetState extends ConsumerState<CloseSheet> {
  late final CloseSubmitter _submitter = CloseSubmitter(
    ref.read(closeRepositoryProvider),
  );
  final _notesController = TextEditingController();

  // Digital-signature sign-off (2026-09-09) — step 3, required unconditionally
  // (unlike root cause, which only shows for Critical/High priority). See
  // `checklistCloseGuard.ts` (server) for the rule this UI exists to satisfy.
  late final SignatureController _sigController = SignatureController(
    penColor: FeColors.ink,
    penStrokeWidth: 3,
    exportBackgroundColor: Colors.white,
    // The pad has no listenable "changed" stream of its own — this is what
    // makes the Confirm button re-evaluate `_sigController.isEmpty` as soon
    // as a stroke ends, the same way `setState` re-evaluates every other
    // gate in this sheet.
    onDrawEnd: () => setState(() {}),
  );
  late final _signerNameController = TextEditingController(
    text: ref.read(authControllerProvider).session?.name ?? '',
  );

  DateTime? _start;
  DateTime? _end;
  DowntimeImpact _impact = DowntimeImpact.fullOutage;

  /// Start and end are still the guess (first checklist start → now) rather
  /// than a real recorded window or something the technician typed. The reset
  /// button only appears once they have diverged from it.
  bool _predicted = true;

  /// A window already running on this record. It fixes the start time — that
  /// moment is recorded fact, not something to re-enter.
  DowntimeWindow? _openWindow;

  /// A window open on another record for the same asset. Informational only:
  /// each record owns its own window, so there is nothing to collide with.
  DowntimeWindow? _otherOpenWindow;
  bool _windowsApplied = false;

  String? _rootCause;
  String? _rootCauseError;

  /// Set when the server itself names `rootCause` as missing. Its answer beats
  /// our priority guess: a field error must never land on a control that is not
  /// on screen, which would leave the sheet unclosable with nothing to fix.
  bool _forceRcaVisible = false;

  bool _submitting = false;

  bool get _rcaVisible =>
      rcaRequiredForPriority(widget.record.priority) || _forceRcaVisible;

  @override
  void initState() {
    super.initState();
    _start = widget.predictedStart ?? DateTime.now();
    _end = DateTime.now();
  }

  @override
  void dispose() {
    _notesController.dispose();
    _sigController.dispose();
    _signerNameController.dispose();
    super.dispose();
  }

  void _applyPredicted() {
    setState(() {
      _start = widget.predictedStart ?? DateTime.now();
      _end = DateTime.now();
      _predicted = true;
    });
  }

  /// Folds the fetched history in once. Doing it in `build` would overwrite the
  /// technician's own edits every time the provider rebuilt.
  void _applyWindows(List<DowntimeWindow> history) {
    if (_windowsApplied) return;
    _windowsApplied = true;

    final stillOpen = history.where((w) => w.isOpen).toList();
    final mine = stillOpen
        .where(
          (w) =>
              w.source == widget.record.type.downtimeSource &&
              w.sourceId == widget.record.id,
        )
        .firstOrNull;

    _openWindow = mine;
    _otherOpenWindow = mine == null ? stillOpen.firstOrNull : null;
    if (mine != null) {
      _start = mine.startedAt;
      _end = DateTime.now();
      _predicted = false;
    }
  }

  Future<void> _pick({required bool isStart}) async {
    final current = (isStart ? _start : _end) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 2),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !mounted) return;

    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (isStart) {
        _start = picked;
      } else {
        _end = picked;
      }
      _predicted = false;
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _rootCauseError = null;
    });

    // Signature sign-off (2026-09-09) — saved first, through the SAME
    // checklist-item call path "Add Other Task" uses (`addSignature` on
    // `ChecklistController`, mirroring `addOther`), so it rides the offline
    // queue like every other write here. It has to land before the
    // completion call below: the server's `checklistCloseGuard.ts` reads the
    // signature out of the record's `checklists`, so a close sent before the
    // signature write is queued (offline) or applied (online) would still
    // 422. The Confirm button is disabled while the pad is empty (see
    // `build`), so reaching here with nothing already signed means there is
    // a stroke to upload.
    final items = ref.read(checklistControllerProvider(widget.orderKey)).items;
    if (!hasRequiredSignature(items)) {
      final pngBytes = await _sigController.toPngBytes();
      if (pngBytes == null) {
        setState(() => _submitting = false);
        if (!mounted) return;
        showTechPopup(
          context,
          message: 'order_detail.signature_required'.getString(context),
          isError: true,
        );
        return;
      }
      final signatureOutcome = await ref
          .read(checklistControllerProvider(widget.orderKey).notifier)
          .addSignature(
            pngBytes: pngBytes,
            signerName: _signerNameController.text.trim(),
          );
      if (!mounted) return;
      if (signatureOutcome != null && !signatureOutcome.queued) {
        // A real failure, not a queue notice — the signature never saved, so
        // closing now would only hit the server's own signature gate. Stop
        // here and let the technician retry rather than sending a close the
        // guard is guaranteed to reject.
        setState(() => _submitting = false);
        showTechPopup(context, message: signatureOutcome.text, isError: true);
        return;
      }
    }

    final result = await _submitter.submit(
      CloseRequest(
        type: widget.record.type,
        recordId: widget.record.id,
        rootCause: _rootCause,
        rcaNotes: _notesController.text.trim(),
        downtimeStart: _start,
        downtimeEnd: _end,
        impact: _impact,
        hasAsset: widget.record.assetId != null,
        hasOpenWindow: _openWindow != null,
        manualHours: widget.manualHours,
      ),
    );
    if (!mounted) return;

    switch (result) {
      case CloseSucceeded(:final queued):
        await ref
            .read(orderDetailControllerProvider(widget.orderKey).notifier)
            .refresh();
        if (!mounted) return;
        Navigator.of(context).pop(
          queued
              ? kOfflineQueuedMessage
              : 'order_detail.job_closed_message'.getString(context),
        );
      case CloseAlreadyClosed():
        await ref
            .read(orderDetailControllerProvider(widget.orderKey).notifier)
            .refresh();
        if (!mounted) return;
        Navigator.of(context)
            .pop('order_detail.job_already_closed'.getString(context));
      case CloseRejected(
        :final needsRootCause,
        :final needsChecklist,
        :final needsSignature,
        :final message,
      ):
        setState(() {
          _submitting = false;
          if (needsRootCause) {
            _forceRcaVisible = true;
            _rootCauseError =
                'order_detail.root_cause_required'.getString(context);
          }
        });
        // The server's own text is written for whoever is calling the API —
        // the root-cause refusal names an endpoint and a request field. Say
        // it in the technician's terms when the gate is one we know, and
        // fall back to the server's wording only for a gate we do not.
        //
        // `needsSignature` should be rare in practice — the signature is
        // saved before this call runs (see `_submit`) — but is still
        // possible if that write only queued offline and has not synced by
        // the time the completion call itself reaches the server.
        showTechPopup(
          context,
          message: needsRootCause
              ? 'order_detail.choose_root_cause_message'.getString(context)
              : needsChecklist
              ? 'order_detail.complete_checklist_message'.getString(context)
              : needsSignature
              ? 'order_detail.signature_needed_message'.getString(context)
              : message,
          isError: true,
        );
      case CloseFailed(:final message):
        setState(() => _submitting = false);
        showTechPopup(context, message: message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final assetId = widget.record.assetId;
    final history = assetId == null
        ? const AsyncValue<List<DowntimeWindow>>.data([])
        : ref.watch(downtimeHistoryProvider(assetId));
    history.whenData(_applyWindows);

    // Live checklist items, not `widget.record.checklists` — the same source
    // `ChecklistTab`'s own close gate reads, so a signature (or anything
    // else) added earlier in this session shows immediately.
    final checklistItems =
        ref.watch(checklistControllerProvider(widget.orderKey)).items;
    final alreadySigned = hasRequiredSignature(checklistItems);
    final signatureItem = findSignatureItem(checklistItems);
    final signaturePending = !alreadySigned && _sigController.isEmpty;

    // The modal route caps this sheet at a fixed fraction of the screen and
    // never accounts for the keyboard — without this padding the keyboard
    // just overlaps the sheet's bottom edge, hiding the Notes field and the
    // Cancel/Confirm buttons below it, neither of which can scroll into view
    // on their own (mirrors order_chat_sheet.dart's composer).
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText.titleMedium(
                          context.formatString(
                            'order_detail.close_title'.getString(context),
                            [widget.record.type.displayLabel(context).toLowerCase()],
                          ),
                          weight: FontWeight.w800,
                        ),
                        const SizedBox(height: 2),
                        AppText.bodySmall(
                          'order_detail.close_subtitle'.getString(context),
                          color: FeColors.ink2,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons.x, size: 20),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText.titleSmall(
                      'order_detail.close_step1_title'.getString(context),
                      weight: FontWeight.w700,
                    ),
                    const SizedBox(height: 4),
                    AppText.bodySmall(
                      'order_detail.close_step1_subtitle'.getString(context),
                      color: FeColors.ink2,
                    ),
                    const SizedBox(height: 12),
                    if (assetId == null)
                      _CloseNote(
                        icon: LucideIcons.info,
                        text: 'order_detail.no_asset_downtime'.getString(context),
                      )
                    else if (history.isLoading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else ...[
                      if (_openWindow != null)
                        _CloseNote(
                          icon: LucideIcons.timerReset,
                          text: context.formatString(
                            'order_detail.downtime_running'.getString(context),
                            [formatDateTimeShort(_openWindow!.startedAt)],
                          ),
                        )
                      else if (_otherOpenWindow != null)
                        _CloseNote(
                          icon: LucideIcons.triangleAlert,
                          tone: FeColors.warning,
                          text: context.formatString(
                            'order_detail.other_window_downtime'.getString(context),
                            [
                              _otherOpenWindow!.reference ??
                                  'order_detail.another_record'.getString(context),
                              formatDateTimeShort(_otherOpenWindow!.startedAt),
                            ],
                          ),
                        )
                      else if (_predicted)
                        _CloseNote(
                          icon: LucideIcons.timerReset,
                          text: 'order_detail.downtime_predicted_note'
                              .getString(context),
                        ),
                      if (_openWindow == null && !_predicted)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton.icon(
                            onPressed: _applyPredicted,
                            icon: const Icon(LucideIcons.timerReset, size: 14),
                            label: AppText(
                              'order_detail.reset_to_predicted'.getString(context),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      _DateTimeField(
                        label: 'order_detail.down_since_label'.getString(context),
                        value: _start,
                        // A running window's start is recorded fact.
                        onTap: _openWindow != null || _submitting
                            ? null
                            : () => _pick(isStart: true),
                      ),
                      const SizedBox(height: 12),
                      _DateTimeField(
                        label:
                            'order_detail.running_again_label'.getString(context),
                        value: _end,
                        onTap: _submitting ? null : () => _pick(isStart: false),
                      ),
                      const SizedBox(height: 12),
                      AppText.labelMedium(
                        'order_detail.impact_label'.getString(context),
                        color: FeColors.ink2,
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<DowntimeImpact>(
                        initialValue: _impact,
                        isExpanded: true,
                        items: [
                          for (final option in DowntimeImpact.values)
                            DropdownMenuItem(
                              value: option,
                              child: AppText.bodyMedium(
                                option.displayLabel(context),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _submitting
                            ? null
                            : (value) =>
                                  setState(() => _impact = value ?? _impact),
                      ),
                    ],
                    if (_rcaVisible) ...[
                      const SizedBox(height: 24),
                      AppText.titleSmall(
                        'order_detail.close_step2_title'.getString(context),
                        weight: FontWeight.w700,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _rootCause,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: 'order_detail.root_cause_label'.getString(context),
                          errorText: _rootCauseError,
                          // The default single line clipped this to "…at …",
                          // which told the technician nothing.
                          errorMaxLines: 3,
                        ),
                        items: [
                          for (final option in kRootCauseOptions)
                            DropdownMenuItem(
                              value: option,
                              child: AppText.bodyMedium(
                                displayRootCause(context, option),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _submitting
                            ? null
                            : (value) => setState(() {
                                _rootCause = value;
                                _rootCauseError = null;
                              }),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _notesController,
                        enabled: !_submitting,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: 'order_detail.notes_label'.getString(context),
                          hintText: 'order_detail.notes_hint'.getString(context),
                        ),
                      ),
                    ],
                    // Signature sign-off — step 3, required unconditionally
                    // (see checklistCloseGuard.ts), so unlike the RCA block
                    // above this is never hidden by priority.
                    const SizedBox(height: 24),
                    AppText.titleSmall(
                      'order_detail.close_step3_title'.getString(context),
                      weight: FontWeight.w700,
                    ),
                    const SizedBox(height: 4),
                    AppText.bodySmall(
                      'order_detail.close_step3_subtitle'.getString(context),
                      color: FeColors.ink2,
                    ),
                    const SizedBox(height: 12),
                    if (alreadySigned)
                      _SignedSummary(item: signatureItem)
                    else ...[
                      TextField(
                        controller: _signerNameController,
                        enabled: !_submitting,
                        decoration: InputDecoration(
                          labelText:
                              'order_detail.signer_name_label'.getString(context),
                          hintText:
                              'order_detail.signer_name_hint'.getString(context),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(context.radii.md),
                          border: Border.all(color: FeColors.line),
                        ),
                        child: Signature(
                          controller: _sigController,
                          height: 160,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          // Only while the pad is empty: once a stroke is
                          // drawn the "required" hint read as still missing.
                          Expanded(
                            child: signaturePending
                                ? AppText.caption(
                                    'order_detail.signature_required'
                                        .getString(context),
                                    color: FeColors.ink2,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          TextButton.icon(
                            onPressed: _submitting
                                ? null
                                : () => setState(_sigController.clear),
                            icon: const Icon(LucideIcons.rotateCcw, size: 14),
                            label: AppText(
                              'order_detail.clear_signature'.getString(context),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: FeColors.line),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      child: AppText('common.cancel'.getString(context)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _submitting || signaturePending
                          ? null
                          : _submit,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: FeColors.success,
                      ),
                      child: _submitting
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : AppText('order_detail.confirm_close'.getString(context)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tap target that reads like a field. The platform pickers do the editing;
/// a technician in gloves is not typing a timestamp.
class _DateTimeField extends StatelessWidget {
  const _DateTimeField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final locked = onTap == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText.labelMedium(label, color: FeColors.ink2),
        const SizedBox(height: 6),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(context.radii.md),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: locked ? FeColors.page : FeColors.panel,
              borderRadius: BorderRadius.circular(context.radii.md),
              border: Border.all(color: FeColors.line),
            ),
            child: Row(
              children: [
                Icon(
                  locked ? LucideIcons.lock : LucideIcons.calendar,
                  size: 16,
                  color: FeColors.ink2,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AppText.bodyMedium(
                    value == null
                        ? 'order_detail.not_set'.getString(context)
                        : formatDateTimeShort(value!),
                    color: value == null ? FeColors.ink2 : FeColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown in place of the signature pad once a signature already exists on
/// this record's checklist (e.g. reopening the sheet after an earlier close
/// attempt got rejected for root cause only). Mirrors the web's own signed
/// confirmation box in `maintenance-checklist-v2.tsx`: image + "Signed by X"
/// + date.
class _SignedSummary extends StatelessWidget {
  const _SignedSummary({required this.item});

  final ChecklistItem? item;

  @override
  Widget build(BuildContext context) {
    final url = item?.signatureUrl;
    final signerName = item?.signerName;
    final signedAt = item?.signedAt;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FeColors.successSoft,
        borderRadius: BorderRadius.circular(context.radii.md),
        border: Border.all(color: FeColors.successSoft),
      ),
      child: Row(
        children: [
          if (url != null && url.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(context.radii.sm),
              child: Container(
                color: Colors.white,
                child: Image.network(
                  url,
                  height: 48,
                  width: 88,
                  fit: BoxFit.contain,
                  errorBuilder: (context, _, _) =>
                      const SizedBox(height: 48, width: 88),
                ),
              ),
            )
          else
            const Icon(LucideIcons.penLine, size: 20, color: FeColors.success),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText.bodySmall(
                  signerName != null && signerName.isNotEmpty
                      ? context.formatString(
                          'order_detail.signed_by'.getString(context),
                          [signerName],
                        )
                      : 'order_detail.signed'.getString(context),
                  weight: FontWeight.w700,
                ),
                if (signedAt != null) ...[
                  const SizedBox(height: 2),
                  AppText.caption(
                    formatDateTimeShort(signedAt),
                    color: FeColors.ink2,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseNote extends StatelessWidget {
  const _CloseNote({
    required this.icon,
    required this.text,
    this.tone = FeColors.info,
  });

  final IconData icon;
  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: tone == FeColors.warning
          ? FeColors.warningSoft
          : FeColors.infoSoft,
      borderRadius: BorderRadius.circular(context.radii.md),
      border: Border.all(
        color: tone == FeColors.warning
            ? FeColors.warningSoft
            : FeColors.infoSoft,
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: tone),
        const SizedBox(width: 10),
        Expanded(child: AppText.bodySmall(text, color: FeColors.ink2)),
      ],
    ),
  );
}
