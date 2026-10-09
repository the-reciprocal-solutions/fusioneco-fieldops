import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/day/process_guides.dart';
import '../../../theme/fe_colors.dart';
import '../../../widgets/app_text.dart';
import 'day_brief_card.dart' show openDayRoute;

/// "How do I…?" — the guides list, one tap from the Your day card.
/// [onAskAi] is null when the account has no AI assistant (`isAiAgent`):
/// the button is then not shown at all.
Future<void> showProcessGuidesSheet(
  BuildContext context, {
  String? nextJobId,
  void Function(String question)? onAskAi,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: FeColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (_, controller) => ProcessGuidesList(
          controller: controller,
          nextJobId: nextJobId,
          onOpen: (route) {
            Navigator.of(sheetContext).pop();
            openDayRoute(context, route);
          },
          onAskAi: onAskAi == null
              ? null
              : (question) {
                  Navigator.of(sheetContext).pop();
                  onAskAi(question);
                },
        ),
      ),
    );

class ProcessGuidesList extends StatelessWidget {
  const ProcessGuidesList({super.key, this.controller, this.nextJobId, required this.onOpen, this.onAskAi});

  final ScrollController? controller;
  final String? nextJobId;
  final void Function(String route) onOpen;
  final void Function(String question)? onAskAi;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Center(
          child: Container(width: 40, height: 4, decoration: BoxDecoration(color: FeColors.line, borderRadius: BorderRadius.circular(4))),
        ),
        const SizedBox(height: 12),
        AppText.titleMedium('day.guides_title'.getString(context), weight: FontWeight.w800),
        AppText.caption('day.guides_sub'.getString(context), color: FeColors.ink2),
        const SizedBox(height: 8),
        for (final g in kProcessGuides)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: Key('guide-${g.id}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 12),
              title: AppText.label(g.titleKey.getString(context), weight: FontWeight.w700),
              children: [
                for (final (i, key) in g.stepKeys.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(color: FeColors.infoSoft, shape: BoxShape.circle),
                          child: Text('${i + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: FeColors.primary)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: AppText.bodySmall(key.getString(context), color: FeColors.ink)),
                      ],
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    OutlinedButton.icon(
                      key: Key('guide-open-${g.id}'),
                      onPressed: () => onOpen(g.route(nextJobId: nextJobId)),
                      icon: const Icon(LucideIcons.externalLink, size: 15),
                      label: Text('day.guide.open_screen'.getString(context)),
                    ),
                    if (onAskAi != null)
                      TextButton.icon(
                        key: Key('guide-ask-${g.id}'),
                        onPressed: () => onAskAi!(g.askKey.getString(context)),
                        icon: const Icon(LucideIcons.sparkles, size: 15, color: FeColors.ai),
                        label: Text('day.guide.ask_ai'.getString(context), style: const TextStyle(color: FeColors.ai)),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
