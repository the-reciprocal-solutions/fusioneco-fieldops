import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/catalog_guard.dart';
import '../../core/network/api_exception.dart';
import '../../domain/mobile_catalog.dart';
import '../../state/providers.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/fe_header.dart';
import '../modules/module_spec.dart';
import '../modules/scan_screen.dart';
import '../photo_twin/photo_twin_screens.dart';

/// Operations tab: Facility Management, Facility Ops and AMC modules the
/// catalog marks `navTab: operations`, then the quick actions.
class OperationsScreen extends StatelessWidget {
  const OperationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FeHeader(title: 'nav.operations'.getString(context), subtitle: 'nav.operations_sub'.getString(context), art: FeArt.operations),
      body: CatalogView(
        builder: (context, boot) => ModuleGroupList(modules: boot.forTab(NavTab.operations), grid: true, footer: [_QuickActions(boot: boot)]),
      ),
    );
  }
}

/// The shortcuts this user's modules allow: raise a reactive ticket, scan an
/// asset's code. Each reuses the existing screen.
class _QuickActions extends ConsumerWidget {
  const _QuickActions({required this.boot});
  final MobileBootstrap boot;

  Future<void> _report(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final body = await ref.read(apiClientProvider).get('/api/snags/locations/buildings');
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => ReportIssueScreen(buildings: rowsOf(body))));
    } on ApiFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(e.message)));
    }
  }

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final raw = await ref.read(scanCodeProvider)(context);
    if (raw == null || !context.mounted) return;
    final id = assetIdFromScan(raw);
    context.push(id == null ? modulePath('assets') : recordPath('assets', id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = boot.has('reactive');
    final scan = boot.has('assets');
    if (!report && !scan) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel('ops.quick_actions'.getString(context)),
          Row(
            children: [
              if (report)
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () => _report(context, ref),
                    icon: const Icon(LucideIcons.plus, size: 18),
                    label: AppText('twin.report'.getString(context), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              if (report && scan) const SizedBox(width: 10),
              if (scan)
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () => _scan(context, ref),
                    icon: const Icon(LucideIcons.scanLine, size: 18),
                    label: AppText('ops.scan_asset'.getString(context), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
