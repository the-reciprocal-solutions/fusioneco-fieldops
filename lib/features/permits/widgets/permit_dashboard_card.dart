import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/router.dart';
import '../../../state/permit_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/theme_extensions.dart';
import '../../../widgets/motion.dart';
import 'permit_visuals.dart';
import '../../../widgets/dir_icon.dart';

/// The dashboard's door into Permit to Work (docs/permit-to-work.md). Reads
/// only the already-fetched "My permits" list, so it costs nothing extra and
/// stays right offline (last-known counts) — mirrors `SnagDashboardCard`.
class PermitDashboardCard extends ConsumerWidget {
  const PermitDashboardCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(myPermitsProvider).valueOrNull ?? const [];
    final live = items.where((i) => i.summary.isLive).length;
    final needsSignature = items.where((i) => i.needsSignature).length;

    return PressableScale(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => context.push(Routes.permits),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: FeColors.ink,
              borderRadius: BorderRadius.circular(20),
              boxShadow: FeElevation.floating,
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [FeColors.primaryLight, FeColors.primary]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(LucideIcons.shieldCheck, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'permits.title'.getString(context),
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        live == 0
                            ? 'permits.dashboard_sub_empty'.getString(context)
                            : permitTr(context, 'permits.dashboard_sub', [live]),
                        style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                if (needsSignature > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: FeColors.warning, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      permitTr(context, 'permits.dashboard_needs_signature', [needsSignature]),
                      style: const TextStyle(color: FeColors.ink, fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                  )
                else
                  const DirIcon(LucideIcons.arrowRight, color: Colors.white70, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
