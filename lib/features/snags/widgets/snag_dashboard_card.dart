import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/router.dart';
import '../../../core/snag/snag_rules.dart';
import '../../../domain/snag.dart';
import '../../../state/snag_controller.dart';
import '../../../theme/fe_colors.dart';
import '../../../theme/theme_extensions.dart';
import '../../../widgets/motion.dart';
import 'snag_visuals.dart';
import '../../../widgets/dir_icon.dart';

/// The dashboard's door into the Snag Assistant. Reads only the local store
/// (every building), so it costs nothing and is right offline; the count is
/// what is waiting on *this* technician, which is the only number that
/// should pull them in from the home screen.
class SnagDashboardCard extends ConsumerWidget {
  const SnagDashboardCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(snagActorProvider)?.id ?? '';
    final snags = ref.watch(snagsProvider(null)).valueOrNull ?? const <Snag>[];
    final waiting = SnagQueues.waitingOn(me, snags).length;
    final live = snags.where((s) => s.status.isLive).length;
    return PressableScale(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => context.push(Routes.snags),
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
                  child: const Icon(LucideIcons.scanEye, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'snags.title'.getString(context),
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        live == 0
                            ? 'snags.dashboard_sub_empty'.getString(context)
                            : snagTr(context, 'snags.dashboard_sub', [live]),
                        style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                if (waiting > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: FeColors.warning, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      snagTr(context, 'snags.dashboard_waiting', [waiting]),
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
