import '../core/network/api_client.dart';
import '../domain/chat_message.dart';
import '../domain/maintenance_record.dart';

/// Stored as the reply when the server sends none; the chat sheet shows it
/// translated (`chat.no_reply`).
const kNoAssistantReply = 'No response from the assistant.';

/// The per-order assistant. Online only, and deliberately so: an answer
/// composed from a stale cached order would be worse than no answer.
class AiChatRepository {
  AiChatRepository(this._api);

  final ApiClient _api;

  /// The thread id the server keys history on. Deterministic per order (and,
  /// for the two agent sub-modes, per mode too — see [ChatMode]) so the
  /// server-side thread survives across sheet opens even though the sheet
  /// itself always starts each visit on a clean screen (`ChatSheetView.home`
  /// / a fresh `messages` list — see `ChatController.openMode`); tapping
  /// "view past messages" is what pulls that same thread back up read-only.
  /// The `technician-checklist:` prefix keeps every mode out of the web
  /// portal's general facility agent history (its own sessions are random
  /// UUIDs, never this scheme).
  static String sessionIdFor(
    OrderType type,
    String recordId, {
    ChatMode mode = ChatMode.general,
  }) {
    final base = 'technician-checklist:${type.slug}:$recordId';
    return switch (mode) {
      ChatMode.general => base,
      ChatMode.createAsset => '$base:create-asset',
      ChatMode.report => '$base:report',
    };
  }

  Future<List<ChatMessage>> history(String sessionId) async {
    final response = await _api.get(
      '/api/fm/ai/chat/history',
      query: {'page': 1, 'limit': 200, 'sessionId': sessionId},
    );
    // This endpoint answers with a bare `{messages, pagination}` — no data
    // envelope — so it is read directly rather than through unwrapList.
    final body = response.data;
    final rows = body is Map ? body['messages'] : null;
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((row) => ChatMessage.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  /// Returns the assistant's reply text and the id it was stored under.
  ///
  /// [images] are `data:<mimeType>;base64,<data>` strings (see
  /// `CapturedPhoto.dataUrl`) — the exact shape the controller destructures
  /// straight from `req.body.images` and forwards into `runFacilityAgentTurn`,
  /// which regex-parses that format into Gemini `inlineData` parts. No other
  /// encoding or upload step is needed. [audio] is the same shape but
  /// singular (see `VoiceRecording.dataUrl`) — one voice note per message, and
  /// only reaches the server in [ChatMode.general]: `chatWithFacilityAgent`
  /// (used for the other two modes) never reads `req.body.audio`.
  Future<({String content, String? messageId})> send({
    required String message,
    required String sessionId,
    required OrderType type,
    required String recordId,
    ChatMode mode = ChatMode.general,
    List<String> images = const [],
    String? audio,
  }) async {
    final response = mode == ChatMode.general
        ? await _api.post(
            '/api/fm/ai/technician-checklist/chat',
            data: {
              'message': message,
              'sessionId': sessionId,
              'maintenanceId': recordId,
              // The endpoint validates this against its own vocabulary, which
              // is the same slug set the detail routes use.
              'maintenanceType': type.slug,
              if (images.isNotEmpty) 'images': images,
              'audio': ?audio,
            },
            // Model turns are slow; the default 30 s read timeout cuts them off.
            receiveTimeout: const Duration(seconds: 90),
          )
        : await _api.post(
            '/api/fm/ai/chat',
            data: {
              'message': message,
              'sessionId': sessionId,
              'isGeneral': false,
              'isCreateAsset': mode == ChatMode.createAsset,
              'isAssetReport': mode == ChatMode.report,
              if (images.isNotEmpty) 'images': images,
            },
            receiveTimeout: const Duration(seconds: 90),
          );
    final body = response.data;
    return (
      content: body is Map
          ? (body['content']?.toString() ?? kNoAssistantReply)
          : kNoAssistantReply,
      messageId: body is Map ? body['messageId']?.toString() : null,
    );
  }

  /// Tells the server to cache the order the technician is looking at, so the
  /// first question already has context. Fire and forget — the chat works
  /// without it, and its failure must never surface.
  Future<void> buildContext(OrderType type, String recordId) async {
    try {
      await _api.post(
        '/api/fm/ai/context/build',
        data: {
          'route': '/technician/orders/${type.slug}/$recordId',
          'params': {'id': recordId},
        },
      );
    } catch (_) {
      // Intentionally silent.
    }
  }
}
