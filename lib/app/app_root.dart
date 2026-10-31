import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/app/app.dart';
import '../admin/state/auth_controller.dart' as admin;
import 'app.dart';

/// One app, two sides (owner, 2026-10-31: "there will be one and only
/// technician portal"). A technician gets FieldOps as before; an admin-panel
/// user (Admin, Vendor, Tenant) gets the admin screens in `lib/admin/`
/// (FE-mobile.md). Nobody signed in → FieldOps, whose sign-in screen tries the
/// technician login first and the admin login second (login_screen.dart).
///
/// Each side keeps its own router, session, tokens and push wiring; the only
/// shared pieces are this switch, the sign-in screen, and the push background
/// handler (lib/core/push/push_service.dart). See docs/admin-side.md.
class AppRoot extends ConsumerWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(admin.authControllerProvider.select((s) => s.isAuthenticated));
    return isAdmin ? const AdminApp() : const TechnicianApp();
  }
}
