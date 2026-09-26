import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/router.dart';
import '../../domain/permit.dart';
import '../../state/permit_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/theme_extensions.dart';
import '../../widgets/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import 'widgets/permit_card.dart';

/// "My permits" (docs/permit-to-work.md): Live / Upcoming / Done, merged
/// across the crew and raised queries. This is the app's own list, not the
/// office web board — approvals, issue and close-out stay web-only, so
/// there is nothing here for a `draft` permit besides watching it move.
enum PermitTab { live, upcoming, done }

extension on PermitTab {
  bool matches(PermitSummary p) => switch (this) {
    PermitTab.live => p.status == 'active' || p.status == 'suspended' || p.status == 'work_complete',
    PermitTab.upcoming => p.status == 'draft' || p.status == 'submitted' || p.status == 'approved',
    PermitTab.done => p.status.isTerminalPermitStatus || p.status == 'expired',
  };

  String label(BuildContext context) => switch (this) {
    PermitTab.live => 'permits.tab_live'.getString(context),
    PermitTab.upcoming => 'permits.tab_upcoming'.getString(context),
    PermitTab.done => 'permits.tab_done'.getString(context),
  };
}

class PermitsHubScreen extends ConsumerStatefulWidget {
  const PermitsHubScreen({super.key});

  @override
  ConsumerState<PermitsHubScreen> createState() => _PermitsHubScreenState();
}

class _PermitsHubScreenState extends ConsumerState<PermitsHubScreen> {
  PermitTab _tab = PermitTab.live;

  Future<void> _refresh() async {
    ref.invalidate(myPermitsProvider);
    await ref.read(myPermitsProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(myPermitsProvider);
    final catalogAsync = ref.watch(permitCatalogProvider);
    final catalog = catalogAsync.valueOrNull ?? PermitCatalog.empty;

    return Scaffold(
      backgroundColor: FeColors.page,
      appBar: FeHeader(
        title: 'permits.title'.getString(context),
        actions: [
          IconButton(
            tooltip: 'permits.scan_worksite_qr'.getString(context),
            icon: const Icon(LucideIcons.qrCode, size: 20),
            onPressed: () => context.push(Routes.scan),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: items.when(
            loading: () => const Center(child: TechSpinner()),
            error: (error, stack) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TechEmptyState(
                  icon: LucideIcons.cloudOff,
                  title: 'permits.load_error'.getString(context),
                ),
              ],
            ),
            data: (all) {
              final filtered = all.where((i) => _tab.matches(i.summary)).toList();
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _TabRow(tab: _tab, onChanged: (t) => setState(() => _tab = t)),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    TechEmptyState(
                      icon: LucideIcons.fileText,
                      title: 'permits.empty_title'.getString(context),
                      subtitle: 'permits.empty_subtitle'.getString(context),
                    )
                  else
                    for (final item in filtered)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: PermitCard(
                          permit: item.summary,
                          catalog: catalog,
                          needsSignature: item.needsSignature,
                          onTap: () => context.push(Routes.permitDetail(item.summary.id)),
                        ),
                      ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TabRow extends StatelessWidget {
  const _TabRow({required this.tab, required this.onChanged});
  final PermitTab tab;
  final ValueChanged<PermitTab> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: FeColors.panel, borderRadius: BorderRadius.circular(999)),
    child: Row(
      children: [
        for (final t in PermitTab.values)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(t),
              child: AnimatedContainer(
                duration: context.motion.fast,
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: t == tab ? FeColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: AppText.bodySmall(
                  t.label(context),
                  weight: FontWeight.w700,
                  color: t == tab ? Colors.white : FeColors.ink2,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
