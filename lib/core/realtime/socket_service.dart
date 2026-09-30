import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../../domain/app_notification.dart';

/// One conversation room event (`message.created`, `message.updated`,
/// `typing`, `session.started`, `session.finished`) — see
/// `../fusion-eco-server/src/services/conversations/types.ts` CONV_SOCKET.
class ConvSocketEvent {
  const ConvSocketEvent(this.name, this.data);
  final String name;
  final Map<String, dynamic> data;

  String? get entity => data['entity']?.toString();
  String? get entityId => data['entityId']?.toString();
}

/// The server's live channel, only while the app is running and connected
/// (FCM covers the closed app). It carries `new_notification` for the bell
/// and, since 2026-09-30, the conversation room events of whichever threads
/// are open on screen (docs/conversations-and-schedules.md "Live updates").
/// Rooms are joined by `conv:join {entity, id}` and are lost on a reconnect,
/// so every open room is re-joined on each `connect`.
class SocketService {
  SocketService({
    required this.baseUrl,
    required this.onNotification,
  });

  final String baseUrl;
  final void Function(AppNotification) onNotification;

  io.Socket? _socket;

  final _convEvents = StreamController<ConvSocketEvent>.broadcast();

  /// Open conversation rooms as `entity|id`, re-joined after a reconnect.
  final _rooms = <String>{};

  static const _convEventNames = [
    'message.created',
    'message.updated',
    'typing',
    'session.started',
    'session.updated',
    'session.finished',
  ];

  /// Room events for every joined thread; listeners filter by entity id.
  Stream<ConvSocketEvent> get conversationEvents => _convEvents.stream;

  bool get isConnected => _socket?.connected ?? false;

  /// Opens the connection for one signed-in technician. Calling it again with a
  /// different token replaces the connection rather than stacking a second one.
  void connect(String token) {
    if (token.isEmpty) return;
    disconnect();

    // The API base may carry an `/api` suffix; the socket server is mounted at
    // the root, same as the web client's `SOCKET_URL.replace("/api", "")`.
    final url = baseUrl.replaceAll('/api', '');

    final socket = io.io(
      url,
      io.OptionBuilder()
          // Websocket first, long-polling as the fallback — a phone on a weak
          // mobile network often cannot hold a websocket open.
          .setTransports(['websocket', 'polling'])
          .setAuth({'token': token})
          .enableReconnection()
          .build(),
    );

    socket.on('new_notification', (data) {
      if (data is! Map) return;
      onNotification(
        AppNotification.fromJson(Map<String, dynamic>.from(data)),
      );
    });

    for (final name in _convEventNames) {
      socket.on(name, (data) {
        if (data is! Map || _convEvents.isClosed) return;
        _convEvents.add(ConvSocketEvent(name, Map<String, dynamic>.from(data)));
      });
    }
    // Rooms don't survive a reconnect (server restart, mobile network hop).
    socket.onConnect((_) {
      for (final room in _rooms) {
        final i = room.indexOf('|');
        socket.emit('conv:join', {'entity': room.substring(0, i), 'id': room.substring(i + 1)});
      }
    });

    _socket = socket;
  }

  /// Joins a thread's room (the server refuses one this person can't see).
  /// Safe before [connect]: the join is sent when the connection opens.
  void joinConversation(String entity, String id) {
    _rooms.add('$entity|$id');
    final socket = _socket;
    if (socket != null && socket.connected) socket.emit('conv:join', {'entity': entity, 'id': id});
  }

  void leaveConversation(String entity, String id) {
    _rooms.remove('$entity|$id');
    final socket = _socket;
    if (socket != null && socket.connected) socket.emit('conv:leave', {'entity': entity, 'id': id});
  }

  /// "Is typing" for the other people in the room; best effort.
  void sendTyping(String entity, String id, {required bool typing}) {
    final socket = _socket;
    if (socket == null || !socket.connected) return;
    socket.emit('conv:typing', {'entity': entity, 'id': id, 'state': typing ? 'start' : 'stop'});
  }

  void disconnect() {
    final socket = _socket;
    if (socket == null) return;
    _socket = null;
    socket.clearListeners();
    socket.dispose();
  }
}
