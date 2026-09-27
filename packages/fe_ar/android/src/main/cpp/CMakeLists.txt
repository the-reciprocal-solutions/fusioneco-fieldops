# libfe_ar_core.so: the shared C core (packages/fe_ar/src) plus its JNI glue.
# The same C sources are compiled into the iOS pod (ios/Classes/fe_ar_core_shim.c),
# so both platforms decode tiles, pick and fit corners with one implementation.
cmake_minimum_required(VERSION 3.18.1)
project(fe_ar_core C)

set(FE_AR_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../src)

# fe_tag.c: board AprilTags + planar PnP. fe_apriltag_unity.c: the vendored
# AprilTag 3 detector (src/third_party/apriltag, BSD-2-Clause, tag36h11 only)
# as one translation unit; its sources include "common/..." from their root.
add_library(fe_ar_core SHARED
    ${FE_AR_CORE_DIR}/fe_ar_core.c
    ${FE_AR_CORE_DIR}/fe_tag.c
    ${FE_AR_CORE_DIR}/fe_apriltag_unity.c
    fe_ar_jni.c)

target_include_directories(fe_ar_core PRIVATE ${FE_AR_CORE_DIR} ${FE_AR_CORE_DIR}/third_party/apriltag)
set_target_properties(fe_ar_core PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON)
target_compile_options(fe_ar_core PRIVATE -O2 -Wall -Wextra -fvisibility=hidden)
# Third-party code: compiled as upstream ships it, its warnings are not ours.
set_source_files_properties(${FE_AR_CORE_DIR}/fe_apriltag_unity.c PROPERTIES COMPILE_OPTIONS "-w")
# Android 15+ devices may use 16 KB pages; Play requires 16 KB-aligned
# native libraries for new app updates.
target_link_options(fe_ar_core PRIVATE "-Wl,-z,max-page-size=16384")
target_link_libraries(fe_ar_core m)
