package com.fusionapps.fe_ar

import android.media.Image
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.TrackingState
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * `depthPointAt {x, y}` (CHANNEL.md extension): the measured surface point
 * under a screen point, for Dart's wall-taps corner (`wall_fit.dart`) and
 * the long-baseline heading tap. Plain painted walls give ARCore no vertical
 * plane (first device run, OnePlus 7 Pro), but the Depth API still measures
 * them, and Raw Depth says per pixel how far to trust it.
 *
 * Tried in order:
 * 1. **rawDepth**: `acquireRawDepthImage16Bits` + `acquireRawDepthConfidenceImage`
 *    in a small window around the point; only pixels at or above
 *    [MIN_CONFIDENCE], then only those near their median depth. The point is
 *    the ray through the exact pixel at that median depth; the normal is the
 *    kept pixels' plane (smallest principal axis) when the patch is flat.
 * 2. **plane**: a tracked ARCore plane under the point (confidence 0.9).
 * 3. **depth**: the smoothed depth image, same window (no per-pixel
 *    confidence, so at most 0.5).
 *
 * Raw Depth is available whenever depth is on (`DepthMode.AUTOMATIC`, which
 * FeArController asks for when the device supports it); the smoothed image
 * too. Nothing here decides anything: Dart gates on `confidence`.
 */
internal class DepthProbe {
    var depthEnabled = false

    fun pointAt(frame: Frame, xPx: Float, yPx: Float): Map<String, Any?>? {
        val cam = frame.camera
        if (cam.trackingState != TrackingState.TRACKING) return null
        val camPos = cam.pose.translation
        if (depthEnabled) rawDepth(frame, xPx, yPx, camPos)?.let { return it }
        planeHit(frame, xPx, yPx, camPos)?.let { return it }
        if (depthEnabled) smoothDepth(frame, xPx, yPx, camPos)?.let { return it }
        return null
    }

    private fun rawDepth(frame: Frame, xPx: Float, yPx: Float, camPos: FloatArray): Map<String, Any?>? {
        val depth = try {
            frame.acquireRawDepthImage16Bits()
        } catch (e: Exception) {
            return null
        }
        try {
            val conf = try {
                frame.acquireRawDepthConfidenceImage()
            } catch (e: Exception) {
                return null
            }
            try {
                return sample(frame, depth, conf, xPx, yPx, camPos, "rawDepth")
            } finally {
                conf.close()
            }
        } finally {
            depth.close()
        }
    }

    private fun smoothDepth(frame: Frame, xPx: Float, yPx: Float, camPos: FloatArray): Map<String, Any?>? {
        val depth = try {
            frame.acquireDepthImage16Bits()
        } catch (e: Exception) {
            return null
        }
        try {
            return sample(frame, depth, null, xPx, yPx, camPos, "depth")
        } finally {
            depth.close()
        }
    }

    private fun planeHit(frame: Frame, xPx: Float, yPx: Float, camPos: FloatArray): Map<String, Any?>? {
        val hits = try {
            frame.hitTest(xPx, yPx)
        } catch (e: Exception) {
            return null
        }
        for (h in hits) {
            val t = h.trackable as? Plane ?: continue
            if (t.trackingState != TrackingState.TRACKING || t.subsumedBy != null || !t.isPoseInPolygon(h.hitPose)) continue
            val pos = h.hitPose.translation
            val n = facing(t.centerPose.yAxis, pos, camPos)
            return result(pos, n, 0.9f, "plane", 0, camPos)
        }
        return null
    }

    /**
     * Samples a depth image around the view point. The pixel mapping and the
     * back-projection are the ARCore RawDepth sample's (and CornerDetector's):
     * VIEW → TEXTURE_NORMALIZED, texture intrinsics scaled to the depth image,
     * camera (sensor) pose. TODO(slice-0): confirm the alignment on device
     * (README checklist item 4), as for CornerDetector.
     */
    private fun sample(
        frame: Frame,
        depth: Image,
        conf: Image?,
        xPx: Float,
        yPx: Float,
        camPos: FloatArray,
        method: String,
    ): Map<String, Any?>? {
        val w = depth.width
        val h = depth.height
        val dPlane = depth.planes[0]
        val dBuf = dPlane.buffer.order(ByteOrder.LITTLE_ENDIAN)
        val dRow = dPlane.rowStride
        val dPix = dPlane.pixelStride
        val cPlane = conf?.planes?.get(0)
        val cBuf = cPlane?.buffer
        val cRow = cPlane?.rowStride ?: 0
        val cPix = cPlane?.pixelStride ?: 1

        val uv = FloatArray(2)
        frame.transformCoordinates2d(Coordinates2d.VIEW, floatArrayOf(xPx, yPx), Coordinates2d.TEXTURE_NORMALIZED, uv)
        val uf = uv[0] * w
        val vf = uv[1] * h
        val u0 = uf.toInt()
        val v0 = vf.toInt()
        if (u0 < 0 || v0 < 0 || u0 >= w || v0 >= h) return null

        val intr = frame.camera.textureIntrinsics
        val dims = intr.imageDimensions
        val fx = intr.focalLength[0] * w / dims[0]
        val fy = intr.focalLength[1] * h / dims[1]
        val cx = intr.principalPoint[0] * w / dims[0]
        val cy = intr.principalPoint[1] * h / dims[1]
        val pose = frame.camera.pose

        // Window pixels: (u, v, depth mm, confidence 0–255).
        val us = IntArray(WINDOW_PIXELS)
        val vs = IntArray(WINDOW_PIXELS)
        val mms = IntArray(WINDOW_PIXELS)
        val cs = IntArray(WINDOW_PIXELS)
        var n = 0
        var total = 0
        for (v in max(0, v0 - WINDOW_RADIUS)..min(h - 1, v0 + WINDOW_RADIUS)) {
            for (u in max(0, u0 - WINDOW_RADIUS)..min(w - 1, u0 + WINDOW_RADIUS)) {
                total++
                val mm = dBuf.getShort(v * dRow + u * dPix).toInt() and 0xffff
                if (mm !in 1..MAX_DEPTH_MM) continue
                val c = if (cBuf != null) cBuf.get(v * cRow + u * cPix).toInt() and 0xff else 255
                if (cBuf != null && c < MIN_CONFIDENCE) continue
                us[n] = u
                vs[n] = v
                mms[n] = mm
                cs[n] = c
                n++
            }
        }
        if (n < MIN_SAMPLES || total == 0) return null

        val sorted = mms.copyOf(n).also { it.sort() }
        val median = sorted[n / 2]
        val band = max(BAND_MIN_MM, (median * BAND_FRACTION).toInt())
        val pts = FloatArray(3 * n)
        var kept = 0
        var confSum = 0
        for (i in 0 until n) {
            if (abs(mms[i] - median) > band) continue
            val z = mms[i] / 1000f
            val p = pose.transformPoint(floatArrayOf((us[i] - cx) / fx * z, -(vs[i] - cy) / fy * z, -z))
            pts[kept * 3] = p[0]
            pts[kept * 3 + 1] = p[1]
            pts[kept * 3 + 2] = p[2]
            confSum += cs[i]
            kept++
        }
        if (kept < MIN_SAMPLES) return null

        val zm = median / 1000f
        val pos = pose.transformPoint(floatArrayOf((uf - cx) / fx * zm, -(vf - cy) / fy * zm, -zm))
        val normal = planeNormal(pts, kept)?.let { facing(it, pos, camPos) }
        val coverage = kept.toFloat() / total
        val confidence = if (conf != null) coverage * (confSum.toFloat() / kept / 255f) else coverage * 0.5f
        return result(pos, normal, confidence.coerceIn(0f, 1f), method, kept, camPos)
    }

    private fun result(pos: FloatArray, normal: FloatArray?, confidence: Float, method: String, samples: Int, camPos: FloatArray): Map<String, Any?> = mapOf(
        "posAr" to ArMath.toDoubleList(pos),
        "normalAr" to normal?.let { ArMath.toDoubleList(it) },
        "confidence" to confidence.toDouble(),
        "method" to method,
        // extras (Dart ignores them)
        "samples" to samples,
        "distanceM" to ArMath.distance(pos, camPos).toDouble(),
    )

    /** Flips [n] to face the camera. */
    private fun facing(n: FloatArray, at: FloatArray, camPos: FloatArray): FloatArray {
        val u = ArMath.normalize(n)
        return if (ArMath.dot(u, ArMath.sub(camPos, at)) < 0f) ArMath.scale(u, -1f) else u
    }

    /**
     * The normal of the best plane through the points (smallest principal
     * axis of their scatter, Jacobi on the 3×3 covariance), or null when the
     * patch isn't flat (the smallest spread is not clearly below the middle
     * one: an edge, a corner, noise).
     */
    private fun planeNormal(pts: FloatArray, n: Int): FloatArray? {
        if (n < MIN_NORMAL_SAMPLES) return null
        var mx = 0.0
        var my = 0.0
        var mz = 0.0
        for (i in 0 until n) {
            mx += pts[i * 3]
            my += pts[i * 3 + 1]
            mz += pts[i * 3 + 2]
        }
        mx /= n
        my /= n
        mz /= n
        val a = Array(3) { DoubleArray(3) }
        for (i in 0 until n) {
            val d = doubleArrayOf(pts[i * 3] - mx, pts[i * 3 + 1] - my, pts[i * 3 + 2] - mz)
            for (r in 0 until 3) for (c in 0 until 3) a[r][c] += d[r] * d[c]
        }
        val vecs = arrayOf(doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, 1.0, 0.0), doubleArrayOf(0.0, 0.0, 1.0))
        jacobi(a, vecs)
        val order = (0 until 3).sortedBy { a[it][it] }
        val l0 = a[order[0]][order[0]]
        val l1 = a[order[1]][order[1]]
        if (l1 <= 1e-12 || l0 / l1 > FLATNESS_MAX) return null
        val k = order[0]
        // Eigenvectors are the columns of vecs.
        val nx = vecs[0][k]
        val ny = vecs[1][k]
        val nz = vecs[2][k]
        val len = sqrt(nx * nx + ny * ny + nz * nz)
        if (len < 1e-9) return null
        return floatArrayOf((nx / len).toFloat(), (ny / len).toFloat(), (nz / len).toFloat())
    }

    /** Cyclic Jacobi for a symmetric 3×3: [a] becomes diagonal, [v] collects the eigenvectors (columns). */
    private fun jacobi(a: Array<DoubleArray>, v: Array<DoubleArray>) {
        repeat(24) {
            var off = 0.0
            for (p in 0 until 3) for (q in p + 1 until 3) off += a[p][q] * a[p][q]
            if (off < 1e-18) return
            for (p in 0 until 3) {
                for (q in p + 1 until 3) {
                    if (abs(a[p][q]) < 1e-15) continue
                    val theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    val t = (if (theta >= 0) 1.0 else -1.0) / (abs(theta) + sqrt(theta * theta + 1))
                    val c = 1 / sqrt(t * t + 1)
                    val s = t * c
                    for (k in 0 until 3) {
                        val akp = a[k][p]
                        val akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for (k in 0 until 3) {
                        val apk = a[p][k]
                        val aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for (k in 0 until 3) {
                        val vkp = v[k][p]
                        val vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
    }

    companion object {
        /** 9×9 depth pixels: about 8 cm at 1.5 m on a 160-px-wide depth image. */
        private const val WINDOW_RADIUS = 4
        private const val WINDOW_PIXELS = (2 * WINDOW_RADIUS + 1) * (2 * WINDOW_RADIUS + 1)

        /** Raw Depth confidence 0–255; ARCore's own samples keep ≥ ~50%. */
        private const val MIN_CONFIDENCE = 128
        private const val MIN_SAMPLES = 8
        private const val MIN_NORMAL_SAMPLES = 12
        private const val MAX_DEPTH_MM = 6000

        /** Pixels further than this from the window's median depth are another surface. */
        private const val BAND_MIN_MM = 30
        private const val BAND_FRACTION = 0.03f

        /** Smallest / middle principal spread above this: not a flat patch. */
        private const val FLATNESS_MAX = 0.25
    }
}
