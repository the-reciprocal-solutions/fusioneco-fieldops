package com.fusionapps.fe_ar

import android.media.Image
import android.os.SystemClock
import com.google.ar.core.Anchor
import com.google.ar.core.DepthPoint
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.UUID
import kotlin.math.acos
import kotlin.math.sqrt

/**
 * Marker observations (docs/ar-bim-overlay.md §4.2), Android.
 *
 * 1. ML Kit reads QR codes from ARCore's CPU camera image: about 5 Hz while
 *    idle (battery), then as fast as ML Kit returns (one frame in flight)
 *    once a code is being locked, so ~15 samples take about a second.
 * 2. Each sample casts a ray through the QR centre FROM THE CAMERA POSE OF
 *    THE FRAME THE CODE WAS READ IN (the result arrives a frame or two
 *    later) and hit-tests it: a tracked vertical plane ("plane"), then a
 *    Depth API point ("depth"), then the square's own pose from its four
 *    corners ("pnp", flagged; Dart doubles its sigma, CONTRACT C2).
 * 3. Gates: tracking, 0.5-2.0 m (3.0 m for an A3 board), within 35 degrees of
 *    square-on. A gated sample is dropped, never averaged in.
 * 4. After 15 samples: per-axis median centre, normalised mean normal, RMS
 *    spread. Spread over 15 mm: "hold still" (error event
 *    `marker-unstable`), and the older half of the samples is dropped. Else a
 *    native anchor is created at the median and ONE `marker` event is sent;
 *    the payload then cools down for 4 s.
 *
 * Every QR payload is reported raw; Dart decides what is a marker
 * (MarkerCode.fromScan), so asset tags scanned in AR get anchored too.
 */
internal class MarkerDetector(private val emit: (Map<String, Any?>) -> Unit) {
    private class Snapshot(
        val cameraPose: Pose,
        val fx: Float,
        val fy: Float,
        val cx: Float,
        val cy: Float,
    )

    private class Detection(val payload: String, val corners: FloatArray, val snapshot: Snapshot)

    private class Sample(
        val atMs: Long,
        val centre: FloatArray,
        val normal: FloatArray,
        val method: String,
        val distance: Float,
        val viewAngle: Float,
        val qrEdgeMm: Float?,
    )

    private class Tracked(val anchor: Anchor, var lastReported: FloatArray, var lastMs: Long)

    private val scanner: BarcodeScanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build(),
    )
    private var inFlight = false
    private var lastRunMs = 0L
    private val pending = ArrayList<Detection>()
    private val samples = HashMap<String, ArrayList<Sample>>()
    private val cooldownUntil = HashMap<String, Long>()
    private val anchors = HashMap<String, Tracked>()
    private var lastAnchorCheckMs = 0L

    /** Also emit `markerProgress` events (startSession option; Dart may ignore them). */
    var progressEvents = false

    fun onFrame(session: Session, frame: Frame, tracking: Boolean) {
        val now = SystemClock.elapsedRealtime()
        if (tracking && pending.isNotEmpty()) {
            val batch = ArrayList(pending)
            pending.clear()
            for (d in batch) process(session, frame, d, now)
        }
        expire(now)
        if (tracking) schedule(frame, now)
        updateAnchors(now)
    }

    private fun schedule(frame: Frame, now: Long) {
        val locking = samples.values.any { it.isNotEmpty() }
        val interval = if (locking) 0L else IDLE_INTERVAL_MS
        if (inFlight || now - lastRunMs < interval) return
        val image: Image = try {
            frame.acquireCameraImage()
        } catch (e: Exception) {
            return // NotYetAvailable / ResourceExhausted: try next frame
        }
        val cam = frame.camera
        val intr = cam.imageIntrinsics
        val focal = intr.focalLength
        val principal = intr.principalPoint
        val snapshot = Snapshot(cam.pose, focal[0], focal[1], principal[0], principal[1])
        lastRunMs = now
        inFlight = true
        // Rotation 0: corner points stay in sensor-image pixels, which is what
        // the intrinsics describe. QR decoding doesn't care about rotation.
        // TODO(slice-0): confirm ML Kit's cornerPoints are in the unrotated
        // image's pixels when rotationDegrees is 0 (they should be).
        val input = try {
            InputImage.fromMediaImage(image, 0)
        } catch (e: Exception) {
            image.close()
            inFlight = false
            return
        }
        scanner.process(input)
            .addOnSuccessListener { codes ->
                for (code in codes) {
                    val raw = code.rawValue ?: continue
                    val pts = code.cornerPoints ?: continue
                    if (pts.size != 4) continue
                    val corners = FloatArray(8)
                    for (i in 0 until 4) {
                        corners[i * 2] = pts[i].x.toFloat()
                        corners[i * 2 + 1] = pts[i].y.toFloat()
                    }
                    pending += Detection(raw, corners, snapshot)
                }
            }
            .addOnCompleteListener {
                image.close()
                inFlight = false
            }
    }

    private fun process(session: Session, frame: Frame, d: Detection, now: Long) {
        if ((cooldownUntil[d.payload] ?: 0L) > now) return
        val s = d.snapshot
        val c = d.corners
        // centre = intersection of the diagonals (0-2, 1-3)
        val centrePx = diagonalCentre(c) ?: return
        val dirCam = floatArrayOf((centrePx[0] - s.cx) / s.fx, -(centrePx[1] - s.cy) / s.fy, -1f)
        val origin = s.cameraPose.translation
        val dirWorld = ArMath.normalize(s.cameraPose.rotateVector(dirCam))

        var centre: FloatArray? = null
        var normal: FloatArray? = null
        var method = "pnp"
        var depthPlane = false
        val hits = try {
            frame.hitTest(origin, 0, dirWorld, 0)
        } catch (e: Exception) {
            emptyList()
        }
        // 1) a tracked vertical plane
        for (h in hits) {
            val t = h.trackable
            if (t is Plane && t.type == Plane.Type.VERTICAL && t.trackingState == TrackingState.TRACKING && t.isPoseInPolygon(h.hitPose)) {
                centre = h.hitPose.translation
                normal = t.centerPose.yAxis
                method = "plane"
                break
            }
        }
        // 2) a Depth API point (its pose's +Y is the surface normal)
        if (centre == null) {
            for (h in hits) {
                if (h.trackable is DepthPoint) {
                    centre = h.hitPose.translation
                    normal = h.hitPose.yAxis
                    method = "depth"
                    depthPlane = true
                    break
                }
            }
        }
        // 3) the square's own pose (assumes the A4 board's 115 mm QR)
        if (centre == null) {
            val out = FloatArray(7)
            if (!FeArCore.nativeSquarePose(c, s.fx, s.fy, s.cx, s.cy, QR_EDGE_A4_M, out)) return
            centre = s.cameraPose.transformPoint(floatArrayOf(out[0], out[1], out[2]))
            normal = s.cameraPose.rotateVector(floatArrayOf(out[3], out[4], out[5]))
            method = "pnp"
        }
        var n = ArMath.normalize(normal!!)
        val toCam = ArMath.sub(origin, centre)
        if (ArMath.dot(n, toCam) < 0) n = ArMath.scale(n, -1f)
        val distance = ArMath.length(toCam)
        val viewAngle = Math.toDegrees(acos(ArMath.clamp(ArMath.dot(n, ArMath.normalize(toCam)), -1f, 1f).toDouble())).toFloat()

        // Print-scale measurement: the QR's corners on the measured wall.
        // Only reported for a depth measurement (MarkerSeenEvent.qrEdgeMm).
        var qrEdgeMm: Float? = null
        if (depthPlane) {
            val inv = s.cameraPose.inverse()
            val pCam = inv.transformPoint(centre)
            val nCam = inv.rotateVector(n)
            val e = FeArCore.nativeSquareEdgeOnPlane(c, s.fx, s.fy, s.cx, s.cy, pCam, nCam)
            if (e > 0) qrEdgeMm = e * 1000f
        }

        val maxDistance = if ((qrEdgeMm ?: 0f) >= 150f) 3.0f else 2.0f
        val gate = when {
            distance < 0.5f -> "tooClose"
            distance > maxDistance -> "tooFar"
            viewAngle > 35f -> "angle"
            else -> null
        }
        val list = samples.getOrPut(d.payload) { ArrayList() }
        if (gate == null) {
            list += Sample(now, centre, n, method, distance, viewAngle, qrEdgeMm)
            if (list.size > 30) list.subList(0, list.size - 30).clear()
        }
        if (progressEvents) {
            emit(
                mapOf(
                    "type" to "markerProgress",
                    "rawPayload" to d.payload,
                    "samples" to list.size,
                    "needed" to SAMPLES_NEEDED,
                    "distanceM" to distance.toDouble(),
                    "viewAngleDeg" to viewAngle.toDouble(),
                    "gate" to (gate ?: "ok"),
                ),
            )
        }
        if (list.size >= SAMPLES_NEEDED) finish(session, d.payload, list, now)
    }

    private fun finish(session: Session, payload: String, list: ArrayList<Sample>, now: Long) {
        val centre = FloatArray(3) { k -> median(list.map { it.centre[k] }) }
        var nsum = floatArrayOf(0f, 0f, 0f)
        for (s in list) nsum = ArMath.add(nsum, s.normal)
        val normal = ArMath.normalize(nsum)
        var sq = 0f
        for (s in list) {
            val dd = ArMath.distance(s.centre, centre)
            sq += dd * dd
        }
        val spreadMm = sqrt(sq / list.size) * 1000f
        if (spreadMm > MAX_SPREAD_MM) {
            emit(mapOf("type" to "error", "code" to "marker-unstable", "detail" to "$payload spread ${"%.1f".format(spreadMm)} mm: hold still"))
            list.subList(0, list.size / 2).clear()
            return
        }
        val anchor = try {
            session.createAnchor(Pose.makeTranslation(centre[0], centre[1], centre[2]))
        } catch (e: Exception) {
            emit(mapOf("type" to "error", "code" to "anchor-failed", "detail" to (e.message ?: "")))
            return
        }
        val id = UUID.randomUUID().toString()
        anchors[id] = Tracked(anchor, centre, now)
        // The weakest method seen decides the label: one pnp sample in the
        // median makes the whole observation pnp-grade.
        val method = when {
            list.any { it.method == "pnp" } -> "pnp"
            list.any { it.method == "depth" } -> "depth"
            else -> "plane"
        }
        val edges = list.mapNotNull { it.qrEdgeMm }
        emit(
            mapOf(
                "type" to "marker",
                "rawPayload" to payload,
                "anchorId" to id,
                "centreAr" to ArMath.toDoubleList(centre),
                "normalAr" to ArMath.toDoubleList(normal),
                "method" to method,
                "spreadMm" to spreadMm.toDouble(),
                "distanceM" to median(list.map { it.distance }).toDouble(),
                "viewAngleDeg" to median(list.map { it.viewAngle }).toDouble(),
                "qrEdgeMm" to if (edges.size >= list.size / 2) median(edges).toDouble() else null,
            ),
        )
        list.clear()
        cooldownUntil[payload] = now + COOLDOWN_MS
    }

    private fun expire(now: Long) {
        val iter = samples.entries.iterator()
        while (iter.hasNext()) {
            val e = iter.next()
            e.value.removeAll { s -> now - s.atMs > SAMPLE_TTL_MS }
            if (e.value.isEmpty()) iter.remove()
        }
    }

    /** Anchor refinements, at most 2 Hz, only when an anchor moved over 1 mm. */
    private fun updateAnchors(now: Long) {
        if (now - lastAnchorCheckMs < 500) return
        lastAnchorCheckMs = now
        val iter = anchors.entries.iterator()
        while (iter.hasNext()) {
            val (id, t) = iter.next()
            when (t.anchor.trackingState) {
                TrackingState.STOPPED -> iter.remove()
                TrackingState.TRACKING -> {
                    val p = t.anchor.pose.translation
                    if (ArMath.distance(p, t.lastReported) > 0.001f) {
                        t.lastReported = p
                        t.lastMs = now
                        emit(mapOf("type" to "anchor", "anchorId" to id, "posAr" to ArMath.toDoubleList(p)))
                    }
                }
                else -> Unit
            }
        }
    }

    /**
     * A native anchor at [p] (a committed corner snap), refined and reported
     * like a board's: `anchor` events at most 2 Hz when it moves over 1 mm.
     */
    fun anchorAt(session: Session, p: FloatArray): String? {
        val anchor = try {
            session.createAnchor(Pose.makeTranslation(p[0], p[1], p[2]))
        } catch (e: Exception) {
            emit(mapOf("type" to "error", "code" to "anchor-failed", "detail" to (e.message ?: "")))
            return null
        }
        val id = UUID.randomUUID().toString()
        anchors[id] = Tracked(anchor, p.copyOf(), SystemClock.elapsedRealtime())
        return id
    }

    /** Forget everything (session stopped or restarted). */
    fun reset() {
        for (t in anchors.values) runCatching { t.anchor.detach() }
        anchors.clear()
        samples.clear()
        pending.clear()
        cooldownUntil.clear()
    }

    fun close() {
        reset()
        scanner.close()
    }

    private fun median(v: List<Float>): Float {
        if (v.isEmpty()) return 0f
        val s = v.sorted()
        val m = s.size / 2
        return if (s.size % 2 == 1) s[m] else (s[m - 1] + s[m]) / 2f
    }

    private fun diagonalCentre(c: FloatArray): FloatArray? {
        // p0 + t (p2 - p0) = p1 + u (p3 - p1)
        val x1 = c[0]
        val y1 = c[1]
        val x2 = c[4]
        val y2 = c[5]
        val x3 = c[2]
        val y3 = c[3]
        val x4 = c[6]
        val y4 = c[7]
        val den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if (kotlin.math.abs(den) < 1e-6f) return null
        val t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        return floatArrayOf(x1 + t * (x2 - x1), y1 + t * (y2 - y1))
    }

    companion object {
        const val SAMPLES_NEEDED = 15
        const val MAX_SPREAD_MM = 15f
        const val IDLE_INTERVAL_MS = 200L
        const val SAMPLE_TTL_MS = 2500L
        const val COOLDOWN_MS = 4000L
        const val QR_EDGE_A4_M = 0.115f
    }
}
