import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../widgets/common.dart';
import '../../widgets/fe_header.dart';

/// Stand-in for a tab whose real screen comes in Phase 2/3.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.titleKey});

  final String titleKey;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FeHeader(title: titleKey.getString(context)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: TechEmptyState(
            icon: LucideIcons.construction,
            title: 'common.coming_soon'.getString(context),
            subtitle: 'common.coming_soon_hint'.getString(context),
          ),
        ),
      ),
    );
  }
}
