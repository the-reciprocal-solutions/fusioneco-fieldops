import '../core/network/api_client.dart';
import '../core/network/api_exception.dart';
import '../domain/mobile_catalog.dart';

class BootstrapRepository {
  BootstrapRepository(this._api);

  final ApiClient _api;

  Future<MobileBootstrap> fetch() async {
    final body = await _api.get('/api/mobile/bootstrap');
    final data = body is Map ? body['data'] : null;
    if (data is! Map<String, dynamic>) {
      throw const UnknownFailure('Unexpected bootstrap response');
    }
    return MobileBootstrap.fromJson(data);
  }
}
