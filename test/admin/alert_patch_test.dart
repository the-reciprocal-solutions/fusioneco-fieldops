import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/alert.dart';
import 'package:technician_portal/admin/state/alerts_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';

/// The server's list; [gate] holds a fetch back until the test lets it go.
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  String status = 'active';
  Completer<void>? gate;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    final seen = status; // what the server had when the request arrived
    await gate?.future;
    return {
      'success': true,
      'data': {
        'rows': [
          {'key': 'sa:1', 'title': 'Chiller', 'severity': 'critical', 'status': seen},
        ],
        'total': 1,
        'summary': <String, dynamic>{},
      },
    };
  }
}

void main() {
  test("an action's answer shows at once; the next fresh fetch takes over", () async {
    final api = _Api();
    final c = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final sub = c.listen(alertListProvider, (_, _) {});
    addTearDown(sub.close);

    AlertItem row() => patchedAlert(c.read(alertPatchesProvider), c.read(alertListProvider).requireValue.rows.single);

    await c.read(alertListProvider.future);
    expect(row().status, 'active');

    // Acknowledged on the phone; the refetch is slow (the old ~10 s).
    api.status = 'acknowledged';
    api.gate = Completer<void>();
    c.read(alertPatchesProvider.notifier).state = {
      'sa:1': AlertPatch(AlertItem.fromJson({'key': 'sa:1', 'title': 'Chiller', 'severity': 'critical', 'status': 'acknowledged'}), DateTime.now()),
    };
    c.read(alertsTickProvider.notifier).state++;
    await Future<void>.delayed(Duration.zero);
    expect(row().status, 'acknowledged'); // before the refetch lands

    api.gate!.complete();
    await c.read(alertListProvider.future);
    expect(c.read(alertPatchesProvider), isEmpty);
    expect(row().status, 'acknowledged'); // now from the server
  });

  test('a fetch that started before the action does not drop its patch', () async {
    final api = _Api()..gate = Completer<void>();
    final c = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final sub = c.listen(alertListProvider, (_, _) {});
    addTearDown(sub.close);

    await Future<void>.delayed(const Duration(milliseconds: 5)); // the fetch is in flight
    c.read(alertPatchesProvider.notifier).state = {
      'sa:1': AlertPatch(AlertItem.fromJson({'key': 'sa:1', 'status': 'resolved'}), DateTime.now()),
    };
    api.gate!.complete();
    await c.read(alertListProvider.future);
    expect(c.read(alertPatchesProvider).keys, ['sa:1']);
  });
}
