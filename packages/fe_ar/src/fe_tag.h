/*
 * fe_tag: AprilTag fiducials on the printed marker boards, and the board
 * pose they give (docs/ar-markers-and-qr.md §2.3, CHANNEL.md method "tag").
 *
 * Why: the QR says WHICH board it is; its four ML Kit / Vision corners are
 * too rough for a precise pose. Each board (printed from 2026-09-27) also
 * carries four AprilTag tag36h11 fiducials, one in each corner of the
 * textured frame (where the old quadrant targets were). The detector finds
 * their corners to a fraction of a pixel, and a planar PnP over all sixteen
 * corners, spread over ~150 mm, gives the board centre to about a centimetre
 * or better at 0.3-1.5 m (averaged over 20-30 frames in world space by the
 * platform half).
 *
 * Board geometry (board frame: origin at the QR centre, +x right, +y up as
 * printed, +z out of the wall toward the viewer; metres):
 *
 *   format  tag edge (black square)   tag centre offset (x and y)
 *   A4      22.0 mm (cell 2.75 mm)    +-71.25 mm
 *   A3      32.0 mm (cell 4.00 mm)    +-105.0 mm
 *
 *   corner k: 0 top-left (-o,+o), 1 top-right (+o,+o),
 *             2 bottom-right (+o,-o), 3 bottom-left (-o,-o).
 *   Every tag is printed upright (not rotated).
 *
 * Tag ids (no schema change; the server's print code is the other copy,
 * fusion-eco-server src/services/ar/print/aprilTag.ts, golden values shared):
 *
 *   g     = FNV-1a-32(canonical 7-char code, ASCII) mod 146
 *   G     = g for A4, (g + 73) mod 146 for A3   (never equal: A4/A3 ids of a
 *           code are disjoint, so a detected id also tells the print format)
 *   id    = 4 * G + k                          (0..583 of tag36h11's 587)
 *
 * 146 groups means two boards in a building can share a group. That is
 * harmless: the QR identifies the board, and a tag is only used when it is
 * in the payload's group AND sits where that QR's frame corner is in the
 * same image (the platform half checks that, see MarkerDetector.kt).
 *
 * Pixel convention: corners are returned with pixel CENTRES at integer
 * coordinates (AprilTag's own output, which puts them at +0.5, is shifted),
 * the convention the camera intrinsics and fe_square_pose use.
 *
 * Pure C99 plus the vendored AprilTag 3 detector (third_party/apriltag,
 * BSD-2-Clause, compiled through fe_apriltag_unity.c). Not re-entrant per
 * detector: use one fe_tag_detector per thread.
 */
#ifndef FE_TAG_H
#define FE_TAG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FE_TAG_GROUPS 146
#define FE_TAG_A3_SHIFT 73

enum {
    FE_BOARD_A4 = 0,
    FE_BOARD_A3 = 1,
};

/** Tag black-square edge and centre offset (both metres) for a format. 0 for an unknown format. */
int fe_board_tag_geometry(int format, float* edge_m, float* offset_m);

/**
 * Anything a scanner hands over -> canonical 7-char marker code (NUL-terminated
 * in code_out), the C port of markerCodeService.codeFromPayload: a marker URL
 * `scheme://host/m/<code>` (any case, optional trailing slash, query or
 * fragment ignored) or a bare code; Crockford aliases O->0, I/L->1; U and a
 * bad check character are rejected. Returns 1 for a marker code, else 0.
 */
int fe_marker_code_from_payload(const char* payload, char code_out[8]);

/** Group g (0..145) of a canonical code, or -1 when it isn't one. */
int fe_tag_group(const char* code7);

/** Tag id for a code, format and corner (0..3), or -1. */
int fe_tag_id(const char* code7, int format, int corner);

/**
 * Is tag_id one of this code's tags? Returns 1 and sets format and corner
 * (either may be NULL), else 0.
 */
int fe_tag_match(const char* code7, int tag_id, int* format, int* corner);

/* ------------------------------------------------------------------------ */
/* Detection                                                                 */
/* ------------------------------------------------------------------------ */

typedef struct fe_tag_detector fe_tag_detector;

typedef struct fe_tag_detection {
    int id;
    /** Bits corrected (0 or 1). */
    int hamming;
    /** AprilTag decision margin (higher is better; under ~20 is weak). */
    float margin;
    /**
     * Image corners, pixels, in the TAG's frame order: bottom-left,
     * bottom-right, top-right, top-left of the tag as printed upright.
     */
    float corners[8];
    float centre[2];
} fe_tag_detection;

/** tag36h11 only, up to 1 corrected bit. NULL on allocation failure. */
fe_tag_detector* fe_tag_detector_create(void);
void fe_tag_detector_free(fe_tag_detector* d);

/**
 * Detects tag36h11 tags in an 8-bit grey image (an ARCore/ARKit Y plane),
 * restricted to the region of interest (roi_w or roi_h <= 0: the whole
 * image; clamped to the image). decimate: AprilTag's quad_decimate (1 = full
 * resolution; 2 for a region wider than ~800 px). Writes up to max_out
 * detections in full-image pixels and returns how many (0 on bad input).
 */
int fe_tag_detect(fe_tag_detector* d, const uint8_t* grey, int width, int height, int stride, int roi_x, int roi_y,
                  int roi_w, int roi_h, float decimate, fe_tag_detection* out, int max_out);

/* ------------------------------------------------------------------------ */
/* Pose                                                                      */
/* ------------------------------------------------------------------------ */

/**
 * Pose of a planar target from n >= 4 points: obj_xy are the points on the
 * target's plane (x, y pairs, metres, z = 0; the target's +z faces the
 * camera), img_px their pixels. Output in camera space (+X right, +Y up,
 * -Z forward): R (row-major 3x3, target -> camera) and t (the target origin).
 * Homography initialisation, both planar solutions refined by Levenberg-
 * Marquardt on the reprojection error, the better one kept. rms_px: final
 * RMS reprojection error. Returns 1 on success.
 */
int fe_planar_pose(const float* obj_xy, const float* img_px, int n, float fx, float fy, float cx, float cy, float R[9],
                   float t[3], float* rms_px);

typedef struct fe_board_pose {
    /** Board centre (the QR centre), camera space (+X right, +Y up, -Z forward). */
    float centre[3];
    /** Unit normal out of the board, toward the camera. */
    float normal[3];
    /** Unit "up" of the board as printed. */
    float up[3];
    float distance;
    float rms_px;
    /** Tags used (1..4) and the print format they say (FE_BOARD_*). */
    int n_tags;
    int format;
} fe_board_pose;

/**
 * Board pose from the detections that belong to code7 (others are ignored):
 * the format comes from the first matching id, and only tags of that format
 * are used. Returns 1 with at least one matching tag and a converged pose.
 */
int fe_board_pose_from_tags(const fe_tag_detection* dets, int n, const char* code7, float fx, float fy, float cx, float cy,
                            fe_board_pose* out);

#ifdef __cplusplus
}
#endif

#endif /* FE_TAG_H */
