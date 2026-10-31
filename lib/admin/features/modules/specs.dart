import '../efficiency/efficiency_pages.dart';
import '../photo_twin/photo_twin_screens.dart';
import '../plant_room/plant_room_screens.dart';
import 'fm_specs.dart';
import 'ops_specs.dart';
import 'performance_specs.dart';
import 'module_spec.dart';

/// Spec id of a module, or of one of its pages (`facility_ops:bookings`).
String specKey(String moduleId, String? pageId) => pageId == null ? moduleId : '$moduleId:$pageId';

/// Every Phase 3 summary screen by catalog module id. A module without a
/// spec still opens — on the "coming soon" placeholder.
final moduleSpecs = <String, ModuleSpec>{
  ...fmSpecs,
  ...performanceSpecs,
  ...opsSpecs,
  'plant_room': ModuleSpec(moduleId: 'plant_room', screen: (m) => PlantRoomListScreen(module: m)),
  'photo_twin': ModuleSpec(moduleId: 'photo_twin', screen: (m) => PhotoTwinScreen(module: m)),
  // Building Efficiency: one screen per page over the shared summary.
  for (final page in effWebPath.keys) 'efficiency:$page': ModuleSpec(moduleId: 'efficiency:$page', screen: (m) => EffPageScreen(module: m, pageId: page)),
};
