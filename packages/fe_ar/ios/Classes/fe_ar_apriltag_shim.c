// The vendored AprilTag 3 detector (packages/fe_ar/src/third_party/apriltag,
// BSD-2-Clause: its LICENSE.md must be reproduced in the app's
// acknowledgements) as the one translation unit src/fe_apriltag_unity.c
// already defines, so Android, iOS and the laptop tests compile the same
// list. A separate shim from fe_ar_tag_shim.c: both sides have file-static
// helpers that must not share a translation unit.
#include "../../src/fe_apriltag_unity.c"
