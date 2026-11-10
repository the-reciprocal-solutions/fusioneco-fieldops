import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:technician_portal/widgets/dir_icon.dart';

Widget _in(TextDirection dir, Widget child) =>
    Directionality(textDirection: dir, child: Center(child: child));

void main() {
  testWidgets('mirrors in Arabic (RTL), not in English (LTR)', (tester) async {
    await tester.pumpWidget(_in(TextDirection.ltr, const DirIcon(LucideIcons.chevronRight)));
    expect(find.byType(Transform), findsNothing);

    await tester.pumpWidget(_in(TextDirection.rtl, const DirIcon(LucideIcons.chevronRight)));
    expect(find.byType(Transform), findsOneWidget);
  });

  testWidgets('auto mirrors only direction icons', (tester) async {
    await tester.pumpWidget(_in(TextDirection.rtl, const DirIcon.auto(LucideIcons.bell)));
    expect(find.byType(Transform), findsNothing);

    await tester.pumpWidget(_in(TextDirection.rtl, const DirIcon.auto(LucideIcons.logOut)));
    expect(find.byType(Transform), findsOneWidget);
  });
}
