import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/realtime/socket_service.dart';
import 'alerts_controller.dart';
import 'catalog_controller.dart';
import 'providers.dart';

/// Builds the socket for the signed-in user. Overridden in tests.
final socketServiceFactoryProvider = Provider<SocketService Function(void Function(String event) onEvent)>((ref) {
  final api = ref.watch(apiClientProvider);
  final secure = ref.watch(secureStoreProvider);
  return (onEvent) => SocketService(
        baseUrl: api.baseUrl,
        readToken: secure.readToken,
        renewSession: api.renewSession,
        onEvent: onEvent,
      );
});

/// The live connection while the signed-in shell is on screen (AdminShell
/// watches it). Disposed — and disconnected — on sign-out.
final socketProvider = Provider.autoDispose<SocketService>((ref) {
  void bumpAlerts() => ref.read(alertsTickProvider.notifier).state++;

  final socket = ref.watch(socketServiceFactoryProvider)((event) {
    switch (event) {
      case SocketService.configChanged:
        ref.invalidate(catalogProvider);
      case SocketService.alertsChanged:
        bumpAlerts();
      case SocketService.reconnected:
        ref.invalidate(catalogProvider);
        bumpAlerts();
    }
  });
  socket.connect();
  ref.onDispose(socket.disconnect);
  return socket;
});
