// Compiles the board-AprilTag code of the shared C core (packages/fe_ar/src/
// fe_tag.c: marker-code -> tag ids, detection wrapper, planar PnP) into the
// pod, the same relative-include pattern as fe_ar_core_shim.c. Its
// "third_party/apriltag/..." includes resolve from src/; the podspec's
// HEADER_SEARCH_PATHS adds src/third_party/apriltag for the vendored
// sources' own "common/..." includes.
#include "../../src/fe_tag.c"
