import 'dart:convert';

import 'package:technician_portal/admin/features/web/web_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same origin: scheme, host and port all match', () {
    final base = Uri.parse('https://dev.eco.thefusionapps.com');
    expect(sameOrigin(Uri.parse('https://dev.eco.thefusionapps.com/hvac/efficiency'), base), isTrue);
    expect(sameOrigin(Uri.parse('http://dev.eco.thefusionapps.com/x'), base), isFalse);
    expect(sameOrigin(Uri.parse('https://files.example.com/a.pdf'), base), isFalse);
    expect(sameOrigin(Uri.parse('https://dev.eco.thefusionapps.com:8443/x'), base), isFalse);
    expect(sameOrigin(null, base), isFalse);
  });

  test('the session keys are the ones the web sign-in writes (app/login/page.tsx)', () {
    final user = {'id': 'u1', 'name': 'Ragul', 'role': 'Admin', 'username': 'ragul', 'email': 'demo@admin.com'};
    final e = webSessionEntries('tok', user);
    expect(e.keys, containsAll(['token', 'isAuthenticated', 'role', 'userId', 'userName', 'username', 'meta', 'userDetails']));
    expect(e['token'], 'tok');
    expect(e['role'], 'Admin');
    expect(e['userId'], 'u1');
    expect(jsonDecode(e['meta']!), {'username': 'ragul'});
    expect((jsonDecode(e['userDetails']!) as Map)['email'], 'demo@admin.com');
  });

  test('no username → no username key (the web reads it as absent)', () {
    expect(webSessionEntries('t', {'id': 'u', 'name': 'n', 'role': 'Admin'}).containsKey('username'), isFalse);
  });
}
