import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../catalog/catalog_guard.dart';
import '../../catalog/module_icons.dart';
import '../../domain/mobile_catalog.dart';
import '../../widgets/app_text.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';
import '../../widgets/open_on_web.dart';

/// A module made of pages (Facility Ops): the pages the catalog sent, each
/// opening its own spec (`facility_ops:bookings` …).
class ModulePagesScreen extends StatelessWidget {
  const ModulePagesScreen({super.key, required this.module});
  final MobileModule module;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: FeHeader(title: module.label, actions: [OpenOnWebButton(path: module.webPath)]),
        body: ListView(
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            RowGroup(
              label: module.group,
              rows: [
                for (final p in module.pages)
                  NavRow(title: p.label, icon: moduleIcon(module.icon), onTap: () => context.push(modulePath(module.id, page: p.id))),
              ],
            ),
          ],
        ),
      );
}

/// A module the phone only points to (FE-mobile.md: "view"): what it is,
/// and a button to open it on the web.
class WebOnlyScreen extends StatelessWidget {
  const WebOnlyScreen({super.key, required this.module, required this.hintKey});
  final MobileModule module;

  /// i18n key: one line on what the web page does.
  final String hintKey;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: FeHeader(title: module.label),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TechEmptyState(icon: moduleIcon(module.icon), title: module.label, subtitle: hintKey.getString(context)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => openOnWeb(context, module.webPath),
                  icon: const Icon(LucideIcons.externalLink, size: 16),
                  label: AppText('module.open_on_web'.getString(context)),
                ),
              ],
            ),
          ),
        ),
      );
}
