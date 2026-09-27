package com.fusionapps.fe_ar

import android.os.SystemClock
import com.google.ar.core.Coordinates2d
import com.google.ar.core.DepthPoint
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Point
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Corner snapping under a screen point (docs/ar-setup-and-gamma-parity.md
 * §2.3), Android. Tried in order:
 *
 * 1. Depth API point cloud around the pin: two vertical planes fitted by the
 *    C core (RANSAC + least squares) and intersected. Works when the base
 *    of the corner is hidden. Reported as method "planes" (CONTRACT C2 has
 *    no Android-depth sigma; fitted planes are what this is).
 * 2. Two tracked ARCore vertical planes whose intersection falls within
 *    0.6 m of the pin: method "planes".
 * 3. Floor tap: the pin is on the floor at the corner; the heading comes from
 *    the one wall plane found nearby: method "floorTap" (largest sigma).
 *
 * Height is never measured from the corner: y is the floor plane's height
 * (the floor finish offset is applied by Dart, CONTRACT C4).
 *
 * When nothing is found, a coaching hint goes out as an `error` event
 * (`corner-no-floor`, `corner-no-walls`, ...), throttled, so the UI can say
 * "Sweep slowly across both walls" or "Point at the floor for a moment".
 */
internal class CornerDetector(private val emit: (Map<String, Any?>) -> Unit) {
    var depthEnabled = false
    private val lastHint = HashMap<String, Long>()

    fun detect(session: Session, frame: Frame, xPx: Float, yPx: Float): Map<String, Any?>? {
        val cam = frame.camera
        if (cam.trackingState != TrackingState.TRACKING) {
            hint("corner-not-tracking", "tracking is not ready")
            return null
        }
        val camPos = cam.pose.translation
        val floorY = findFloor(session, camPos[1])

        val hits = try {
            frame.hitTest(xPx, yPx)
        } catch (e: Exception) {
            emptyList()
        }
        var aim: FloatArray? = null
        var aimPlane: Plane? = null
        var aimOnFloor = false
        for (h in hits) {
            val t = h.trackable
            val usable = when (t) {
                is Plane -> t.trackingState == TrackingState.TRACKING && t.isPoseInPolygon(h.hitPose)
                is DepthPoint, is Point -> true
                else -> false
            }
            if (!usable) continue
            if (aim == null) {
                aim = h.hitPose.translation
                aimOnFloor = t is Plane && t.type == Plane.Type.HORIZONTAL_UPWARD_FACING
            }
            if (t is Plane && t.type == Plane.Type.VERTICAL && aimPlane == null) aimPlane = t
        }
        if (aim == null) {
            hint("corner-no-surface", "nothing measured under the pin yet: sweep slowly across both walls")
            return null
        }
        if (floorY == null) {
            hint("corner-no-floor", "no floor yet: point at the floor for a moment")
            return null
        }

        if (depthEnabled) depthCorner(frame, xPx, yPx, aim, camPos, floorY)?.let { return it }
        planesCorner(session, aim, aimPlane, camPos, floorY)?.let { return it }
        if (aimOnFloor) floorTap(session, aim, camPos, floorY)?.let { return it }

        val verticals = verticalPlanes(session).size
        // Fewer than two tracked walls, and depth (tried first above) found
        // no corner either: plain painted walls. Dart offers wall taps
        // (depthPointAt + wall_fit.dart) on this code. It used to go out only
        // without depth, so the OnePlus 7 Pro (depth, plain walls) only ever
        // heard "corner-not-found".
        if (verticals < 2) {
            hint("corner-no-walls", "found $verticals wall(s): tap each wall near the corner instead")
        } else {
            hint("corner-not-found", "no corner under the pin")
        }
        return null
    }

    // --------------------------------------------------------------- depth

    private fun depthCorner(frame: Frame, xPx: Float, yPx: Float, aim: FloatArray, camPos: FloatArray, floorY: Float): Map<String, Any?>? {
        val image = try {
            frame.acquireDepthImage16Bits()
        } catch (e: Exception) {
            return null
        }
        try {
            val w = image.width
            val h = image.height
            val plane = image.planes[0]
            val buf = plane.buffer.order(ByteOrder.LITTLE_ENDIAN)
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            // TODO(slice-0): confirm the depth image is aligned with TEXTURE_NORMALIZED
            // (the RawDepth sample pairs it with textureIntrinsics, as here).
            val uv = FloatArray(2)
            frame.transformCoordinates2d(Coordinates2d.VIEW, floatArrayOf(xPx, yPx), Coordinates2d.TEXTURE_NORMALIZED, uv)
            val u0 = (uv[0] * w).toInt()
            val v0 = (uv[1] * h).toInt()
            val intr = frame.camera.textureIntrinsics
            val dims = intr.imageDimensions
            val fx = intr.focalLength[0] * w / dims[0]
            val fy = intr.focalLength[1] * h / dims[1]
            val cx = intr.principalPoint[0] * w / dims[0]
            val cy = intr.principalPoint[1] * h / dims[1]
            val pose = frame.camera.pose
            val half = max(w, h) / 5
            val step = max(1, (2 * half) / 70)
            val pts = FloatArray(3 * ((2 * half / step + 1) * (2 * half / step + 1)))
            var n = 0
            var v = max(0, v0 - half)
            while (v <= min(h - 1, v0 + half)) {
                var u = max(0, u0 - half)
                while (u <= min(w - 1, u0 + half)) {
                    val mm = buf.getShort(v * rowStride + u * pixelStride).toInt() and 0xffff
                    if (mm in 1..6000) {
                        val z = mm / 1000f
                        val p = pose.transformPoint(floatArrayOf((u - cx) / fx * z, -(v - cy) / fy * z, -z))
                        pts[n * 3] = p[0]
                        pts[n * 3 + 1] = p[1]
                        pts[n * 3 + 2] = p[2]
                        n++
                    }
                    u += step
                }
                v += step
            }
            if (n < 60) return null
            val out = FloatArray(12)
            if (!FeArCore.nativeCornerFromPoints(pts, n, aim, camPos, floorY, true, 0.03f, out)) return null
            return event(out, "planes")
        } finally {
            image.close()
        }
    }

    // -------------------------------------------------------------- planes

    private fun verticalPlanes(session: Session): List<Plane> =
        session.getAllTrackables(Plane::class.java).filter {
            it.trackingState == TrackingState.TRACKING && it.type == Plane.Type.VERTICAL && it.subsumedBy == null
        }

    private fun planesCorner(session: Session, aim: FloatArray, aimPlane: Plane?, camPos: FloatArray, floorY: Float): Map<String, Any?>? {
        val walls = verticalPlanes(session)
        if (walls.size < 2) return null
        // Try the wall under the pin first, then any wall whose line passes near the pin.
        val firsts = (listOfNotNull(aimPlane) + walls.filter { it != aimPlane && lineDistance(it, aim) < 0.8f }).distinct()
        var best: FloatArray? = null
        var bestDist = Float.MAX_VALUE
        val out = FloatArray(12)
        for (a in firsts) {
            for (b in walls) {
                if (a == b) continue
                val ok = FeArCore.nativeCornerFromPlanes(
                    a.centerPose.translation, a.centerPose.yAxis, halfExtent(a),
                    b.centerPose.translation, b.centerPose.yAxis, halfExtent(b),
                    aim, camPos, floorY, true, out,
                )
                if (!ok) continue
                val d = kotlin.math.hypot(out[0] - aim[0], out[2] - aim[2])
                if (d < bestDist) {
                    bestDist = d
                    best = out.copyOf()
                }
            }
        }
        return best?.let { event(it, "planes") }
    }

    /** Horizontal distance from a point to the plane's infinite wall line. */
    private fun lineDistance(p: Plane, x: FloatArray): Float {
        val c = p.centerPose.translation
        val n = p.centerPose.yAxis
        val l = kotlin.math.hypot(n[0], n[2])
        if (l < 1e-6f) return Float.MAX_VALUE
        return abs(((x[0] - c[0]) * n[0] + (x[2] - c[2]) * n[2]) / l)
    }

    /** Half the plane's horizontal extent, from its polygon. */
    private fun halfExtent(p: Plane): Float {
        val pose = p.centerPose
        val n = pose.yAxis
        val ux = -n[2]
        val uz = n[0]
        val ul = kotlin.math.hypot(ux, uz)
        if (ul < 1e-6f) return max(p.extentX, p.extentZ) / 2f
        val poly = p.polygon
        val c = pose.translation
        var m = 0f
        poly.rewind()
        while (poly.remaining() >= 2) {
            val lx = poly.get()
            val lz = poly.get()
            val w = pose.transformPoint(floatArrayOf(lx, 0f, lz))
            m = max(m, abs(((w[0] - c[0]) * ux + (w[2] - c[2]) * uz) / ul))
        }
        return if (m > 0f) m else max(p.extentX, p.extentZ) / 2f
    }

    // ----------------------------------------------------------- floor tap

    private fun floorTap(session: Session, aim: FloatArray, camPos: FloatArray, floorY: Float): Map<String, Any?>? {
        val wall = verticalPlanes(session).filter { lineDistance(it, aim) < 0.3f }.minByOrNull { lineDistance(it, aim) } ?: return null
        val n = wall.centerPose.yAxis
        var ax = n[0]
        var az = n[2]
        val l = kotlin.math.hypot(ax, az)
        if (l < 1e-6f) return null
        ax /= l
        az /= l
        val tx = camPos[0] - aim[0]
        val tz = camPos[2] - aim[2]
        if (ax * tx + az * tz < 0) {
            ax = -ax
            az = -az
        }
        // The second face is 90 degrees round, on the camera's side.
        val r1x = -az
        val r1z = ax
        val (bx, bz) = if (r1x * tx + r1z * tz >= 0) r1x to r1z else -r1x to -r1z
        // Order so cross(faceA, faceB) >= 0, as the C core does.
        val swap = ax * bz - az * bx < 0
        val fa = if (swap) floatArrayOf(bx, bz) else floatArrayOf(ax, az)
        val fb = if (swap) floatArrayOf(ax, az) else floatArrayOf(bx, bz)
        return mapOf(
            "type" to "corner",
            "posAr" to listOf(aim[0].toDouble(), floorY.toDouble(), aim[2].toDouble()),
            "faceAAr" to listOf(fa[0].toDouble(), fa[1].toDouble()),
            "faceBAr" to listOf(fb[0].toDouble(), fb[1].toDouble()),
            "angleDeg" to 90.0,
            "kind" to "inside",
            "method" to "floorTap",
        )
    }

    // ----------------------------------------------------------------- floor

    /** The floor: the lowest tracked upward plane at least 0.5 m below the camera. */
    fun findFloor(session: Session, cameraY: Float): Float? =
        session.getAllTrackables(Plane::class.java)
            .filter {
                it.trackingState == TrackingState.TRACKING && it.type == Plane.Type.HORIZONTAL_UPWARD_FACING &&
                    it.subsumedBy == null && it.centerPose.ty() < cameraY - 0.5f && it.extentX * it.extentZ > 0.2f
            }
            .minByOrNull { it.centerPose.ty() }
            ?.centerPose?.ty()

    private fun event(out: FloatArray, method: String): Map<String, Any?> = mapOf(
        "type" to "corner",
        "posAr" to listOf(out[0].toDouble(), out[1].toDouble(), out[2].toDouble()),
        "faceAAr" to listOf(out[3].toDouble(), out[4].toDouble()),
        "faceBAr" to listOf(out[5].toDouble(), out[6].toDouble()),
        "angleDeg" to out[7].toDouble(),
        "kind" to when (out[8].toInt()) {
            FeArCore.CORNER_OUTSIDE -> "outside"
            FeArCore.CORNER_COLUMN -> "column"
            else -> "inside"
        },
        "method" to method,
        // extras (not in CornerSeenEvent; Dart ignores them)
        "spanA" to out[9].toDouble(),
        "spanB" to out[10].toDouble(),
        "rmsM" to out[11].toDouble(),
    )

    private fun hint(code: String, detail: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - (lastHint[code] ?: 0L) < 1500) return
        lastHint[code] = now
        emit(mapOf("type" to "error", "code" to code, "detail" to detail))
    }
}
