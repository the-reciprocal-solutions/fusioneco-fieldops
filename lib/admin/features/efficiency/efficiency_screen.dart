import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:go_router/go_router.dart';

import '../../catalog/catalog_guard.dart';
import '../../domain/mobile_catalog.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/fe_header.dart';

/// Building Efficiency: the pages this user may see, in the web's groups
/// (Today, Health areas, Take action, Monitor, Setup). The catalog already
/// dropped every page switched off (effPageOn on the server).
class EfficiencyScreen extends StatelessWidget {
  const EfficiencyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FeHeader(title: 'nav.efficiency'.getString(context)),
      body: CatalogView(
        builder: (context, boot) {
          final pages = boot.module('efficiency')?.pages ?? const <ModulePage>[];
          final groups = <String, List<ModulePage>>{};
          for (final p in pages) {
            groups.putIfAbsent(p.group ?? '', () => []).add(p);
          }
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            children: [
              for (final g in groups.entries)
                RowGroup(
                  label: g.key,
                  dividerIndent: 16,
                  rows: [
                    for (final p in g.value)
                      NavRow(title: p.label, onTap: () => context.push(modulePath('efficiency', page: p.id))),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}
