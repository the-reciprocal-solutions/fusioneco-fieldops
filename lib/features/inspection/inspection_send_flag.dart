import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/inspection/inspection_send_state.dart';
import '../../state/inspection_controller.dart';
import '../../theme/fe_colors.dart';
import '../../widgets/app_text.dart';

/// A one-line "Waiting to send" / "Not sent" flag for an inspection card.
class InspectionSendFlag extends ConsumerWidget {
  const InspectionSendFlag({super.key, required this.assignmentId, required this.serverStatus});

  final String assignmentId;
  final String serverStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref
        .watch(inspectionSendStatusProvider((id: assignmentId, serverStatus: serverStatus)))
        .valueOrNull;
    if (status == null) return const SizedBox.shrink();
    final notSent = status.state == InspectionSendState.notSent;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            notSent ? LucideIcons.circleAlert : LucideIcons.cloudUpload,
            size: 14,
            color: notSent ? FeColors.danger : FeColors.warning,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: AppText.bodySmall(
              status.labelKey.getString(context),
              weight: FontWeight.w600,
              color: notSent ? FeColors.danger : FeColors.warning,
            ),
          ),
        ],
      ),
    );
  }
}
