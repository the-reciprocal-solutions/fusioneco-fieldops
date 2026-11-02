import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';
import 'package:technician_portal/admin/core/storage/secure_store.dart';
import 'package:technician_portal/admin/domain/alert.dart';
import 'package:technician_portal/admin/state/alerts_controller.dart';
import 'package:technician_portal/admin/state/providers.dart';

/// 120 alerts in pages of 50 (server feed.ts pageItems). Page 2 starts one
/// early, as when a new alert lands on top between the two requests.
class _Api extends ApiClient {
  _Api() : super(secureStore: SecureStore());
  final pages = <String>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query, Duration? timeout}) async {
    final page = int.parse('${query?['page'] ?? 1}');
    pages.add('$page');
    final from = page == 1 ? 0 : (page - 1) * 50 - 1;
    return {
      'success': true,
      'data': {
        'rows': [for (var i = from; i < (page * 50).clamp(0, 120); i++) {'key': 'a$i', 'title': 'Alert $i', 'severity': 'high', 'status': 'active'}],
        'total': 120,
        'summary': <String, dynamic>{},
      },
    };
  }
}

void main() {
  test('load more adds the next page, keeps it on refetch, resets on a new filter', () async {
    final api = _Api();
    final c = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final sub = c.listen(alertListProvider, (_, _) {});
    addTearDown(sub.close);

    expect((await c.read(alertListProvider.future)).rows, hasLength(50));

    c.read(alertPageCountProvider.notifier).state++;
    final two = await c.read(alertListProvider.future);
    expect(two.rows, hasLength(100)); // a49 sent twice, shown once
    expect(two.rows.map((a) => a.key).toSet(), hasLength(100));
    expect(two.total, 120);

    api.pages.clear();
    c.read(alertsTickProvider.notifier).state++; // socket / own action
    expect((await c.read(alertListProvider.future)).rows, hasLength(100));
    expect(api.pages, unorderedEquals(['1', '2']));

    c.read(alertFiltersProvider.notifier).state = const AlertFilters(mineOnly: true);
    expect((await c.read(alertListProvider.future)).rows, hasLength(50));
  });

  test('page 1 sends no page param; later pages do', () {
    expect(const AlertFilters().toQuery().containsKey('page'), isFalse);
    expect(const AlertFilters().toQuery(page: 3)['page'], '3');
  });
}
