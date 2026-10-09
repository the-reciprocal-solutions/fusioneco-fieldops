import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../domain/snag.dart';
import '../../../domain/snag_ai.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import 'snag_region_overlay.dart';
import 'snag_visuals.dart';

/// One suggestion the technician can apply.
enum SnagAiField { title, description, trade, priority, issueType, cause, fix, responsible }

/// The fields "Apply all" applies, in display order.
List<SnagAiField> snagAiFieldsOf(SnagAiResult r) => [
  if (r.title != null) SnagAiField.title,
  if (r.trade != null) SnagAiField.trade,
  if (r.priority != null) SnagAiField.priority,
  if (r.issueType != null) SnagAiField.issueType,
  if (r.description != null) SnagAiField.description,
  if (r.likelyCause != null) SnagAiField.cause,
  if (r.recommendedFix != null) SnagAiField.fix,
  if (r.responsibleTrade != null) SnagAiField.responsible,
];

/// The optional photo check on the snag create step.
///
/// 2026-10-10 (owner): photo analysis is NOT the headline AI feature on a
/// snag any more — the main AI help is the estimate & quote card on the
/// snag detail screen (snag_estimate_card.dart). So this no longer runs by
/// itself and no longer sits in a big highlighted panel: until the
/// technician taps "Check photo" it is one small chip, while it works it is
/// one quiet line, and only an answer gets a (flat) card. The defect
/// highlights are still there on demand.
///
/// Violet is the app's AI-only accent (`FeColors.ai`). It never blocks the
/// snag: the form saves whether or not it has answered, and nothing here
/// changes a field until the technician taps Apply (agents are read-only by
/// default).
class SnagAiPanel extends StatelessWidget {
  const SnagAiPanel({
    super.key,
    required this.running,
    required this.result,
    required this.applied,
    required this.onRun,
    required this.onApply,
    required this.onApplyAll,
    this.onOpenDuplicate,
    this.hasPhoto = true,
    this.photo,
    this.regions = const [],
    this.onDeleteRegion,
  });

  final bool running;
  final SnagAiResult? result;
  final Set<SnagAiField> applied;
  final VoidCallback onRun;
  final ValueChanged<SnagAiField> onApply;
  final VoidCallback onApplyAll;
  final ValueChanged<SnagAiDuplicate>? onOpenDuplicate;
  final bool hasPhoto;

  /// The photo the assistant looked at, and the highlights still kept on it
  /// (the caller owns the list: [onDeleteRegion] removes a wrong box).
  final Uint8List? photo;
  final List<SnagRegion> regions;
  final ValueChanged<int>? onDeleteRegion;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final fields = r == null ? const <SnagAiField>[] : snagAiFieldsOf(r);
    final pendingFields = fields.where((f) => !applied.contains(f)).toList();
    // Quiet until asked: no photo → nothing; a photo → one "Check photo" chip.
    if (!running && r == null) {
      if (!hasPhoto) return const SizedBox.shrink();
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: ActionChip(
          key: const ValueKey('snag-check-photo'),
          onPressed: onRun,
          avatar: const Icon(LucideIcons.scanSearch, size: 15, color: FeColors.ai),
          label: Text('snags.ai.check_photo'.getString(context)),
          labelStyle: const TextStyle(color: FeColors.ai, fontWeight: FontWeight.w600, fontSize: 13),
          side: const BorderSide(color: FeColors.aiLine),
          backgroundColor: Colors.white,
          visualDensity: VisualDensity.compact,
        ),
      );
    }
    if (running) {
      return Row(
        children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: FeColors.ai)),
          const SizedBox(width: 8),
          Expanded(child: AppText.bodySmall('snags.ai.step_photo'.getString(context), color: FeColors.ai)),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: FeColors.aiLine),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _Spark(),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText.titleSmall('snags.ai.photo_title'.getString(context), color: FeColors.ai),
                      AppText.bodySmall('snags.ai.photo_subtitle'.getString(context), color: FeColors.ink2),
                    ],
                  ),
                ),
                if (!running && r?.status == SnagAiStatus.ok && pendingFields.length > 1)
                  FilledButton.tonal(
                    onPressed: onApplyAll,
                    style: FilledButton.styleFrom(
                      backgroundColor: FeColors.ai,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text('snags.ai.apply_all'.getString(context)),
                  )
                else if (!running && r == null)
                  FilledButton.tonalIcon(
                    onPressed: hasPhoto ? onRun : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: FeColors.ai,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(LucideIcons.sparkles, size: 14),
                    label: Text('snags.ai.run'.getString(context)),
                  ),
              ],
            ),
            if (running) ...[const SizedBox(height: 12), const _Thinking()],
            if (!running && r == null && !hasPhoto) ...[
              const SizedBox(height: 8),
              AppText.bodySmall('snags.ai.needs_photo'.getString(context), color: FeColors.ink2),
            ],
            if (!running && r != null) ...[
              if (r.status != SnagAiStatus.ok) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      r.status == SnagAiStatus.offline ? LucideIcons.cloudOff : LucideIcons.circleAlert,
                      size: 16,
                      color: FeColors.ink2,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: AppText.bodySmall(
                        (r.status == SnagAiStatus.offline ? 'snags.ai.offline' : 'snags.ai.unavailable').getString(context),
                        color: FeColors.ink,
                      ),
                    ),
                    TextButton(onPressed: onRun, child: Text('snags.ai.retry'.getString(context))),
                  ],
                ),
              ] else if (fields.isEmpty) ...[
                const SizedBox(height: 8),
                AppText.bodySmall('snags.ai.nothing'.getString(context), color: FeColors.ink2),
              ],
              // Where the defect is: the photo with the AI's highlights, so the
              // technician sees what it means before applying anything.
              if (r.status == SnagAiStatus.ok && photo != null && regions.isNotEmpty) ...[
                const SizedBox(height: 10),
                SnagAnnotatedPhoto(
                  image: MemoryImage(photo!),
                  regions: regions,
                  height: 210,
                  onDelete: onDeleteRegion,
                ),
                const SizedBox(height: 4),
                AppText.caption('snags.ai.regions_hint'.getString(context), color: FeColors.ink2),
              ],
              if (r.status == SnagAiStatus.ok && r.confidence != null && r.confidence! < 0.5) ...[
                const SizedBox(height: 8),
                AppText.bodySmall('snags.ai.low_confidence'.getString(context), color: FeColors.warning),
              ],
              for (final f in fields) ...[
                const SizedBox(height: 8),
                _SuggestionRow(
                  label: 'snags.ai.field.${f.name}'.getString(context),
                  value: _valueOf(context, r, f),
                  applied: applied.contains(f),
                  onApply: () => onApply(f),
                ),
              ],
              if (r.captureTips.isNotEmpty) ...[
                const SizedBox(height: 12),
                _SectionLabel(icon: LucideIcons.camera, text: 'snags.ai.tips_title'.getString(context)),
                for (final t in r.captureTips)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 3),
                          child: Icon(LucideIcons.lightbulb, size: 13, color: FeColors.warning),
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: AppText.bodySmall('snags.ai.tip.$t'.getString(context), color: FeColors.ink)),
                      ],
                    ),
                  ),
              ],
              if (r.duplicates.isNotEmpty) ...[
                const SizedBox(height: 12),
                _SectionLabel(icon: LucideIcons.copy, text: 'snags.ai.dupes_title'.getString(context)),
                for (final d in r.duplicates)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: onOpenDuplicate == null ? null : () => onOpenDuplicate!(d),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: FeColors.line),
                        ),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: d.coverUrl == null
                                  ? Container(width: 40, height: 40, color: FeColors.line)
                                  : Image.network(
                                      d.coverUrl!,
                                      width: 40,
                                      height: 40,
                                      fit: BoxFit.cover,
                                      cacheWidth: 120,
                                      errorBuilder: (_, _, _) => Container(width: 40, height: 40, color: FeColors.line),
                                    ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AppText.bodySmall(d.displayRef, color: FeColors.ink2, weight: FontWeight.w700),
                                  AppText.bodyMedium(d.title ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            AppText.bodySmall(SnagVisuals.statusLabel(context, d.status), color: FeColors.ink2),
                            const Icon(LucideIcons.chevronRight, size: 16, color: FeColors.ink2),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
              if (r.missing.isNotEmpty) ...[
                const SizedBox(height: 12),
                _SectionLabel(icon: LucideIcons.listTodo, text: 'snags.ai.missing_title'.getString(context)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final m in r.missing)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: FeColors.warningSoft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'snags.ai.missing.$m'.getString(context),
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: FeColors.ink),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  static String _valueOf(BuildContext context, SnagAiResult r, SnagAiField f) => switch (f) {
    SnagAiField.title => r.title ?? '',
    SnagAiField.description => r.description ?? '',
    SnagAiField.trade => SnagVisuals.tradeLabel(context, r.trade!),
    SnagAiField.priority => SnagVisuals.priorityLabel(context, r.priority!),
    SnagAiField.issueType => SnagVisuals.issueLabel(context, r.issueType!),
    SnagAiField.cause => r.likelyCause ?? '',
    SnagAiField.fix => r.recommendedFix ?? '',
    SnagAiField.responsible => SnagVisuals.tradeLabel(context, r.responsibleTrade!),
  };
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.label, required this.value, required this.applied, required this.onApply});
  final String label;
  final String value;
  final bool applied;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: applied ? FeColors.aiLine : FeColors.line),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText.bodySmall(label, color: FeColors.ink2, weight: FontWeight.w600),
              AppText.bodyMedium(value, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        applied
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(LucideIcons.check, size: 14, color: FeColors.ai),
                    const SizedBox(width: 3),
                    Text(
                      'snags.ai.applied'.getString(context),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: FeColors.ai),
                    ),
                  ],
                ),
              )
            : TextButton(
                onPressed: onApply,
                style: TextButton.styleFrom(foregroundColor: FeColors.ai),
                child: Text('snags.ai.apply'.getString(context)),
              ),
      ],
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 14, color: FeColors.ai),
      const SizedBox(width: 6),
      AppText.bodySmall(text, color: FeColors.ink, weight: FontWeight.w700),
    ],
  );
}

class _Spark extends StatelessWidget {
  const _Spark();

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(color: FeColors.ai.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
    child: const Icon(LucideIcons.sparkles, size: 18, color: FeColors.ai),
  );
}

/// The working state: pulsing dots and a line that walks through what the
/// assistant is doing, so ~8 s of waiting reads as progress, not a hang.
class _Thinking extends StatefulWidget {
  const _Thinking();

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat();
  static const _steps = ['snags.ai.step_photo', 'snags.ai.step_nearby', 'snags.ai.step_draft'];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final elapsed = (_c.lastElapsedDuration?.inMilliseconds ?? 0);
        final step = _steps[(elapsed ~/ 2400) % _steps.length];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Opacity(
                      opacity: 0.3 + 0.7 * (((_c.value * 3 - i) % 3) < 1 ? 1 : 0),
                      child: const CircleAvatar(radius: 4, backgroundColor: FeColors.ai),
                    ),
                  ),
                const SizedBox(width: 6),
                Expanded(child: AppText.bodySmall(step.getString(context), color: FeColors.ai, weight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 10),
            for (final w in const [0.9, 0.6, 0.75])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: FractionallySizedBox(
                  widthFactor: w,
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                      color: FeColors.aiLine.withValues(alpha: 0.4 + 0.4 * _c.value),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// "AI suggested" marker next to a field whose value came from the panel.
class SnagAiBadge extends StatelessWidget {
  const SnagAiBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: FeColors.aiSoft, borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(LucideIcons.sparkles, size: 11, color: FeColors.ai),
        const SizedBox(width: 3),
        Text(
          'snags.ai.badge'.getString(context),
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: FeColors.ai),
        ),
      ],
    ),
  );
}
