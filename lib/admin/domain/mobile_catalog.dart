/// `GET /api/mobile/bootstrap` — the server's already-filtered list of what
/// this user may see (FE-mobile.md "the server decides what is visible").
/// The app never works out visibility rules itself; it only reads this.
library;

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
  const ModulePage({required this.id, required this.label, this.group});

  final String id;
  final String label;
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
    required this.label,
    required this.group,
    required this.icon,
    required this.webPath,
    this.navTab,
    this.pages = const [],
    this.tabs = const [],
  });

  /// Stable contract with the server catalog (src/mobile/moduleCatalog.ts).
  final String id;
  final String label;
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
    this.pushAlerts = true,
    this.pushMinSeverity = 'high',
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

  /// The user's own alert-push settings (server ConfigSchema `mobilePushAlerts`,
  /// `mobilePushMinSeverity`), changed from More → Alert notifications.
  final bool pushAlerts;
  final String pushMinSeverity;

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
      pushAlerts: prefs['mobilePushAlerts'] != false,
      pushMinSeverity: '${prefs['mobilePushMinSeverity'] ?? 'high'}',
    );
  }
}

List<Map<String, dynamic>> _list(Object? v) =>
    v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];
