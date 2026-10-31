import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../features/web/web_screen.dart';

/// Opens the same page of the web admin panel — for what the phone only
/// summarises (full charts, 3D, the PDF report) — inside the app and already
/// signed in (FE-mobile.md 0.6, lib/features/web/web_screen.dart). [path] is
/// a web path such as the catalog module's `webPath`.
Future<void> openOnWeb(BuildContext context, String path, {String? title}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WebScreen(path: path, title: title)));

class OpenOnWebButton extends StatelessWidget {
  const OpenOnWebButton({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(LucideIcons.externalLink, size: 20),
        tooltip: 'module.open_on_web'.getString(context),
        onPressed: () => openOnWeb(context, path),
      );
}
