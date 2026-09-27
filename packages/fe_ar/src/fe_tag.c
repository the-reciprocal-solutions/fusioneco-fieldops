/*
 * fe_tag: board fiducials (AprilTag tag36h11) and the board pose. See fe_tag.h.
 *
 * The detector itself is AprilTag 3 (third_party/apriltag, BSD-2-Clause,
 * University of Michigan), compiled by fe_apriltag_unity.c. Everything in
 * this file is ours: the id mapping (kept byte-for-byte in step with the
 * server's src/services/ar/print/aprilTag.ts), the board layout, and a
 * planar PnP (homography + Levenberg-Marquardt over both planar solutions).
 */
#include "fe_tag.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "third_party/apriltag/apriltag.h"
#include "third_party/apriltag/tag36h11.h"

/* ------------------------------------------------------------------------ */
/* Codes and ids                                                             */
/* ------------------------------------------------------------------------ */

static const char FE_ALPHABET[] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

static int alpha_index(char c) {
    for (int i = 0; i < 32; i++)
        if (FE_ALPHABET[i] == c) return i;
    return -1;
}

static int valid_code7(const char* c) {
    if (!c) return 0;
    int sum = 0;
    for (int i = 0; i < 6; i++) {
        const int v = alpha_index(c[i]);
        if (v < 0) return 0;
        sum += (2 * i + 1) * v;
    }
    return c[6] == FE_ALPHABET[sum % 32] && c[7] == 0;
}

static int is_space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; }

static char upper(char c) { return (c >= 'a' && c <= 'z') ? (char) (c - 32) : c; }

/* markerCodeService.normalizeCode over s[0..n). */
static int normalize_code(const char* s, size_t n, char out[8]) {
    char buf[8];
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        char ch = upper(s[i]);
        if (is_space(ch) || ch == '-') continue;
        if (k >= 7) return 0;
        if (ch == 'U') return 0;
        if (ch == 'O') ch = '0';
        if (ch == 'I' || ch == 'L') ch = '1';
        if (alpha_index(ch) < 0) return 0;
        buf[k++] = ch;
    }
    if (k != 7) return 0;
    buf[7] = 0;
    if (!valid_code7(buf)) return 0;
    memcpy(out, buf, 8);
    return 1;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    c = upper(c);
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int fe_marker_code_from_payload(const char* payload, char code_out[8]) {
    if (!payload) return 0;
    const char* s = payload;
    size_t n = strlen(s);
    while (n && is_space(*s)) s++, n--;
    while (n && is_space(s[n - 1])) n--;
    if (!n) return 0;

    /* ^[a-z][a-z0-9+.-]*://[^/?#\s]+/m/([^/?#\s]+)/?(?:[?#].*)?$  (case-insensitive) */
    size_t i = 0;
    const char c0 = upper(s[0]);
    if (c0 >= 'A' && c0 <= 'Z') {
        i = 1;
        while (i < n) {
            const char c = upper(s[i]);
            if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-')
                i++;
            else
                break;
        }
        if (i + 3 <= n && s[i] == ':' && s[i + 1] == '/' && s[i + 2] == '/') {
            size_t h = i + 3;
            const size_t host0 = h;
            while (h < n && s[h] != '/' && s[h] != '?' && s[h] != '#' && !is_space(s[h])) h++;
            if (h == host0 || h + 3 > n || s[h] != '/' || upper(s[h + 1]) != 'M' || s[h + 2] != '/') return 0;
            size_t p = h + 3;
            const size_t code0 = p;
            while (p < n && s[p] != '/' && s[p] != '?' && s[p] != '#' && !is_space(s[p])) p++;
            const size_t code1 = p;
            if (code1 == code0) return 0;
            if (p < n && s[p] == '/') p++;
            if (p < n && s[p] != '?' && s[p] != '#') return 0;
            /* decodeURIComponent over the code segment */
            char dec[64];
            size_t k = 0;
            for (size_t j = code0; j < code1; j++) {
                if (k >= sizeof(dec)) return 0;
                if (s[j] == '%') {
                    if (j + 2 >= code1) return 0;
                    const int a = hexval(s[j + 1]), b = hexval(s[j + 2]);
                    if (a < 0 || b < 0) return 0;
                    dec[k++] = (char) (a * 16 + b);
                    j += 2;
                } else {
                    dec[k++] = s[j];
                }
            }
            return normalize_code(dec, k, code_out);
        }
    }
    for (size_t j = 0; j < n; j++)
        if (s[j] == '/' || s[j] == ':') return 0;
    return normalize_code(s, n, code_out);
}

int fe_tag_group(const char* code7) {
    if (!valid_code7(code7)) return -1;
    uint32_t h = 0x811c9dc5u;
    for (int i = 0; i < 7; i++) {
        h ^= (uint8_t) code7[i];
        h *= 0x01000193u;
    }
    return (int) (h % FE_TAG_GROUPS);
}

int fe_tag_id(const char* code7, int format, int corner) {
    const int g = fe_tag_group(code7);
    if (g < 0 || corner < 0 || corner > 3) return -1;
    int G;
    if (format == FE_BOARD_A4)
        G = g;
    else if (format == FE_BOARD_A3)
        G = (g + FE_TAG_A3_SHIFT) % FE_TAG_GROUPS;
    else
        return -1;
    return 4 * G + corner;
}

int fe_tag_match(const char* code7, int tag_id, int* format, int* corner) {
    for (int f = FE_BOARD_A4; f <= FE_BOARD_A3; f++) {
        const int base = fe_tag_id(code7, f, 0);
        if (base < 0) return 0;
        if (tag_id >= base && tag_id < base + 4) {
            if (format) *format = f;
            if (corner) *corner = tag_id - base;
            return 1;
        }
    }
    return 0;
}

int fe_board_tag_geometry(int format, float* edge_m, float* offset_m) {
    float e, o;
    if (format == FE_BOARD_A4) {
        e = 0.022f;
        o = 0.07125f;
    } else if (format == FE_BOARD_A3) {
        e = 0.032f;
        o = 0.105f;
    } else {
        return 0;
    }
    if (edge_m) *edge_m = e;
    if (offset_m) *offset_m = o;
    return 1;
}

/* ------------------------------------------------------------------------ */
/* Detection                                                                 */
/* ------------------------------------------------------------------------ */

struct fe_tag_detector {
    apriltag_family_t* family;
    apriltag_detector_t* td;
};

fe_tag_detector* fe_tag_detector_create(void) {
    fe_tag_detector* d = (fe_tag_detector*) calloc(1, sizeof(fe_tag_detector));
    if (!d) return NULL;
    d->family = tag36h11_create();
    d->td = apriltag_detector_create();
    if (!d->family || !d->td) {
        fe_tag_detector_free(d);
        return NULL;
    }
    /* One corrected bit: a far smaller decode table than the default 2, and
     * the QR pairing (group + position) already rejects stray matches. */
    apriltag_detector_add_family_bits(d->td, d->family, 1);
    d->td->nthreads = 1;
    d->td->quad_sigma = 0.0f; /* never write into the caller's buffer */
    d->td->refine_edges = true;
    d->td->decode_sharpening = 0.25;
    d->td->debug = false;
    return d;
}

void fe_tag_detector_free(fe_tag_detector* d) {
    if (!d) return;
    if (d->td) apriltag_detector_destroy(d->td);
    if (d->family) tag36h11_destroy(d->family);
    free(d);
}

int fe_tag_detect(fe_tag_detector* d, const uint8_t* grey, int width, int height, int stride, int roi_x, int roi_y,
                  int roi_w, int roi_h, float decimate, fe_tag_detection* out, int max_out) {
    if (!d || !grey || width <= 0 || height <= 0 || stride < width || !out || max_out <= 0) return 0;
    if (roi_w <= 0 || roi_h <= 0) {
        roi_x = 0;
        roi_y = 0;
        roi_w = width;
        roi_h = height;
    }
    if (roi_x < 0) roi_w += roi_x, roi_x = 0;
    if (roi_y < 0) roi_h += roi_y, roi_y = 0;
    if (roi_x + roi_w > width) roi_w = width - roi_x;
    if (roi_y + roi_h > height) roi_h = height - roi_y;
    if (roi_w < 16 || roi_h < 16) return 0;
    d->td->quad_decimate = decimate >= 1.0f ? decimate : 1.0f;

    /* A view into the caller's buffer: with quad_sigma 0 the detector only
     * reads it (decimation, thresholding and sampling all allocate). */
    image_u8_t im = {.width = roi_w,
                     .height = roi_h,
                     .stride = stride,
                     .buf = (uint8_t*) (grey + (size_t) roi_y * (size_t) stride + (size_t) roi_x)};
    zarray_t* dets = apriltag_detector_detect(d->td, &im);
    if (!dets) return 0;
    int count = 0;
    for (int i = 0; i < zarray_size(dets) && count < max_out; i++) {
        apriltag_detection_t* det;
        zarray_get(dets, i, &det);
        fe_tag_detection* o = &out[count++];
        o->id = det->id;
        o->hamming = det->hamming;
        o->margin = det->decision_margin;
        for (int k = 0; k < 4; k++) {
            o->corners[k * 2] = (float) (det->p[k][0] - 0.5 + roi_x);
            o->corners[k * 2 + 1] = (float) (det->p[k][1] - 0.5 + roi_y);
        }
        o->centre[0] = (float) (det->c[0] - 0.5 + roi_x);
        o->centre[1] = (float) (det->c[1] - 0.5 + roi_y);
    }
    apriltag_detections_destroy(dets);
    return count;
}

/* ------------------------------------------------------------------------ */
/* Planar PnP                                                                */
/* ------------------------------------------------------------------------ */

/* Internally in the computer-vision camera frame (+x right, +y down, +z
 * forward); converted to the core's (+X right, +Y up, -Z forward) at the end. */

static void mat3_mul(const double a[9], const double b[9], double o[9]) {
    double r[9];
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    memcpy(o, r, sizeof(r));
}

static void rodrigues(const double w[3], double R[9]) {
    const double th = sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]);
    if (th < 1e-12) {
        const double I[9] = {1, -w[2], w[1], w[2], 1, -w[0], -w[1], w[0], 1};
        memcpy(R, I, sizeof(I));
        return;
    }
    const double k[3] = {w[0] / th, w[1] / th, w[2] / th};
    const double c = cos(th), s = sin(th), v = 1 - c;
    R[0] = c + k[0] * k[0] * v;
    R[1] = k[0] * k[1] * v - k[2] * s;
    R[2] = k[0] * k[2] * v + k[1] * s;
    R[3] = k[1] * k[0] * v + k[2] * s;
    R[4] = c + k[1] * k[1] * v;
    R[5] = k[1] * k[2] * v - k[0] * s;
    R[6] = k[2] * k[0] * v - k[1] * s;
    R[7] = k[2] * k[1] * v + k[0] * s;
    R[8] = c + k[2] * k[2] * v;
}

/* Nearest rotation: Newton polar iteration R <- (R + R^-T) / 2. */
static int orthonormalize(double R[9]) {
    for (int it = 0; it < 30; it++) {
        const double* m = R;
        const double det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) +
                           m[2] * (m[3] * m[7] - m[4] * m[6]);
        if (fabs(det) < 1e-12) return 0;
        /* inverse transpose = cofactor matrix / det */
        double C[9];
        C[0] = (m[4] * m[8] - m[5] * m[7]) / det;
        C[1] = -(m[3] * m[8] - m[5] * m[6]) / det;
        C[2] = (m[3] * m[7] - m[4] * m[6]) / det;
        C[3] = -(m[1] * m[8] - m[2] * m[7]) / det;
        C[4] = (m[0] * m[8] - m[2] * m[6]) / det;
        C[5] = -(m[0] * m[7] - m[1] * m[6]) / det;
        C[6] = (m[1] * m[5] - m[2] * m[4]) / det;
        C[7] = -(m[0] * m[5] - m[2] * m[3]) / det;
        C[8] = (m[0] * m[4] - m[1] * m[3]) / det;
        double diff = 0;
        for (int i = 0; i < 9; i++) {
            const double nv = 0.5 * (R[i] + C[i]);
            diff += fabs(nv - R[i]);
            R[i] = nv;
        }
        if (diff < 1e-13) break;
    }
    return 1;
}

/* Gaussian elimination with partial pivoting, n <= 9. */
static int solve_linear(double* A, double* b, int n) {
    for (int c = 0; c < n; c++) {
        int p = c;
        for (int r = c + 1; r < n; r++)
            if (fabs(A[r * n + c]) > fabs(A[p * n + c])) p = r;
        if (fabs(A[p * n + c]) < 1e-18) return 0;
        if (p != c) {
            for (int k = 0; k < n; k++) {
                const double t = A[c * n + k];
                A[c * n + k] = A[p * n + k];
                A[p * n + k] = t;
            }
            const double t = b[c];
            b[c] = b[p];
            b[p] = t;
        }
        for (int r = c + 1; r < n; r++) {
            const double f = A[r * n + c] / A[c * n + c];
            for (int k = c; k < n; k++) A[r * n + k] -= f * A[c * n + k];
            b[r] -= f * b[c];
        }
    }
    for (int r = n - 1; r >= 0; r--) {
        double s = b[r];
        for (int k = r + 1; k < n; k++) s -= A[r * n + k] * b[k];
        b[r] = s / A[r * n + r];
    }
    return 1;
}

typedef struct pnp_data {
    const float* obj;
    const float* img;
    int n;
    double fx, fy, cx, cy;
} pnp_data;

/* Residuals (2n) in pixels; returns the sum of squares, or HUGE_VAL if any point is behind the camera. */
static double residuals(const pnp_data* d, const double R[9], const double t[3], double* res) {
    double ss = 0;
    for (int i = 0; i < d->n; i++) {
        const double X = d->obj[i * 2], Y = d->obj[i * 2 + 1];
        const double pc[3] = {R[0] * X + R[1] * Y + t[0], R[3] * X + R[4] * Y + t[1], R[6] * X + R[7] * Y + t[2]};
        if (pc[2] <= 1e-6) return HUGE_VAL;
        const double u = d->fx * pc[0] / pc[2] + d->cx, v = d->fy * pc[1] / pc[2] + d->cy;
        const double ru = u - d->img[i * 2], rv = v - d->img[i * 2 + 1];
        if (res) {
            res[i * 2] = ru;
            res[i * 2 + 1] = rv;
        }
        ss += ru * ru + rv * rv;
    }
    return ss;
}

/* Levenberg-Marquardt over (rotation increment, translation). */
static double refine(const pnp_data* d, double R[9], double t[3]) {
    const int m = d->n * 2;
    double* r0 = (double*) malloc(sizeof(double) * (size_t) m * 8);
    if (!r0) return HUGE_VAL;
    double* J = r0 + m;     /* 6 columns of m */
    double* rt = r0 + 7 * m; /* scratch */
    double cost = residuals(d, R, t, r0);
    double lambda = 1e-3;
    for (int it = 0; it < 40 && cost < HUGE_VAL; it++) {
        /* numeric Jacobian */
        for (int p = 0; p < 6; p++) {
            double Rp[9], tp[3];
            memcpy(Rp, R, sizeof(Rp));
            memcpy(tp, t, sizeof(tp));
            const double h = p < 3 ? 1e-6 : 1e-6 * (fabs(t[2]) + 1e-3);
            if (p < 3) {
                double w[3] = {0, 0, 0}, dR[9];
                w[p] = h;
                rodrigues(w, dR);
                mat3_mul(dR, R, Rp);
            } else {
                tp[p - 3] += h;
            }
            if (residuals(d, Rp, tp, rt) == HUGE_VAL) {
                free(r0);
                return cost;
            }
            for (int k = 0; k < m; k++) J[p * m + k] = (rt[k] - r0[k]) / h;
        }
        double JtJ[36], Jtr[6];
        for (int a = 0; a < 6; a++) {
            double s = 0;
            for (int k = 0; k < m; k++) s += J[a * m + k] * r0[k];
            Jtr[a] = -s;
            for (int b = 0; b < 6; b++) {
                double q = 0;
                for (int k = 0; k < m; k++) q += J[a * m + k] * J[b * m + k];
                JtJ[a * 6 + b] = q;
            }
        }
        int improved = 0;
        for (int tries = 0; tries < 8 && !improved; tries++) {
            double A[36], x[6];
            memcpy(A, JtJ, sizeof(A));
            memcpy(x, Jtr, sizeof(x));
            for (int a = 0; a < 6; a++) A[a * 6 + a] *= 1.0 + lambda;
            if (!solve_linear(A, x, 6)) {
                lambda *= 10;
                continue;
            }
            double dR[9], Rn[9], tn[3] = {t[0] + x[3], t[1] + x[4], t[2] + x[5]};
            rodrigues(x, dR);
            mat3_mul(dR, R, Rn);
            const double c = residuals(d, Rn, tn, rt);
            if (c < cost) {
                memcpy(R, Rn, sizeof(Rn));
                memcpy(t, tn, sizeof(tn));
                memcpy(r0, rt, sizeof(double) * (size_t) m);
                const double rel = (cost - c) / (cost + 1e-30);
                cost = c;
                lambda = lambda * 0.3 > 1e-9 ? lambda * 0.3 : 1e-9;
                improved = 1;
                if (rel < 1e-12) it = 1000;
            } else {
                lambda *= 10;
            }
        }
        if (!improved) break;
    }
    orthonormalize(R);
    cost = residuals(d, R, t, NULL);
    free(r0);
    return cost;
}

/* Homography (target plane -> normalised image) by DLT with h33 = 1. */
static int homography(const pnp_data* d, double H[9]) {
    /* normalise the target points for conditioning */
    double mx = 0, my = 0, sc = 0;
    for (int i = 0; i < d->n; i++) mx += d->obj[i * 2], my += d->obj[i * 2 + 1];
    mx /= d->n;
    my /= d->n;
    for (int i = 0; i < d->n; i++) sc += hypot(d->obj[i * 2] - mx, d->obj[i * 2 + 1] - my);
    sc = sc > 0 ? d->n / sc : 1.0;
    double A[64] = {0}, b[8] = {0};
    for (int i = 0; i < d->n; i++) {
        const double X = (d->obj[i * 2] - mx) * sc, Y = (d->obj[i * 2 + 1] - my) * sc;
        const double u = (d->img[i * 2] - d->cx) / d->fx, v = (d->img[i * 2 + 1] - d->cy) / d->fy;
        const double r1[8] = {X, Y, 1, 0, 0, 0, -u * X, -u * Y};
        const double r2[8] = {0, 0, 0, X, Y, 1, -v * X, -v * Y};
        for (int a = 0; a < 8; a++) {
            b[a] += r1[a] * u + r2[a] * v;
            for (int c = 0; c < 8; c++) A[a * 8 + c] += r1[a] * r1[c] + r2[a] * r2[c];
        }
    }
    if (!solve_linear(A, b, 8)) return 0;
    const double Hn[9] = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], 1};
    /* undo the normalisation: H = Hn * T, T = [sc 0 -sc*mx; 0 sc -sc*my; 0 0 1] */
    const double T[9] = {sc, 0, -sc * mx, 0, sc, -sc * my, 0, 0, 1};
    mat3_mul(Hn, T, H);
    return 1;
}

int fe_planar_pose(const float* obj_xy, const float* img_px, int n, float fx, float fy, float cx, float cy, float Rout[9],
                   float tout[3], float* rms_px) {
    if (!obj_xy || !img_px || n < 4 || !(fx > 0 && fy > 0)) return 0;
    const pnp_data d = {obj_xy, img_px, n, fx, fy, cx, cy};
    double H[9];
    if (!homography(&d, H)) return 0;
    /* H ~ [r1 r2 t] */
    double h1[3] = {H[0], H[3], H[6]}, h2[3] = {H[1], H[4], H[7]}, h3[3] = {H[2], H[5], H[8]};
    const double n1 = sqrt(h1[0] * h1[0] + h1[1] * h1[1] + h1[2] * h1[2]);
    const double n2 = sqrt(h2[0] * h2[0] + h2[1] * h2[1] + h2[2] * h2[2]);
    if (n1 < 1e-12 || n2 < 1e-12) return 0;
    double lam = 2.0 / (n1 + n2);
    if (h3[2] < 0) lam = -lam; /* the target is in front: t.z > 0 */
    double R[9], t[3];
    for (int i = 0; i < 3; i++) {
        R[i * 3] = h1[i] * lam;
        R[i * 3 + 1] = h2[i] * lam;
        t[i] = h3[i] * lam;
    }
    R[2] = R[3] * R[7] - R[6] * R[4];
    R[5] = R[6] * R[1] - R[0] * R[7];
    R[8] = R[0] * R[4] - R[3] * R[1];
    if (!orthonormalize(R)) return 0;

    /* Second planar solution: the normal mirrored about the line of sight. */
    double R2[9], t2[3];
    memcpy(R2, R, sizeof(R2));
    memcpy(t2, t, sizeof(t2));
    {
        const double tn = sqrt(t[0] * t[0] + t[1] * t[1] + t[2] * t[2]);
        const double v[3] = {-t[0] / tn, -t[1] / tn, -t[2] / tn};
        const double nrm[3] = {R[2], R[5], R[8]};
        const double dv = nrm[0] * v[0] + nrm[1] * v[1] + nrm[2] * v[2];
        const double nm[3] = {2 * dv * v[0] - nrm[0], 2 * dv * v[1] - nrm[1], 2 * dv * v[2] - nrm[2]};
        double ax[3] = {nrm[1] * nm[2] - nrm[2] * nm[1], nrm[2] * nm[0] - nrm[0] * nm[2], nrm[0] * nm[1] - nrm[1] * nm[0]};
        const double s = sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
        const double c = nrm[0] * nm[0] + nrm[1] * nm[1] + nrm[2] * nm[2];
        if (s > 1e-9) {
            const double ang = atan2(s, c);
            const double w[3] = {ax[0] / s * ang, ax[1] / s * ang, ax[2] / s * ang};
            double Q[9];
            rodrigues(w, Q);
            mat3_mul(Q, R, R2);
        }
    }
    double c1 = refine(&d, R, t);
    double c2 = refine(&d, R2, t2);
    if (c2 < c1) {
        memcpy(R, R2, sizeof(R));
        memcpy(t, t2, sizeof(t));
        c1 = c2;
    }
    if (!(c1 < HUGE_VAL) || !(t[2] > 0)) return 0;
    /* CV -> core camera frame: flip y and z */
    for (int j = 0; j < 3; j++) {
        Rout[j] = (float) R[j];
        Rout[3 + j] = (float) -R[3 + j];
        Rout[6 + j] = (float) -R[6 + j];
    }
    tout[0] = (float) t[0];
    tout[1] = (float) -t[1];
    tout[2] = (float) -t[2];
    if (rms_px) *rms_px = (float) sqrt(c1 / n);
    return 1;
}

/* ------------------------------------------------------------------------ */
/* Board pose                                                                */
/* ------------------------------------------------------------------------ */

int fe_board_pose_from_tags(const fe_tag_detection* dets, int n, const char* code7, float fx, float fy, float cx, float cy,
                            fe_board_pose* out) {
    if (!dets || n <= 0 || !out || fe_tag_group(code7) < 0) return 0;
    int format = -1;
    float obj[32], img[32];
    int np = 0, ntags = 0, used = 0;
    float edge = 0, off = 0;
    for (int i = 0; i < n && ntags < 4; i++) {
        int f, k;
        if (!fe_tag_match(code7, dets[i].id, &f, &k)) continue;
        if (format < 0) {
            format = f;
            fe_board_tag_geometry(format, &edge, &off);
        }
        if (f != format || (used & (1 << k))) continue;
        used |= 1 << k;
        ntags++;
        /* corner k centre in the board frame (+y up) */
        const float ox = (k == 0 || k == 3) ? -off : off;
        const float oy = (k == 0 || k == 1) ? off : -off;
        /* AprilTag corner order in the tag frame (y down as printed):
         * (-1,+1) bottom-left, (+1,+1) bottom-right, (+1,-1) top-right, (-1,-1) top-left */
        static const float tx[4] = {-1, 1, 1, -1}, ty[4] = {1, 1, -1, -1};
        for (int c = 0; c < 4; c++) {
            obj[np * 2] = ox + tx[c] * edge * 0.5f;
            obj[np * 2 + 1] = oy - ty[c] * edge * 0.5f;
            img[np * 2] = dets[i].corners[c * 2];
            img[np * 2 + 1] = dets[i].corners[c * 2 + 1];
            np++;
        }
    }
    if (ntags == 0) return 0;
    float R[9], t[3], rms;
    if (!fe_planar_pose(obj, img, np, fx, fy, cx, cy, R, t, &rms)) return 0;
    memset(out, 0, sizeof(*out));
    for (int j = 0; j < 3; j++) {
        out->centre[j] = t[j];
        out->normal[j] = R[j * 3 + 2];
        out->up[j] = R[j * 3 + 1];
    }
    /* the normal faces the camera (the camera is at the origin) */
    if (out->normal[0] * t[0] + out->normal[1] * t[1] + out->normal[2] * t[2] > 0) {
        for (int j = 0; j < 3; j++) out->normal[j] = -out->normal[j];
    }
    out->distance = sqrtf(t[0] * t[0] + t[1] * t[1] + t[2] * t[2]);
    out->rms_px = rms;
    out->n_tags = ntags;
    out->format = format;
    return 1;
}
