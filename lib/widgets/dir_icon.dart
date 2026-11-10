import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// An [Icon] whose arrow means "back", "next", "open", "send", "sign in/out"
/// or "undo/redo": mirrored in right-to-left (Arabic) so it points the way
/// the layout reads.
///
/// Lucide icons don't set `matchTextDirection`, and building a non-const
/// `IconData` to set it breaks icon tree-shaking in release builds, so the
/// mirroring is a [Transform.flip] instead. Don't use it for arrows that point
/// at something physical (an AR nudge, a drawing tool).
class DirIcon extends StatelessWidget {
  const DirIcon(this.icon, {super.key, this.size, this.color, this.semanticLabel}) : _always = true;

  /// For shared widgets that take any icon (header buttons, badges, action
  /// rows): mirrors only when [icon] is one of [directional].
  const DirIcon.auto(this.icon, {super.key, this.size, this.color, this.semanticLabel}) : _always = false;

  /// Lucide icons whose arrow follows the reading direction.
  static const directional = <IconData>[
    LucideIcons.chevronLeft,
    LucideIcons.chevronRight,
    LucideIcons.chevronsLeft,
    LucideIcons.chevronsRight,
    LucideIcons.arrowLeft,
    LucideIcons.arrowRight,
    LucideIcons.send,
    LucideIcons.logIn,
    LucideIcons.logOut,
    LucideIcons.undo2,
    LucideIcons.redo2,
  ];

  final bool _always;

  final IconData icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final child = Icon(icon, size: size, color: color, semanticLabel: semanticLabel);
    final flip = Directionality.of(context) == TextDirection.rtl && (_always || directional.contains(icon));
    return flip
        ? Transform.flip(flipX: true, child: child)
        : child;
  }
}
