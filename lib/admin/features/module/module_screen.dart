import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/catalog_guard.dart';
import '../../catalog/module_icons.dart';
import '../modules/module_spec.dart';
import '../modules/module_summary_screen.dart';
import '../modules/record_detail_screen.dart';
import '../modules/specs.dart';
import '../../state/catalog_controller.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// One module (or one of its pages). Stand-in until the module's real
/// summary screen lands (FE-mobile.md Phase 2/3); the router guard has
/// already checked the catalog allows it.
class ModuleScreen extends ConsumerWidget {
  const ModuleScreen({super.key, required this.moduleId, this.pageId});

  final String moduleId;
  final String? pageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boot = ref.watch(loadedCatalogProvider);
    // go_router re-runs its redirect only for the base location, not for a
    // pushed screen; so an open module re-checks the guard itself when a new
    // catalog lands (config:changed switched it off).
    if (catalogRedirect(boot, Uri(path: modulePath(moduleId), queryParameters: pageId == null ? null : {'page': pageId})) != null) {
      return const UnavailableScreen();
    }
    final module = boot?.module(moduleId);
    String? pageLabel;
    for (final p in module?.pages ?? const []) {
      if (p.id == pageId) pageLabel = p.label;
    }
    // A page has its own spec: "facility_ops:bookings".
    final spec = moduleSpecs[specKey(moduleId, pageId)];
    if (module != null && spec != null) {
      return spec.screen?.call(module) ?? ModuleSummaryScreen(module: module, spec: spec, title: pageLabel);
    }

    return Scaffold(
      appBar: FeHeader(title: pageLabel ?? module?.label ?? ''),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: TechEmptyState(
            icon: module == null ? LucideIcons.construction : moduleIcon(module.icon),
            title: 'common.coming_soon'.getString(context),
            subtitle: 'common.coming_soon_hint'.getString(context),
          ),
        ),
      ),
    );
  }
}

/// One record of a module with a spec. Re-checks the guard like
/// [ModuleScreen]: a pushed screen is not covered by the router's redirect.
class RecordScreen extends ConsumerWidget {
  const RecordScreen({super.key, required this.moduleId, required this.recordId, this.pageId, this.initial});

  final String moduleId;
  final String recordId;
  final String? pageId;
  final Json? initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boot = ref.watch(loadedCatalogProvider);
    final spec = moduleSpecs[specKey(moduleId, pageId)];
    if (spec == null || catalogRedirect(boot, Uri.parse(recordPath(moduleId, recordId, page: pageId))) != null) {
      return const UnavailableScreen();
    }
    return RecordDetailScreen(spec: spec, recordId: recordId, initial: initial);
  }
}

/// Where the guard sends a link to a module this user can't see.
class UnavailableScreen extends StatelessWidget {
  const UnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FeHeader(title: 'catalog.unavailable_title'.getString(context)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: TechEmptyState(
            icon: LucideIcons.lock,
            title: 'catalog.unavailable_title'.getString(context),
            subtitle: 'catalog.unavailable_body'.getString(context),
          ),
        ),
      ),
    );
  }
}
