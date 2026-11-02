import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../catalog/catalog_guard.dart';
import '../../catalog/module_icons.dart';
import '../../domain/mobile_catalog.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/fe_header.dart';

/// A module made of pages (Facility Ops): the pages the catalog sent, each
/// opening its own spec (`facility_ops:bookings` …).
class ModulePagesScreen extends StatelessWidget {
  const ModulePagesScreen({super.key, required this.module});
  final MobileModule module;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: FeHeader(title: module.label),
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
