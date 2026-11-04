/// `GET /api/mobile/bootstrap` — the server's already-filtered list of what
/// this user may see (FE-mobile.md "the server decides what is visible").
/// The app never works out visibility rules itself; it only reads this.
library;

import '../core/i18n/server_text.dart';

/// The bottom-nav tabs. `more` holds every module without a tab of its own.
enum NavTab { home, efficiency, alerts, operations, more }

NavTab? _navTab(Object? v) => switch (v) {
      'home' => NavTab.home,
      'efficiency' => NavTab.efficiency,
      'alerts' => NavTab.alerts,
      'operations' => NavTab.operations,
      _ => null,
    };

class ModulePage {
  const ModulePage({required this.id, required String label, this.group}) : serverLabel = label;

  final String id;

  /// The name as the server sent it; [label] is what to show.
  final String serverLabel;
  String get label => serverText('catalog.page.$id', serverLabel);

  /// The server's group name: a grouping key. Show it through [catalogGroup].
  final String? group;

  factory ModulePage.fromJson(Map<String, dynamic> json) => ModulePage(
        id: '${json['id']}',
        label: '${json['label'] ?? ''}',
        group: json['group'] as String?,
      );
}

class MobileModule {
  const MobileModule({
    required this.id,
    required String label,
    required this.group,
    required this.icon,
    required this.webPath,
    this.navTab,
    this.pages = const [],
    this.tabs = const [],
  }) : serverLabel = label;

  /// Stable contract with the server catalog (src/mobile/moduleCatalog.ts).
  final String id;

  /// The name as the server sent it; [label] is what to show.
  final String serverLabel;
  String get label => serverText('catalog.module.$id', serverLabel);

  /// The server's group name: a grouping key. Show it through [catalogGroup].
  final String group;

  /// lucide icon name, kebab-case (same set as the web).
  final String icon;
  final String webPath;
  final NavTab? navTab;
  final List<ModulePage> pages;

  /// Tab flags switched on for this user, e.g. `isEnergy_Trends`.
  final List<String> tabs;

  factory MobileModule.fromJson(Map<String, dynamic> json) => MobileModule(
        id: '${json['id']}',
        label: '${json['label'] ?? ''}',
        group: '${json['group'] ?? ''}',
        icon: '${json['icon'] ?? ''}',
        webPath: '${json['webPath'] ?? ''}',
        navTab: _navTab(json['navTab']),
        pages: _list(json['pages']).map(ModulePage.fromJson).toList(),
        tabs: (json['tabs'] as List? ?? const []).map((e) => '$e').toList(),
      );
}

class LicenseInfo {
  const LicenseInfo({required this.state, required this.access, this.daysLeft, this.graceDaysLeft});

  final String state;

  /// `full` or `locked`.
  final String access;
  final int? daysLeft;
  final int? graceDaysLeft;

  bool get isLocked => access == 'locked';

  factory LicenseInfo.fromJson(Map<String, dynamic> json) => LicenseInfo(
        state: '${json['state'] ?? ''}',
        access: '${json['access'] ?? 'full'}',
        daysLeft: (json['daysLeft'] as num?)?.toInt(),
        graceDaysLeft: (json['graceDaysLeft'] as num?)?.toInt(),
      );
}

class MobileBootstrap {
  const MobileBootstrap({
    required this.role,
    required this.isSuperAdmin,
    required this.accessScope,
    required this.buildings,
    required this.language,
    required this.license,
    required this.modules,
    required this.webOnly,
    required this.catalogVersion,
    this.dashboardEnv = 'test',
    this.utilityProvider = 'bacnet',
    this.pushAlerts = true,
    this.pushMinSeverity = 'high',
    this.aiCreateAsset = false,
    this.aiAssetReport = false,
  });

  final String role;
  final bool isSuperAdmin;

  /// `all` or `buildings`.
  final String accessScope;
  final List<({String id, String name})> buildings;
  final String language;
  final LicenseInfo license;
  final List<MobileModule> modules;

  /// Admin pages kept on the web by design (the "More" footer).
  final List<String> webOnly;
  final int catalogVersion;

  /// Which provider doc Home reads: `/api/dashboard-v3?env=` (server visibility.ts dashboardEnv).
  final String dashboardEnv;

  /// Where Facility Utilities + HVAC read from — the provider chosen for the
  /// user in Settings (server visibility.ts `utilityProvider`): `bacnet` → the
  /// building system directly, any other slug (vidyutt-demo, test, …) →
  /// `GET /api/fm/utilities/live`. Older servers don't send it: BacNet, as before.
  final String utilityProvider;

  bool get utilitiesOnBacnet => utilityProvider == 'bacnet';

  /// The user's own alert-push settings (server ConfigSchema `mobilePushAlerts`,
  /// `mobilePushMinSeverity`), changed from More → Alert notifications.
  final bool pushAlerts;
  final String pushMinSeverity;

  /// Ask FlowAI's "Create asset" / "Inspection report" modes (server prefs
  /// `aiCreateAsset` / `aiAssetReport`, the web's isCreateAsset / isAssetReport).
  final bool aiCreateAsset;
  final bool aiAssetReport;

  bool has(String moduleId) => modules.any((m) => m.id == moduleId);

  MobileModule? module(String moduleId) {
    for (final m in modules) {
      if (m.id == moduleId) return m;
    }
    return null;
  }

  List<MobileModule> forTab(NavTab tab) => modules.where((m) => (m.navTab ?? NavTab.more) == tab).toList();

  /// Home/More are always shown; a module tab only when something is in it.
  bool tabVisible(NavTab tab) => switch (tab) {
        NavTab.home || NavTab.more => true,
        _ => forTab(tab).isNotEmpty,
      };

  factory MobileBootstrap.fromJson(Map<String, dynamic> json) {
    final access = json['access'] as Map<String, dynamic>? ?? const {};
    final prefs = json['prefs'] as Map<String, dynamic>? ?? const {};
    return MobileBootstrap(
      role: '${json['role'] ?? ''}',
      isSuperAdmin: json['isSuperAdmin'] == true,
      accessScope: '${access['scope'] ?? 'all'}',
      buildings: _list(access['buildings']).map((b) => (id: '${b['id']}', name: '${b['name'] ?? ''}')).toList(),
      language: '${prefs['language'] ?? 'en'}',
      license: LicenseInfo.fromJson(json['license'] as Map<String, dynamic>? ?? const {}),
      modules: _list(json['modules']).map(MobileModule.fromJson).toList(),
      webOnly: (json['webOnly'] as List? ?? const []).map((e) => '$e').toList(),
      catalogVersion: (json['catalogVersion'] as num?)?.toInt() ?? 0,
      dashboardEnv: '${prefs['dashboardEnv'] ?? 'test'}',
      utilityProvider: '${prefs['utilityProvider'] ?? 'bacnet'}',
      pushAlerts: prefs['mobilePushAlerts'] != false,
      pushMinSeverity: '${prefs['mobilePushMinSeverity'] ?? 'high'}',
      aiCreateAsset: prefs['aiCreateAsset'] == true,
      aiAssetReport: prefs['aiAssetReport'] == true,
    );
  }
}

List<Map<String, dynamic>> _list(Object? v) =>
    v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];
