/*
 * The vendored AprilTag 3 detector as ONE translation unit, so every build
 * (Android CMake, the iOS pod's shim, the laptop tests) compiles the same
 * list with one line.
 *
 * third_party/apriltag is a subset of https://github.com/AprilRobotics/apriltag
 * at b7c0ebe9aa20f82ec7a828579004f9e706bfecd9 (2026-08-07), BSD-2-Clause
 * (third_party/apriltag/LICENSE.md, which must ship with it), unmodified:
 * the detector, tag36h11 (the only family we print), and the common/ files
 * they link against. No other family, no Python wrapper, no example code.
 *
 * Two of those files each define a file-static `convolve`; they are renamed
 * here only so that one translation unit can hold both.
 */
#include "third_party/apriltag/apriltag.c"
#include "third_party/apriltag/apriltag_quad_thresh.c"
#include "third_party/apriltag/tag36h11.c"
#include "third_party/apriltag/common/g2d.c"
#include "third_party/apriltag/common/homography.c"
#include "third_party/apriltag/common/image_u8.c"
#define convolve fe_apriltag_u8x3_convolve
#include "third_party/apriltag/common/image_u8x3.c"
#undef convolve
#define convolve fe_apriltag_parallel_convolve
#include "third_party/apriltag/common/image_u8_parallel.c"
#undef convolve
#include "third_party/apriltag/common/matd.c"
#include "third_party/apriltag/common/pnm.c"
#include "third_party/apriltag/common/pthreads_cross.c"
#include "third_party/apriltag/common/svd22.c"
#include "third_party/apriltag/common/time_util.c"
#include "third_party/apriltag/common/unionfind.c"
#include "third_party/apriltag/common/workerpool.c"
#include "third_party/apriltag/common/zarray.c"
#include "third_party/apriltag/common/zmaxheap.c"
