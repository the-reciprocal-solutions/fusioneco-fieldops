/*
 * JNI bindings for fe_ar_core (../../../../src/fe_ar_core.c), used by
 * com.fusionapps.fe_ar.FeArCore. Thin: argument marshalling only, every
 * decision stays in the core (tested on a laptop) or in Kotlin.
 *
 * The package name contains an underscore, which JNI escapes as "_1":
 * com.fusionapps.fe_ar.FeArCore -> Java_com_fusionapps_fe_1ar_FeArCore_*.
 */
#include <jni.h>
#include <stdlib.h>
#include <string.h>

#include "fe_ar_core.h"

#define FN(name) Java_com_fusionapps_fe_1ar_FeArCore_##name

/* Last parse error, per thread (tiles are parsed on a background executor). */
static __thread char g_err[256];

static int get_floats(JNIEnv* env, jfloatArray arr, float* out, jsize n) {
    if (!arr || (*env)->GetArrayLength(env, arr) < n) return 0;
    (*env)->GetFloatArrayRegion(env, arr, 0, n, out);
    return 1;
}

JNIEXPORT jlong JNICALL FN(nativeTileParse)(JNIEnv* env, jclass cls, jobject buffer, jint length) {
    (void) cls;
    g_err[0] = 0;
    const uint8_t* data = (const uint8_t*) (*env)->GetDirectBufferAddress(env, buffer);
    const jlong cap = (*env)->GetDirectBufferCapacity(env, buffer);
    if (!data || cap < 0 || length < 0 || (jlong) length > cap) {
        strncpy(g_err, "not a direct buffer", sizeof(g_err) - 1);
        return 0;
    }
    fe_tile* t = fe_tile_parse(data, (size_t) length, g_err, sizeof(g_err));
    return (jlong) (intptr_t) t;
}

JNIEXPORT jstring JNICALL FN(nativeLastError)(JNIEnv* env, jclass cls) {
    (void) cls;
    return (*env)->NewStringUTF(env, g_err);
}

JNIEXPORT void JNICALL FN(nativeTileFree)(JNIEnv* env, jclass cls, jlong handle) {
    (void) env;
    (void) cls;
    fe_tile_free((fe_tile*) (intptr_t) handle);
}

/* [triangles, lines, localIndexCount, featureCount] */
JNIEXPORT jintArray JNICALL FN(nativeTileCounts)(JNIEnv* env, jclass cls, jlong handle) {
    (void) cls;
    const fe_tile* t = (const fe_tile*) (intptr_t) handle;
    jint v[4] = {(jint) fe_tile_triangle_count(t), (jint) fe_tile_line_count(t), (jint) fe_tile_local_index_count(t),
                 (jint) fe_tile_feature_count(t)};
    jintArray out = (*env)->NewIntArray(env, 4);
    if (out) (*env)->SetIntArrayRegion(env, out, 0, 4, v);
    return out;
}

JNIEXPORT jstring JNICALL FN(nativeTileLayer)(JNIEnv* env, jclass cls, jlong handle) {
    (void) cls;
    return (*env)->NewStringUTF(env, fe_tile_layer((const fe_tile*) (intptr_t) handle));
}

JNIEXPORT jstring JNICALL FN(nativeTileBuildId)(JNIEnv* env, jclass cls, jlong handle) {
    (void) cls;
    return (*env)->NewStringUTF(env, fe_tile_build_id((const fe_tile*) (intptr_t) handle));
}

JNIEXPORT jintArray JNICALL FN(nativeTileFeatureIds)(JNIEnv* env, jclass cls, jlong handle) {
    (void) cls;
    const fe_tile* t = (const fe_tile*) (intptr_t) handle;
    const jsize n = (jsize) fe_tile_feature_count(t);
    jintArray out = (*env)->NewIntArray(env, n);
    if (out && n > 0) (*env)->SetIntArrayRegion(env, out, 0, n, (const jint*) fe_tile_feature_ids(t));
    return out;
}

JNIEXPORT jboolean JNICALL FN(nativeTileBounds)(JNIEnv* env, jclass cls, jlong handle, jfloatArray out6) {
    (void) cls;
    float mn[3], mx[3];
    if (!fe_tile_bounds((const fe_tile*) (intptr_t) handle, mn, mx)) return JNI_FALSE;
    const float v[6] = {mn[0], mn[1], mn[2], mx[0], mx[1], mx[2]};
    (*env)->SetFloatArrayRegion(env, out6, 0, 6, v);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL FN(nativeTileLocalBounds)(JNIEnv* env, jclass cls, jlong handle, jint local, jfloatArray out6) {
    (void) cls;
    float mn[3], mx[3];
    if (local < 0 || !fe_tile_local_bounds((const fe_tile*) (intptr_t) handle, (uint32_t) local, mn, mx)) return JNI_FALSE;
    const float v[6] = {mn[0], mn[1], mn[2], mx[0], mx[1], mx[2]};
    (*env)->SetFloatArrayRegion(env, out6, 0, 6, v);
    return JNI_TRUE;
}

/* Returns the hit's local index (-1 when the triangle carries none), or -2 for
 * a miss. out7 = [t, px, py, pz, nx, ny, nz]. */
JNIEXPORT jint JNICALL FN(nativeTileRaycast)(JNIEnv* env, jclass cls, jlong handle, jfloatArray origin, jfloatArray dir, jfloat max_t,
                                             jbyteArray skip, jfloatArray out7) {
    (void) cls;
    float o[3], d[3];
    if (!get_floats(env, origin, o, 3) || !get_floats(env, dir, d, 3)) return -2;
    jbyte* mask = NULL;
    jsize mask_n = 0;
    if (skip) {
        mask_n = (*env)->GetArrayLength(env, skip);
        mask = (*env)->GetByteArrayElements(env, skip, NULL);
    }
    fe_hit hit;
    const int ok = fe_tile_raycast_masked((const fe_tile*) (intptr_t) handle, o, d, max_t, (const uint8_t*) mask, (uint32_t) mask_n, &hit);
    if (mask) (*env)->ReleaseByteArrayElements(env, skip, mask, JNI_ABORT);
    if (!ok) return -2;
    const float v[7] = {hit.t, hit.point[0], hit.point[1], hit.point[2], hit.normal[0], hit.normal[1], hit.normal[2]};
    (*env)->SetFloatArrayRegion(env, out7, 0, 7, v);
    return hit.local_index == FE_NO_FEATURE ? -1 : (jint) hit.local_index;
}

static void corner_out(JNIEnv* env, const fe_corner* c, jfloatArray out12) {
    const float v[12] = {c->pos[0], c->pos[1], c->pos[2], c->face_a[0], c->face_a[1], c->face_b[0], c->face_b[1],
                         c->angle_deg, (float) c->kind, c->span_a, c->span_b, c->rms};
    (*env)->SetFloatArrayRegion(env, out12, 0, 12, v);
}

JNIEXPORT jboolean JNICALL FN(nativeCornerFromPoints)(JNIEnv* env, jclass cls, jfloatArray xyz, jint n, jfloatArray hint, jfloatArray camera,
                                                      jfloat floor_y, jboolean floor_known, jfloat noise, jfloatArray out12) {
    (void) cls;
    float h[3], c[3];
    if (n <= 0 || !get_floats(env, hint, h, 3) || !get_floats(env, camera, c, 3)) return JNI_FALSE;
    if ((*env)->GetArrayLength(env, xyz) < n * 3) return JNI_FALSE;
    jfloat* pts = (*env)->GetFloatArrayElements(env, xyz, NULL);
    if (!pts) return JNI_FALSE;
    fe_corner corner;
    const int ok = fe_corner_from_points(pts, (size_t) n, h, c, floor_y, floor_known ? 1 : 0, noise, &corner);
    (*env)->ReleaseFloatArrayElements(env, xyz, pts, JNI_ABORT);
    if (!ok) return JNI_FALSE;
    corner_out(env, &corner, out12);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL FN(nativeCornerFromPlanes)(JNIEnv* env, jclass cls, jfloatArray ca, jfloatArray na, jfloat ha, jfloatArray cb,
                                                      jfloatArray nb, jfloat hb, jfloatArray hint, jfloatArray camera, jfloat floor_y,
                                                      jboolean floor_known, jfloatArray out12) {
    (void) cls;
    float a[3], an[3], b[3], bn[3], h[3], c[3];
    if (!get_floats(env, ca, a, 3) || !get_floats(env, na, an, 3) || !get_floats(env, cb, b, 3) || !get_floats(env, nb, bn, 3) ||
        !get_floats(env, hint, h, 3) || !get_floats(env, camera, c, 3))
        return JNI_FALSE;
    fe_corner corner;
    if (!fe_corner_from_planes(a, an, ha, b, bn, hb, h, c, floor_y, floor_known ? 1 : 0, &corner)) return JNI_FALSE;
    corner_out(env, &corner, out12);
    return JNI_TRUE;
}

/* out7 = [cx, cy, cz, nx, ny, nz, rms] */
JNIEXPORT jboolean JNICALL FN(nativeFitPlane)(JNIEnv* env, jclass cls, jfloatArray xyz, jint n, jfloatArray out7) {
    (void) cls;
    if (n < 3 || (*env)->GetArrayLength(env, xyz) < n * 3) return JNI_FALSE;
    jfloat* pts = (*env)->GetFloatArrayElements(env, xyz, NULL);
    if (!pts) return JNI_FALSE;
    float c[3], nn[3], rms = 0;
    const int ok = fe_fit_plane(pts, (size_t) n, c, nn, &rms);
    (*env)->ReleaseFloatArrayElements(env, xyz, pts, JNI_ABORT);
    if (!ok) return JNI_FALSE;
    const float v[7] = {c[0], c[1], c[2], nn[0], nn[1], nn[2], rms};
    (*env)->SetFloatArrayRegion(env, out7, 0, 7, v);
    return JNI_TRUE;
}

/* out7 = [cx, cy, cz, nx, ny, nz, distance], camera space */
JNIEXPORT jboolean JNICALL FN(nativeSquarePose)(JNIEnv* env, jclass cls, jfloatArray corners8, jfloat fx, jfloat fy, jfloat cx, jfloat cy,
                                                jfloat edge_m, jfloatArray out7) {
    (void) cls;
    float px[8], c[3], n[3], d = 0;
    if (!get_floats(env, corners8, px, 8)) return JNI_FALSE;
    if (!fe_square_pose(px, fx, fy, cx, cy, edge_m, c, n, &d)) return JNI_FALSE;
    const float v[7] = {c[0], c[1], c[2], n[0], n[1], n[2], d};
    (*env)->SetFloatArrayRegion(env, out7, 0, 7, v);
    return JNI_TRUE;
}

JNIEXPORT jfloat JNICALL FN(nativeSquareEdgeOnPlane)(JNIEnv* env, jclass cls, jfloatArray corners8, jfloat fx, jfloat fy, jfloat cx, jfloat cy,
                                                     jfloatArray point3, jfloatArray normal3) {
    (void) cls;
    float px[8], p[3], n[3];
    if (!get_floats(env, corners8, px, 8) || !get_floats(env, point3, p, 3) || !get_floats(env, normal3, n, 3)) return -1.0f;
    return fe_square_edge_on_plane(px, fx, fy, cx, cy, p, n);
}

/* lines: 4 floats per line (x0, z0, x1, z1). pins: 8 floats per pin
 * (x, y, z, nx, ny, nz, alpha, shape) plus pin_rgb (0xRRGGBB) per pin. */
JNIEXPORT jbyteArray JNICALL FN(nativeOverlayGlb)(JNIEnv* env, jclass cls, jfloatArray lines, jfloat floor_y, jint grid_rgb, jfloatArray pins,
                                                  jintArray pin_rgb) {
    (void) cls;
    const jsize nl = lines ? (*env)->GetArrayLength(env, lines) / 4 : 0;
    const jsize np = pins ? (*env)->GetArrayLength(env, pins) / 8 : 0;
    if (pin_rgb && (*env)->GetArrayLength(env, pin_rgb) < np) return NULL;
    fe_grid_line* gl = (fe_grid_line*) calloc(nl ? (size_t) nl : 1, sizeof(fe_grid_line));
    fe_pin* pp = (fe_pin*) calloc(np ? (size_t) np : 1, sizeof(fe_pin));
    jbyteArray out = NULL;
    if (gl && pp) {
        if (nl) {
            jfloat* l = (*env)->GetFloatArrayElements(env, lines, NULL);
            for (jsize i = 0; l && i < nl; i++) {
                gl[i].x0 = l[i * 4];
                gl[i].z0 = l[i * 4 + 1];
                gl[i].x1 = l[i * 4 + 2];
                gl[i].z1 = l[i * 4 + 3];
            }
            if (l) (*env)->ReleaseFloatArrayElements(env, lines, l, JNI_ABORT);
        }
        if (np) {
            jfloat* p = (*env)->GetFloatArrayElements(env, pins, NULL);
            jint* rgb = pin_rgb ? (*env)->GetIntArrayElements(env, pin_rgb, NULL) : NULL;
            for (jsize i = 0; p && i < np; i++) {
                const jfloat* s = p + i * 8;
                pp[i].pos[0] = s[0];
                pp[i].pos[1] = s[1];
                pp[i].pos[2] = s[2];
                pp[i].normal[0] = s[3];
                pp[i].normal[1] = s[4];
                pp[i].normal[2] = s[5];
                pp[i].alpha = s[6];
                pp[i].shape = (int) s[7];
                pp[i].rgb = rgb ? (uint32_t) rgb[i] & 0xFFFFFFu : 0xEF4444u;
            }
            if (rgb) (*env)->ReleaseIntArrayElements(env, pin_rgb, rgb, JNI_ABORT);
            if (p) (*env)->ReleaseFloatArrayElements(env, pins, p, JNI_ABORT);
        }
        size_t size = 0;
        uint8_t* glb = fe_overlay_glb(gl, (size_t) nl, floor_y, (uint32_t) grid_rgb & 0xFFFFFFu, pp, (size_t) np, &size);
        if (glb) {
            out = (*env)->NewByteArray(env, (jsize) size);
            if (out) (*env)->SetByteArrayRegion(env, out, 0, (jsize) size, (const jbyte*) glb);
            fe_free(glb);
        }
    }
    free(gl);
    free(pp);
    return out;
}

/* ------------------------------------------------------------------------ */
/* Board AprilTags (../../../../src/fe_tag.c), bound to                      */
/* com.fusionapps.fe_ar.FeArTagCore (declared in MarkerDetector.kt).         */
/* ------------------------------------------------------------------------ */

#include "fe_tag.h"

#define TFN(name) Java_com_fusionapps_fe_1ar_FeArTagCore_##name

/* Floats per detection in nativeTagDetect's output. */
#define TAG_STRIDE 13

JNIEXPORT jlong JNICALL TFN(nativeTagDetectorCreate)(JNIEnv* env, jclass cls) {
    (void) env;
    (void) cls;
    return (jlong) (intptr_t) fe_tag_detector_create();
}

JNIEXPORT void JNICALL TFN(nativeTagDetectorFree)(JNIEnv* env, jclass cls, jlong handle) {
    (void) env;
    (void) cls;
    fe_tag_detector_free((fe_tag_detector*) (intptr_t) handle);
}

/*
 * grey: a DIRECT buffer (the camera image's Y plane), row_stride bytes per
 * row, pixel stride 1. roi4 = [x, y, w, h] (w or h <= 0: whole image).
 * out: TAG_STRIDE floats per detection
 *   [id, hamming, margin, blx, bly, brx, bry, trx, try, tlx, tly, cx, cy]
 * Returns the number of detections written.
 */
JNIEXPORT jint JNICALL TFN(nativeTagDetect)(JNIEnv* env, jclass cls, jlong handle, jobject grey, jint width, jint height, jint row_stride,
                                            jintArray roi4, jfloat decimate, jfloatArray out) {
    (void) cls;
    fe_tag_detector* d = (fe_tag_detector*) (intptr_t) handle;
    if (!d || !grey || !out || width <= 0 || height <= 0 || row_stride < width) return 0;
    const uint8_t* data = (const uint8_t*) (*env)->GetDirectBufferAddress(env, grey);
    const jlong cap = (*env)->GetDirectBufferCapacity(env, grey);
    if (!data || cap < (jlong) (height - 1) * row_stride + width) return 0;
    jint roi[4] = {0, 0, 0, 0};
    if (roi4 && (*env)->GetArrayLength(env, roi4) >= 4) (*env)->GetIntArrayRegion(env, roi4, 0, 4, roi);
    const jsize cap_out = (*env)->GetArrayLength(env, out) / TAG_STRIDE;
    if (cap_out <= 0) return 0;
    fe_tag_detection dets[16];
    const int max_out = cap_out < 16 ? (int) cap_out : 16;
    const int n = fe_tag_detect(d, data, width, height, row_stride, roi[0], roi[1], roi[2], roi[3], decimate, dets, max_out);
    for (int i = 0; i < n; i++) {
        float v[TAG_STRIDE];
        v[0] = (float) dets[i].id;
        v[1] = (float) dets[i].hamming;
        v[2] = dets[i].margin;
        for (int k = 0; k < 8; k++) v[3 + k] = dets[i].corners[k];
        v[11] = dets[i].centre[0];
        v[12] = dets[i].centre[1];
        (*env)->SetFloatArrayRegion(env, out, i * TAG_STRIDE, TAG_STRIDE, v);
    }
    return n;
}

/* The payload's tag group (0..145), or -1 when it isn't a marker code (asset tags, anything else). */
JNIEXPORT jint JNICALL TFN(nativeTagGroup)(JNIEnv* env, jclass cls, jstring payload) {
    (void) cls;
    if (!payload) return -1;
    const char* p = (*env)->GetStringUTFChars(env, payload, NULL);
    if (!p) return -1;
    char code[8];
    const int g = fe_marker_code_from_payload(p, code) ? fe_tag_group(code) : -1;
    (*env)->ReleaseStringUTFChars(env, payload, p);
    return g;
}

/* -1 when tag_id isn't one of this payload's board tags, else format * 4 + corner. */
JNIEXPORT jint JNICALL TFN(nativeTagMatch)(JNIEnv* env, jclass cls, jstring payload, jint tag_id) {
    (void) cls;
    if (!payload) return -1;
    const char* p = (*env)->GetStringUTFChars(env, payload, NULL);
    if (!p) return -1;
    char code[8];
    int f = -1, k = -1, r = -1;
    if (fe_marker_code_from_payload(p, code) && fe_tag_match(code, tag_id, &f, &k)) r = f * 4 + k;
    (*env)->ReleaseStringUTFChars(env, payload, p);
    return r;
}

/*
 * Board pose from detections (TAG_STRIDE floats each) of this payload's
 * tags. out13 = [cx, cy, cz, nx, ny, nz, ux, uy, uz, distance, rmsPx, nTags,
 * format], camera space (+X right, +Y up, -Z forward).
 */
JNIEXPORT jboolean JNICALL TFN(nativeTagBoardPose)(JNIEnv* env, jclass cls, jstring payload, jfloatArray dets_in, jint n, jfloat fx, jfloat fy,
                                                   jfloat cx, jfloat cy, jfloatArray out13) {
    (void) cls;
    if (!payload || !dets_in || !out13 || n <= 0 || n > 16) return JNI_FALSE;
    if ((*env)->GetArrayLength(env, dets_in) < n * TAG_STRIDE || (*env)->GetArrayLength(env, out13) < 13) return JNI_FALSE;
    float raw[16 * TAG_STRIDE];
    (*env)->GetFloatArrayRegion(env, dets_in, 0, n * TAG_STRIDE, raw);
    fe_tag_detection dets[16];
    for (int i = 0; i < n; i++) {
        const float* s = raw + i * TAG_STRIDE;
        dets[i].id = (int) s[0];
        dets[i].hamming = (int) s[1];
        dets[i].margin = s[2];
        for (int k = 0; k < 8; k++) dets[i].corners[k] = s[3 + k];
        dets[i].centre[0] = s[11];
        dets[i].centre[1] = s[12];
    }
    const char* p = (*env)->GetStringUTFChars(env, payload, NULL);
    if (!p) return JNI_FALSE;
    char code[8];
    fe_board_pose pose;
    const int ok = fe_marker_code_from_payload(p, code) && fe_board_pose_from_tags(dets, n, code, fx, fy, cx, cy, &pose);
    (*env)->ReleaseStringUTFChars(env, payload, p);
    if (!ok) return JNI_FALSE;
    const float v[13] = {pose.centre[0], pose.centre[1], pose.centre[2], pose.normal[0], pose.normal[1], pose.normal[2], pose.up[0],
                         pose.up[1],     pose.up[2],     pose.distance,  pose.rms_px,    (float) pose.n_tags, (float) pose.format};
    (*env)->SetFloatArrayRegion(env, out13, 0, 13, v);
    return JNI_TRUE;
}
