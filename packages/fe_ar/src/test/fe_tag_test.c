/*
 * Unit tests for fe_tag (board AprilTags, id mapping, planar PnP), runnable
 * on any laptop with a C compiler. From packages/fe_ar:
 *
 *   cc -std=gnu99 -Wall -Wextra -O1 -I src src/fe_tag.c src/fe_apriltag_unity.c src/test/fe_tag_test.c -lm -lpthread -o /tmp/fe_tag_test
 *   /tmp/fe_tag_test
 *
 * With AddressSanitizer + UBSan: add `-g -fsanitize=address,undefined -fno-omit-frame-pointer`.
 *
 * The board images are RENDERED here: a camera at a known pose looks at a
 * board with the four printed tags (supersampled, so edges are anti-aliased
 * like a real photo), and the detector + pose must recover that pose. The
 * golden ids are shared with the server (src/services/ar/print/__tests__/aprilTag.test.ts).
 */
#include "../fe_tag.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../third_party/apriltag/apriltag.h"
#include "../third_party/apriltag/tag36h11.h"

static int g_failed = 0, g_passed = 0;

#define CHECK(cond, ...)                                          \
    do {                                                          \
        if (cond) {                                               \
            g_passed++;                                           \
        } else {                                                  \
            g_failed++;                                           \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);           \
            printf(__VA_ARGS__);                                  \
            printf("\n");                                         \
        }                                                         \
    } while (0)

#define DEG (3.14159265358979323846 / 180.0)

/* ------------------------------------------------------------------ codes */

static void test_codes(void) {
    char c[8];
    CHECK(fe_marker_code_from_payload("HTTPS://ECO.EXAMPLE.COM/M/7K3QX9-R", c) && strcmp(c, "7K3QX9R") == 0, "url payload");
    CHECK(fe_marker_code_from_payload("https://eco.example.com/m/7k3qx9-r/?utm=1", c) && strcmp(c, "7K3QX9R") == 0, "lower-case url + query");
    CHECK(fe_marker_code_from_payload("http://h/M/7K3QX9R#x", c) && strcmp(c, "7K3QX9R") == 0, "fragment");
    CHECK(fe_marker_code_from_payload("  7k3qx9-r ", c) && strcmp(c, "7K3QX9R") == 0, "bare code");
    CHECK(fe_marker_code_from_payload("HTTPS://H/M/7K3QX9%2DR", c) && strcmp(c, "7K3QX9R") == 0, "percent-encoded hyphen");
    CHECK(fe_marker_code_from_payload("OOOOOO-O", c) && strcmp(c, "0000000") == 0, "O aliases to 0");
    CHECK(!fe_marker_code_from_payload("HTTPS://H/M/7K3QX9-S", c), "bad check character");
    CHECK(!fe_marker_code_from_payload("HTTPS://H/X/7K3QX9-R", c), "not a /m/ path");
    CHECK(!fe_marker_code_from_payload("HTTPS://H/M/7K3QX9-R/extra", c), "extra path segment");
    CHECK(!fe_marker_code_from_payload("ASSET:12345", c), "asset tag");
    CHECK(!fe_marker_code_from_payload("7K3QX9-U", c), "U rejected");
    CHECK(!fe_marker_code_from_payload("", c), "empty");

    /* Golden values, shared with the server's aprilTag.test.ts. */
    CHECK(fe_tag_group("7K3QX9R") == 96, "group 7K3QX9R = %d", fe_tag_group("7K3QX9R"));
    CHECK(fe_tag_group("4Q2MA76") == 123, "group 4Q2MA76");
    CHECK(fe_tag_group("0000000") == 71, "group 0000000");
    CHECK(fe_tag_group("ZZZZZZW") == 100, "group ZZZZZZW");
    CHECK(fe_tag_group("ABCDEF5") == 1, "group ABCDEF5");
    CHECK(fe_tag_group("7K3QX9S") == -1, "bad code has no group");
    CHECK(fe_tag_id("7K3QX9R", FE_BOARD_A4, 0) == 384 && fe_tag_id("7K3QX9R", FE_BOARD_A4, 3) == 387, "A4 ids");
    CHECK(fe_tag_id("7K3QX9R", FE_BOARD_A3, 0) == 92, "A3 id %d", fe_tag_id("7K3QX9R", FE_BOARD_A3, 0));
    CHECK(fe_tag_id("0000000", FE_BOARD_A3, 3) == 579, "A3 id wraps");
    CHECK(fe_tag_id("7K3QX9R", FE_BOARD_A4, 4) == -1, "corner out of range");
    int f = -1, k = -1;
    CHECK(fe_tag_match("7K3QX9R", 386, &f, &k) && f == FE_BOARD_A4 && k == 2, "match A4");
    CHECK(fe_tag_match("7K3QX9R", 93, &f, &k) && f == FE_BOARD_A3 && k == 1, "match A3");
    CHECK(!fe_tag_match("7K3QX9R", 388, &f, &k), "neighbour group is not a match");
    /* every code's A4 and A3 ids are disjoint and inside tag36h11 */
    int max_id = 0, overlap = 0;
    for (int g = 0; g < FE_TAG_GROUPS; g++) {
        const int a3 = (g + FE_TAG_A3_SHIFT) % FE_TAG_GROUPS;
        if (a3 == g) overlap++;
        if (4 * a3 + 3 > max_id) max_id = 4 * a3 + 3;
        if (4 * g + 3 > max_id) max_id = 4 * g + 3;
    }
    CHECK(overlap == 0 && max_id < 587, "id space: overlap %d, max %d", overlap, max_id);
}

/* ------------------------------------------------------------ rendering */

typedef struct cam {
    int w, h;
    double fx, fy, cx, cy;
} cam;

typedef struct board {
    double R[9]; /* board -> camera, CV frame (+y down, +z forward) */
    double t[3];
    int format;
    int ids[4];
    int present[4];
    image_u8_t* tags[4];
} board;

static void rot_y(double a, double R[9]) {
    const double c = cos(a), s = sin(a);
    const double m[9] = {c, 0, s, 0, 1, 0, -s, 0, c};
    memcpy(R, m, sizeof(m));
}

static void rot_x(double a, double R[9]) {
    const double c = cos(a), s = sin(a);
    const double m[9] = {1, 0, 0, 0, c, -s, 0, s, c};
    memcpy(R, m, sizeof(m));
}

static void mul3(const double a[9], const double b[9], double o[9]) {
    double r[9];
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    memcpy(o, r, sizeof(r));
}

/* A board seen from the camera: GL-style pose (yaw about up, pitch about x,
 * centre in GL camera space), converted to the CV frame the renderer uses. */
static void make_board(board* b, const char* code, int format, double yaw, double pitch, const double centre_gl[3]) {
    memset(b, 0, sizeof(*b));
    double Ry[9], Rx[9], Rgl[9];
    rot_y(yaw, Ry);
    rot_x(pitch, Rx);
    mul3(Ry, Rx, Rgl);
    for (int j = 0; j < 3; j++) {
        b->R[j] = Rgl[j];
        b->R[3 + j] = -Rgl[3 + j];
        b->R[6 + j] = -Rgl[6 + j];
    }
    b->t[0] = centre_gl[0];
    b->t[1] = -centre_gl[1];
    b->t[2] = -centre_gl[2];
    b->format = format;
    apriltag_family_t* tf = tag36h11_create();
    for (int k = 0; k < 4; k++) {
        b->ids[k] = fe_tag_id(code, format, k);
        b->present[k] = 1;
        b->tags[k] = apriltag_to_image(tf, (uint32_t) b->ids[k]);
    }
    tag36h11_destroy(tf);
}

static void free_board(board* b) {
    for (int k = 0; k < 4; k++) image_u8_destroy(b->tags[k]);
}

/* Board-frame point (metres, +y up) -> pixel (centres at integers). */
static void project(const cam* c, const board* b, double x, double y, double* u, double* v) {
    const double X = b->R[0] * x + b->R[1] * y + b->t[0];
    const double Y = b->R[3] * x + b->R[4] * y + b->t[1];
    const double Z = b->R[6] * x + b->R[7] * y + b->t[2];
    *u = c->fx * X / Z + c->cx;
    *v = c->fy * Y / Z + c->cy;
}

static double shade(const board* b, double bx, double by) {
    float edge, off;
    fe_board_tag_geometry(b->format, &edge, &off);
    const double cell = edge / 8.0;
    const double half = (b->format == FE_BOARD_A4 ? 0.085 : 0.125) + 0.02;
    if (fabs(bx) > half || fabs(by) > half) return 110; /* wall */
    for (int k = 0; k < 4; k++) {
        if (!b->present[k]) continue;
        const double ox = (k == 0 || k == 3) ? -off : off;
        const double oy = (k == 0 || k == 1) ? off : -off;
        const double lx = (bx - ox) / cell + 5.0, ly = (oy - by) / cell + 5.0;
        if (lx < 0 || ly < 0 || lx >= 10 || ly >= 10) continue;
        const image_u8_t* im = b->tags[k];
        return im->buf[(int) ly * im->stride + (int) lx] ? 215 : 25;
    }
    return 215; /* paper */
}

static uint8_t* render(const cam* c, const board* b) {
    uint8_t* img = (uint8_t*) malloc((size_t) c->w * (size_t) c->h);
    const double* R = b->R;
    const double n[3] = {R[2], R[5], R[8]};
    const double nt = n[0] * b->t[0] + n[1] * b->t[1] + n[2] * b->t[2];
    const int S = 3;
    for (int v = 0; v < c->h; v++) {
        for (int u = 0; u < c->w; u++) {
            double acc = 0;
            for (int sy = 0; sy < S; sy++) {
                for (int sx = 0; sx < S; sx++) {
                    const double pu = u - 0.5 + (sx + 0.5) / S, pv = v - 0.5 + (sy + 0.5) / S;
                    const double d[3] = {(pu - c->cx) / c->fx, (pv - c->cy) / c->fy, 1.0};
                    const double den = n[0] * d[0] + n[1] * d[1] + n[2] * d[2];
                    if (fabs(den) < 1e-9) {
                        acc += 110;
                        continue;
                    }
                    const double s = nt / den;
                    const double q[3] = {s * d[0] - b->t[0], s * d[1] - b->t[1], s * d[2] - b->t[2]};
                    const double bx = R[0] * q[0] + R[3] * q[1] + R[6] * q[2];
                    const double by = R[1] * q[0] + R[4] * q[1] + R[7] * q[2];
                    acc += shade(b, bx, by);
                }
            }
            img[(size_t) v * (size_t) c->w + (size_t) u] = (uint8_t) (acc / (S * S) + 0.5);
        }
    }
    return img;
}

static double angle_deg(const float a[3], const double b[3]) {
    const double la = sqrt((double) a[0] * a[0] + (double) a[1] * a[1] + (double) a[2] * a[2]);
    const double lb = sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2]);
    double c = (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (la * lb);
    if (c > 1) c = 1;
    if (c < -1) c = -1;
    return acos(c) / DEG;
}

/* Truth in the core's GL camera frame. */
static void truth_gl(const board* b, double centre[3], double normal[3], double up[3]) {
    centre[0] = b->t[0];
    centre[1] = -b->t[1];
    centre[2] = -b->t[2];
    normal[0] = b->R[2];
    normal[1] = -b->R[5];
    normal[2] = -b->R[8];
    up[0] = b->R[1];
    up[1] = -b->R[4];
    up[2] = -b->R[7];
}

static void test_board(const char* name, const char* code, int format, double yaw, double pitch, const double centre[3],
                       float decimate, int use_roi, double tol_mm, double tol_deg) {
    const cam c = {1920, 1080, 1450, 1450, 959.5, 539.5};
    board b;
    make_board(&b, code, format, yaw, pitch, centre);
    uint8_t* img = render(&c, &b);
    fe_tag_detector* det = fe_tag_detector_create();
    CHECK(det != NULL, "%s: detector", name);
    int rx = 0, ry = 0, rw = 0, rh = 0;
    if (use_roi) {
        /* the frame's bounding box, as the platform half derives it from the QR */
        double umin = 1e9, vmin = 1e9, umax = -1e9, vmax = -1e9;
        const double h = format == FE_BOARD_A4 ? 0.095 : 0.14;
        for (int i = 0; i < 4; i++) {
            double u, v;
            project(&c, &b, (i & 1) ? h : -h, (i & 2) ? h : -h, &u, &v);
            umin = fmin(umin, u), umax = fmax(umax, u), vmin = fmin(vmin, v), vmax = fmax(vmax, v);
        }
        rx = (int) umin, ry = (int) vmin, rw = (int) (umax - umin) + 1, rh = (int) (vmax - vmin) + 1;
    }
    fe_tag_detection dets[16];
    const int n = fe_tag_detect(det, img, c.w, c.h, c.w, rx, ry, rw, rh, decimate, dets, 16);
    CHECK(n == 4, "%s: %d tags detected", name, n);

    /* ids and the corner order (bottom-left, bottom-right, top-right, top-left of each printed tag) */
    float edge, off;
    fe_board_tag_geometry(format, &edge, &off);
    double worst = 0;
    for (int i = 0; i < n; i++) {
        int f, k;
        CHECK(fe_tag_match(code, dets[i].id, &f, &k) && f == format, "%s: id %d belongs to the code", name, dets[i].id);
        if (!fe_tag_match(code, dets[i].id, &f, &k)) continue;
        const double ox = (k == 0 || k == 3) ? -off : off, oy = (k == 0 || k == 1) ? off : -off;
        static const double tx[4] = {-1, 1, 1, -1}, ty[4] = {-1, -1, 1, 1}; /* board frame, +y up */
        for (int q = 0; q < 4; q++) {
            double u, v;
            project(&c, &b, ox + tx[q] * edge / 2, oy + ty[q] * edge / 2, &u, &v);
            const double e = hypot(u - dets[i].corners[q * 2], v - dets[i].corners[q * 2 + 1]);
            if (e > worst) worst = e;
        }
    }
    CHECK(worst < 0.5, "%s: worst corner error %.3f px", name, worst);

    fe_board_pose pose;
    const int ok = fe_board_pose_from_tags(dets, n, code, (float) c.fx, (float) c.fy, (float) c.cx, (float) c.cy, &pose);
    CHECK(ok, "%s: board pose", name);
    if (ok) {
        double tc[3], tn[3], tu[3];
        truth_gl(&b, tc, tn, tu);
        const double err = sqrt((pose.centre[0] - tc[0]) * (pose.centre[0] - tc[0]) + (pose.centre[1] - tc[1]) * (pose.centre[1] - tc[1]) +
                                (pose.centre[2] - tc[2]) * (pose.centre[2] - tc[2])) *
                           1000.0;
        const double an = angle_deg(pose.normal, tn), au = angle_deg(pose.up, tu);
        CHECK(err < tol_mm, "%s: centre error %.2f mm", name, err);
        CHECK(an < tol_deg, "%s: normal error %.3f deg", name, an);
        CHECK(au < tol_deg, "%s: up error %.3f deg", name, au);
        CHECK(pose.n_tags == 4 && pose.format == format, "%s: %d tags, format %d", name, pose.n_tags, pose.format);
        CHECK(pose.rms_px < 0.5f, "%s: rms %.3f px", name, pose.rms_px);
        printf("  %-28s centre %.2f mm  normal %.3f deg  up %.3f deg  rms %.3f px\n", name, err, an, au, pose.rms_px);
    }

    /* another board's code: none of these tags are its */
    CHECK(!fe_board_pose_from_tags(dets, n, "4Q2MA76", (float) c.fx, (float) c.fy, (float) c.cx, (float) c.cy, &pose),
          "%s: foreign code gives no pose", name);

    /* one tag alone still gives a pose (the platform half may require more) */
    if (n == 4) {
        fe_tag_detection one[1];
        for (int i = 0; i < n; i++) {
            int k;
            if (fe_tag_match(code, dets[i].id, NULL, &k) && k == 2) one[0] = dets[i];
        }
        CHECK(fe_board_pose_from_tags(one, 1, code, (float) c.fx, (float) c.fy, (float) c.cx, (float) c.cy, &pose) && pose.n_tags == 1,
              "%s: single-tag pose", name);
    }
    fe_tag_detector_free(det);
    free(img);
    free_board(&b);
}

/* ------------------------------------------------------------------- PnP */

static uint32_t g_rng = 12345;
static double urand(void) {
    g_rng = g_rng * 1664525u + 1013904223u;
    return (g_rng >> 8) / 16777216.0;
}
static double gauss(void) {
    const double a = urand() + 1e-12, b = urand();
    return sqrt(-2 * log(a)) * cos(2 * 3.14159265358979 * b);
}

static void test_planar_pose(void) {
    const cam c = {1920, 1080, 1450, 1450, 959.5, 539.5};
    board b;
    const double centre[3] = {0.1, 0.05, -1.4};
    make_board(&b, "7K3QX9R", FE_BOARD_A4, 35 * DEG, -8 * DEG, centre);
    /* the 16 tag corners of an A4 board, with 0.15 px noise */
    float obj[32], img[32];
    int np = 0;
    for (int k = 0; k < 4; k++) {
        const double ox = (k == 0 || k == 3) ? -0.07125 : 0.07125, oy = (k == 0 || k == 1) ? 0.07125 : -0.07125;
        for (int q = 0; q < 4; q++) {
            const double x = ox + ((q == 1 || q == 2) ? 0.011 : -0.011), y = oy + (q < 2 ? -0.011 : 0.011);
            double u, v;
            project(&c, &b, x, y, &u, &v);
            obj[np * 2] = (float) x;
            obj[np * 2 + 1] = (float) y;
            img[np * 2] = (float) (u + 0.15 * gauss());
            img[np * 2 + 1] = (float) (v + 0.15 * gauss());
            np++;
        }
    }
    float R[9], t[3], rms;
    CHECK(fe_planar_pose(obj, img, np, (float) c.fx, (float) c.fy, (float) c.cx, (float) c.cy, R, t, &rms), "planar pose");
    double tc[3], tn[3], tu[3];
    truth_gl(&b, tc, tn, tu);
    const double err = sqrt((t[0] - tc[0]) * (t[0] - tc[0]) + (t[1] - tc[1]) * (t[1] - tc[1]) + (t[2] - tc[2]) * (t[2] - tc[2])) * 1000;
    const float nrm[3] = {R[2], R[5], R[8]};
    CHECK(err < 6.0, "planar pose centre error %.2f mm at 1.4 m", err);
    CHECK(angle_deg(nrm, tn) < 1.0, "planar pose normal error %.3f deg", angle_deg(nrm, tn));
    CHECK(rms < 0.4f, "planar pose rms %.3f", rms);
    printf("  %-28s centre %.2f mm  normal %.3f deg  rms %.3f px\n", "pnp 1.4 m, 0.15 px noise", err, angle_deg(nrm, tn), rms);
    CHECK(!fe_planar_pose(obj, img, 3, 1450, 1450, 959.5f, 539.5f, R, t, &rms), "needs 4 points");
    free_board(&b);
}

int main(void) {
    test_codes();
    test_planar_pose();
    {
        const double c1[3] = {0.03, -0.02, -0.7};
        test_board("A4 0.7 m, 25 deg yaw", "7K3QX9R", FE_BOARD_A4, 25 * DEG, 8 * DEG, c1, 2.0f, 0, 3.0, 0.8);
        test_board("A4 0.7 m, ROI, decimate 1", "7K3QX9R", FE_BOARD_A4, 25 * DEG, 8 * DEG, c1, 1.0f, 1, 3.0, 0.8);
        const double c2[3] = {-0.1, 0.08, -1.2};
        test_board("A4 1.2 m, -30 deg, ROI", "ABCDEF5", FE_BOARD_A4, -30 * DEG, -5 * DEG, c2, 1.0f, 1, 5.0, 1.0);
        const double c3[3] = {0.0, 0.0, -1.5};
        test_board("A3 1.5 m, 15 deg, ROI", "0000000", FE_BOARD_A3, 15 * DEG, 0, c3, 1.0f, 1, 5.0, 1.0);
    }
    printf("%d passed, %d failed\n", g_passed, g_failed);
    return g_failed ? 1 : 0;
}
