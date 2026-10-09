import 'dart:io';

import 'package:flutter/services.dart';

/// One button tap on an alert iOS drew itself.
typedef NativePushAction = ({String actionId, Map<String, dynamic> data, String? input});

/// The iOS side of tray buttons on **server-drawn** alerts.
///
/// While the app is in the background or closed, iOS shows the server's
/// APNs alert itself, with the buttons of the `category` the server named
/// (`pushPayload.ts`). firebase_messaging reports a tap on such an alert as
/// a plain open and drops which button it was and any typed reply, so
/// `AppDelegate.swift` catches those taps and hands them over this channel
/// (`fieldops/push_actions`): live as an `action` call, or — after a cold
/// start — from `takePending`. "Mark read" never reaches Dart this way: the
/// app delegate parks the id in shared_preferences (`PendingPushActions`).
///
/// Android never uses this: every Android notification is drawn by the app,
/// so flutter_local_notifications reports its buttons directly.
class NativePushActions {
  NativePushActions._();

  static const _channel = MethodChannel('fieldops/push_actions');

  /// Starts delivering live taps to [onAction] and returns the ones that
  /// arrived before Dart was listening (cold start).
  static Future<List<NativePushAction>> listen(void Function(NativePushAction action) onAction) async {
    if (!Platform.isIOS) return const [];
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'action') throw MissingPluginException();
      final a = _parse(call.arguments);
      if (a != null) onAction(a);
      return true;
    });
    try {
      final pending = await _channel.invokeListMethod<Object?>('takePending') ?? const [];
      return [for (final p in pending) ?_parse(p)];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// The app icon number (iOS). Android launchers count tray entries.
  static Future<void> setBadge(int count) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('setBadge', count < 0 ? 0 : count);
    } catch (_) {}
  }

  static NativePushAction? _parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['actionId']?.toString();
    if (id == null || id.isEmpty) return null;
    final data = raw['data'] is Map ? Map<String, dynamic>.from(raw['data'] as Map) : <String, dynamic>{};
    final input = raw['input']?.toString();
    return (actionId: id, data: data, input: input == null || input.trim().isEmpty ? null : input);
  }
}
