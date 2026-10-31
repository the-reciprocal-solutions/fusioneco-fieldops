import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../../domain/mobile_catalog.dart';
import '../../widgets/catalog_view.dart';
import '../../widgets/fe_header.dart';

/// Operations tab: Facility Management, Facility Ops and AMC modules the
/// catalog marks `navTab: operations`.
class OperationsScreen extends StatelessWidget {
  const OperationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FeHeader(title: 'nav.operations'.getString(context)),
      body: CatalogView(
        builder: (context, boot) => ModuleGroupList(modules: boot.forTab(NavTab.operations)),
      ),
    );
  }
}
