import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/storage/session_store.dart';
import 'package:technician_portal/features/ar/ar_ui.dart';

/// P-007 flags and the AR screen's layout choice (landscape phones).
void main() {
  test('isArInstall is opt-in; isArView opt-out', () {
    expect(Permissions.fromJson(const {}).isArInstall, isFalse);
    expect(Permissions.fromJson(const {'isArInstall': true}).isArInstall, isTrue);
    expect(Permissions.fromJson(const {'isArInstall': 'yes'}).isArInstall, isFalse);
    expect(Permissions.fromJson(const {}).isArView, isNull);
    final round = Permissions.fromJson(Permissions.fromJson(const {'isArInstall': true, 'isArView': false}).toJson());
    expect(round.isArInstall, isTrue);
    expect(round.isArView, isFalse);
  });

  test('a wide but short view is a phone on its side, not a tablet', () {
    expect(arLayoutFor(const Size(390, 844)), ArLayout.phone);
    expect(arLayoutFor(const Size(915, 412)), ArLayout.landscapePhone);
    expect(arLayoutFor(const Size(780, 360)), ArLayout.landscapePhone);
    expect(arLayoutFor(const Size(1180, 820)), ArLayout.tablet);
    expect(arLayoutFor(const Size(820, 1180)), ArLayout.phone, reason: 'portrait iPad under 900 px: the phone layout, as before');
  });
}
