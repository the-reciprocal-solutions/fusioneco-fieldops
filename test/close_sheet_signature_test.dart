import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signature/signature.dart';
import 'package:technician_portal/domain/maintenance_record.dart';
import 'package:technician_portal/features/order_detail/close_sheet.dart';
import 'package:technician_portal/state/auth_controller.dart';
import 'package:technician_portal/state/checklist_controller.dart';
import 'package:technician_portal/state/order_detail_controller.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// The close sheet's "Signature required before closing." stayed under a drawn
/// signature, reading as still missing (WO-762 on the phone, 2026-11-02).
class _NoChecklist extends ChecklistController {
  @override
  ChecklistState build(OrderKey arg) => const ChecklistState();
}

class _SignedOut extends AuthController {
  @override
  AuthState build() => const AuthState();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final en = jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(mapLocales: [MapLocale('en', en)], initLanguageCode: 'en');
  });

  testWidgets('the "required" hint goes once a signature is drawn, and comes back on clear', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final l = FlutterLocalization.instance;
    final record = MaintenanceRecord.fromJson({'id': 'w1', 'workOrderId': 'w1', 'title': 'RM: Test', 'status': 'In Progress'}, OrderType.workOrder);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        checklistControllerProvider.overrideWith(_NoChecklist.new),
        authControllerProvider.overrideWith(_SignedOut.new),
      ],
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: l.supportedLocales,
        localizationsDelegates: l.localizationsDelegates,
        home: Scaffold(
          body: CloseSheet(orderKey: (type: OrderType.workOrder, id: 'w1'), record: record, predictedStart: null),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    const hint = 'Signature required before closing.';
    expect(find.text(hint), findsOneWidget);

    final pad = find.byType(Signature);
    await tester.ensureVisible(pad);
    await tester.drag(pad, const Offset(120, 40));
    await tester.pumpAndSettle();
    expect(find.text(hint), findsNothing);

    await tester.tap(find.text('Clear signature'));
    await tester.pumpAndSettle();
    expect(find.text(hint), findsOneWidget);
  });
}
