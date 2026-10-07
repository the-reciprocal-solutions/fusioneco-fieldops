import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../domain/conversation.dart';
import '../../../theme/fe_colors.dart';

/// `conv.*` / `schedules.*` string with `%a` arguments.
String convTr(BuildContext context, String key, [List<Object> args = const []]) {
  final text = key.getString(context);
  return args.isEmpty ? text : context.formatString(text, args.map((a) => '$a').toList());
}

/// A failure line from `plainPostFailure`: an i18n key (`conv.err_*`) or the
/// server's own plain words.
String failureText(BuildContext context, String? raw) {
  final r = raw ?? '';
  return r.startsWith('conv.err_') ? r.getString(context) : r;
}

/// Round avatar. People: initials on a soft grey. AI teammates: a violet
/// ring and a sparkle, so an agent can never be mistaken for a person.
class ConvAvatar extends StatelessWidget {
  const ConvAvatar({super.key, required this.name, this.isAgent = false, this.size = 32});
  final String name;
  final bool isAgent;
  final double size;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final second = parts.length > 1 ? parts[1].characters.first : '';
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    if (isAgent) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: FeColors.aiSoft,
          shape: BoxShape.circle,
          border: Border.all(color: FeColors.ai, width: 2),
        ),
        child: Icon(LucideIcons.sparkles, size: size * 0.45, color: FeColors.ai),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: FeColors.line, shape: BoxShape.circle),
      child: Text(
        _initials,
        style: TextStyle(fontSize: size * 0.36, fontWeight: FontWeight.w800, color: FeColors.ink),
      ),
    );
  }
}

/// The small "AI" tag next to an agent's name.
class AiTag extends StatelessWidget {
  const AiTag({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: FeColors.ai, borderRadius: BorderRadius.circular(6)),
    child: Text(
      'conv.ai_tag'.getString(context),
      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.4),
    ),
  );
}

abstract final class ConvVisuals {
  static Color cardColor(ActionCardStatus s) => switch (s) {
    ActionCardStatus.done => FeColors.success,
    ActionCardStatus.approved => FeColors.info,
    ActionCardStatus.held => FeColors.warning,
    ActionCardStatus.blocked || ActionCardStatus.failed => FeColors.danger,
    ActionCardStatus.dismissed => FeColors.ink2,
    ActionCardStatus.suggested => FeColors.ai,
  };

  static String cardStatusKey(ActionCardStatus s) => 'conv.card.${s.name}';
}
