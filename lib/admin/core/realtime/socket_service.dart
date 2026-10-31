import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../network/session_renewer.dart';

/// The server's live channel while the app runs (FE-mobile.md 0.3). The
/// server puts each signed-in user's sockets in `user_<id>`; this listens there.
///
/// Events, passed to [onEvent] by name:
/// - [configChanged] — an admin changed this user's switches: refetch the catalog.
/// - [alertsChanged] — an alert in one of the user's buildings changed (the
///   server sends it to building/org rooms, which this socket joins).
/// - [reconnected] — the server disconnects a user's sockets when their
///   building access changes (socketService.refreshUserAccess), and events
///   sent while the phone was offline are lost: refetch everything.
///
/// One connection per signed-in user. Same transport choice as
/// technician_portal's SocketService.
class SocketService {
  SocketService({
    required this.baseUrl,
    required this.readToken,
    required this.renewSession,
    required this.onEvent,
  });

  static const configChanged = 'config:changed';
  static const alertsChanged = 'alerts:changed';
  static const reconnected = 'reconnected';

  final String baseUrl;

  /// The current access token (secure storage — it rotates every hour).
  final Future<String?> Function() readToken;

  /// Renews the session. `unavailable` (no network) is retried with backoff;
  /// `rejected` ends here (the API client signs the user out).
  final Future<RenewOutcome> Function() renewSession;

  /// Waits between renewal retries while the server can't be reached.
  static const retryDelays = [Duration(seconds: 5), Duration(seconds: 10), Duration(seconds: 20), Duration(seconds: 40), Duration(seconds: 60)];

  /// One of [configChanged], [alertsChanged], [reconnected].
  final void Function(String event) onEvent;

  io.Socket? _socket;
  bool _connectedOnce = false;
  bool _renewing = false;
  int _retry = 0;
  Timer? _retryTimer;

  bool get isConnected => _socket?.connected ?? false;

  Future<void> connect() async {
    disconnect();
    final token = await readToken();
    if (token == null || token.isEmpty) return;

    // The socket server is mounted at the root, as on the web
    // (`SOCKET_URL.replace("/api", "")`).
    final socket = io.io(
      baseUrl.replaceAll('/api', ''),
      io.OptionBuilder()
          // Websocket first, long-polling as the fallback for weak networks.
          .setTransports(['websocket', 'polling'])
          .setAuth({'token': token})
          .enableReconnection()
          .disableAutoConnect()
          .build(),
    );

    socket.on(configChanged, (_) => onEvent(configChanged));
    socket.on(alertsChanged, (_) => onEvent(alertsChanged));

    socket.onConnect((_) {
      // The first connect follows the catalog load that just happened.
      if (_connectedOnce) onEvent(reconnected);
      _connectedOnce = true;
    });

    // The access token lasts an hour; a reconnect must carry the current one.
    socket.onDisconnect((_) async {
      final fresh = await readToken();
      if (fresh != null && identical(_socket, socket)) socket.auth = {'token': fresh};
    });

    // Handshake refused ("Authentication error: …"): the token ran out while
    // disconnected. socket.io does not retry after a refusal, so renew and
    // reconnect ourselves — and if the renewal can't reach the server
    // (still offline), try again later instead of giving up (PENDING P-002).
    socket.onConnectError((err) {
      if ('$err'.contains('Authentication error')) _renewAndReconnect(socket);
    });

    _socket = socket;
    socket.connect();
  }

  Future<void> _renewAndReconnect(io.Socket socket) async {
    if (_renewing || !identical(_socket, socket)) return;
    _renewing = true;
    try {
      switch (await renewSession()) {
        case RenewOutcome.renewed:
          _retry = 0;
          if (!identical(_socket, socket)) return;
          socket.auth = {'token': await readToken()};
          socket.disconnect().connect();
        case RenewOutcome.unavailable:
          final wait = retryDelays[_retry < retryDelays.length ? _retry : retryDelays.length - 1];
          _retry++;
          _retryTimer?.cancel();
          _retryTimer = Timer(wait, () => _renewAndReconnect(socket));
        case RenewOutcome.rejected:
          break; // signed out by the API client
      }
    } finally {
      _renewing = false;
    }
  }

  /// App back in the foreground: reconnect if the socket is down (it may have
  /// given up while the phone was asleep or offline). A reconnect fires
  /// [reconnected], so everything is refetched.
  Future<void> ensureConnected() async {
    final socket = _socket;
    if (socket == null) return connect();
    if (socket.connected || socket.active) return;
    socket.auth = {'token': await readToken()};
    socket.connect();
  }

  void disconnect() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retry = 0;
    final socket = _socket;
    if (socket == null) return;
    _socket = null;
    _connectedOnce = false;
    socket.clearListeners();
    socket.dispose();
  }
}
