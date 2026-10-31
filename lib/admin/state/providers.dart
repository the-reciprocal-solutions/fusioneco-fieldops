import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../core/storage/secure_store.dart';
import '../core/storage/session_store.dart';
import '../data/auth_repository.dart';
import '../data/bootstrap_repository.dart';

/// All three are constructed in main() and injected via ProviderScope overrides.
final secureStoreProvider = Provider<SecureStore>(
  (ref) => throw UnimplementedError(),
);
final sessionStoreProvider = Provider<SessionStore>(
  (ref) => throw UnimplementedError(),
);
final apiClientProvider = Provider<ApiClient>(
  (ref) => throw UnimplementedError(),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(apiClientProvider)),
);

final bootstrapRepositoryProvider = Provider<BootstrapRepository>(
  (ref) => BootstrapRepository(ref.watch(apiClientProvider)),
);
