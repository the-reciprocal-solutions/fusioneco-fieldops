import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Identity as the API needs it. `userId` is the technician UUID and is what every
/// `/technician/:id` call takes; `technicianId` (TECH001) is display only.
class Session {
  const Session({
    required this.userId,
    required this.name,
    this.technicianId,
    this.email,
    this.username,
    this.department,
    this.partnerRole,
    this.vendorId,
    this.loginAt,
    this.requestLocation = false,
  });

  final String userId;
  final String name;
  final String? technicianId;
  final String? email;
  final String? username;
  final String? department;
  final String? partnerRole;
  final String? vendorId;
  final DateTime? loginAt;

  /// Set from the login response's top-level `requestLocation` flag (server:
  /// `TechnicianLogin`, `technicianLocationService.needsLocationRefresh`) —
  /// true when the last GPS fix is missing or older than 24h. Persisted so
  /// the check-in prompt survives an app restart before the technician
  /// answers it; cleared locally once `updateLocation` succeeds.
  final bool requestLocation;

  Session copyWith({bool? requestLocation}) => Session(
        userId: userId,
        name: name,
        technicianId: technicianId,
        email: email,
        username: username,
        department: department,
        partnerRole: partnerRole,
        vendorId: vendorId,
        loginAt: loginAt,
        requestLocation: requestLocation ?? this.requestLocation,
      );

  bool get isInHouse => partnerRole == null || partnerRole == 'in-house';

  // No client-side expiry (2026-10-06): the session lasts until the
  // technician signs out or the server refuses to renew it — see
  // `SessionRefresher` and docs/architecture.md "Session". The old 24h
  // timer signed people out mid-shift and asked for the password daily.

  factory Session.fromLoginResponse(
    Map<String, dynamic> technician, {
    bool requestLocation = false,
  }) =>
      Session(
        userId: technician['id']?.toString() ?? '',
        name: technician['name']?.toString() ?? '',
        technicianId: technician['technicianId']?.toString(),
        email: technician['email']?.toString(),
        username: technician['username']?.toString(),
        department: technician['department']?.toString(),
        partnerRole: technician['partnerRole']?.toString(),
        vendorId: technician['vendorId']?.toString(),
        loginAt: DateTime.now(),
        requestLocation: requestLocation,
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'name': name,
        'technicianId': technicianId,
        'email': email,
        'username': username,
        'department': department,
        'partnerRole': partnerRole,
        'vendorId': vendorId,
        'loginAt': (loginAt ?? DateTime.now()).toIso8601String(),
        'requestLocation': requestLocation,
      };

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        userId: json['userId']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        technicianId: json['technicianId']?.toString(),
        email: json['email']?.toString(),
        username: json['username']?.toString(),
        department: json['department']?.toString(),
        partnerRole: json['partnerRole']?.toString(),
        vendorId: json['vendorId']?.toString(),
        loginAt: json['loginAt'] != null
            ? DateTime.tryParse(json['loginAt'].toString())
            : null,
        requestLocation: json['requestLocation'] == true,
      );
}

/// Feature flags from GET /api/auth/config. Only these reach the technician UI.
class Permissions {
  const Permissions({
    this.isAiAgent = false,
    this.isCreateAsset = false,
    this.isAssetReport = false,
    this.isDigitalTwin,
    this.isArView,
    this.isArInstall = false,
    this.currencyType,
    this.currencyRates = const {},
  });

  final bool isAiAgent;
  // Sub-actions of the assistant sheet, not standalone screens — same
  // truthy-default-false polarity as isAiAgent (opt-in), unlike
  // isDigitalTwin below (opt-out). See order_chat_sheet.dart's mode chips.
  final bool isCreateAsset;
  final bool isAssetReport;
  // Nullable, unlike isAiAgent: matches the web portal's polarity, where an
  // unset/missing flag (every account created before this gate existed)
  // keeps View in 3D reachable. Only an explicit `false` blocks it.
  final bool? isDigitalTwin;
  // FieldOps "Show in AR" doors (server `isArView`, default on). Same opt-out
  // polarity as isDigitalTwin: only an explicit `false` hides AR for a client.
  // A door also needs the floor/building to have a published AR model — see
  // state/ar_availability.dart; this flag is the per-client switch on top.
  final bool? isArView;
  // FieldOps install runs and turning spare boards into markers (server
  // `isArInstall`, default **off**): opt-in, like isAiAgent — only an
  // explicit `true` shows the install list, the dashboard install tile and
  // "save a board here" (ar-markers-and-qr.md §3.3 decision 3, PENDING P-007).
  final bool isArInstall;
  final String? currencyType;
  final Map<String, double> currencyRates;

  factory Permissions.fromJson(Map<String, dynamic> json) {
    final rates = <String, double>{};
    final raw = json['currencyRates'];
    if (raw is Map) {
      raw.forEach((key, value) {
        final parsed = value is num ? value.toDouble() : double.tryParse('$value');
        if (parsed != null) rates[key.toString()] = parsed;
      });
    }
    return Permissions(
      isAiAgent: json['isAiAgent'] == true,
      isCreateAsset: json['isCreateAsset'] == true,
      isAssetReport: json['isAssetReport'] == true,
      isDigitalTwin: json['isDigitalTwin'] as bool?,
      isArView: json['isArView'] as bool?,
      isArInstall: json['isArInstall'] == true,
      currencyType: json['currencyType']?.toString(),
      currencyRates: rates,
    );
  }

  Map<String, dynamic> toJson() => {
        'isAiAgent': isAiAgent,
        'isCreateAsset': isCreateAsset,
        'isAssetReport': isAssetReport,
        'isDigitalTwin': isDigitalTwin,
        'isArView': isArView,
        'isArInstall': isArInstall,
        'currencyType': currencyType,
        'currencyRates': currencyRates,
      };
}

class SessionStore {
  SessionStore(this._prefs);

  static const _sessionKey = 'session';
  static const _sessionTimestampKey = 'session_timestamp';
  static const _permissionsKey = 'permissions';
  static const _baseUrlKey = 'apiBaseUrl';

  final SharedPreferences _prefs;

  static Future<SessionStore> open() async =>
      SessionStore(await SharedPreferences.getInstance());

  Session? readSession() {
    final raw = _prefs.getString(_sessionKey);
    if (raw == null) return null;
    // No 24h cut-off any more: an expired access token is renewed on the
    // first request (ApiClient → SessionRefresher); only a refused renewal
    // ends the session.
    try {
      return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeSession(Session session) async {
    final now = session.loginAt ?? DateTime.now();
    await _prefs.setInt(_sessionTimestampKey, now.millisecondsSinceEpoch);
    await _prefs.setString(_sessionKey, jsonEncode(session.toJson()));
  }

  /// Persists the cleared flag in place — called once `updateLocation`
  /// succeeds, so a killed-and-reopened app doesn't prompt again for a
  /// check-in that already landed.
  Future<Session?> clearRequestLocation() async {
    final session = readSession();
    if (session == null) return null;
    final updated = session.copyWith(requestLocation: false);
    await writeSession(updated);
    return updated;
  }

  Permissions readPermissions() {
    final raw = _prefs.getString(_permissionsKey);
    if (raw == null) return const Permissions();
    try {
      return Permissions.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const Permissions();
    }
  }

  Future<void> writePermissions(Permissions permissions) =>
      _prefs.setString(_permissionsKey, jsonEncode(permissions.toJson()));

  String? readBaseUrlOverride() => _prefs.getString(_baseUrlKey);

  Future<void> writeBaseUrlOverride(String? value) async {
    if (value == null || value.isEmpty) {
      await _prefs.remove(_baseUrlKey);
    } else {
      await _prefs.setString(_baseUrlKey, value);
    }
  }

  Future<void> clear() async {
    await _prefs.remove(_sessionKey);
    await _prefs.remove(_sessionTimestampKey);
    await _prefs.remove(_permissionsKey);
  }
}
