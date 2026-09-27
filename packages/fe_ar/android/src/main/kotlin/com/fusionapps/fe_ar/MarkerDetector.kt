package com.fusionapps.fe_ar

import android.media.Image
import android.os.Handler
import android.os.Looper
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
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Marker observations (docs/ar-bim-overlay.md §4.2), Android.
 *
 * 1. ML Kit reads QR codes from ARCore's CPU camera image: about 5 Hz while
 *    idle (battery), then as fast as ML Kit returns (one frame in flight)
 *    once a code is being locked, so ~15 samples take about a second.
 * 2. TAG (boards printed from 2026-09-27, fe_tag.h): the same image's Y
 *    plane is searched for the board's four AprilTag tag36h11 fiducials in a
 *    region around the QR. A tag counts only if its id is in that payload's
 *    group AND it sits at one of the QR frame's corners in the image (group
 *    ids can collide between boards; position can't). With at least
 *    [MIN_TAGS] tags, a planar PnP over their corners (C core) gives the
 *    board pose in camera space, moved to world space by the camera pose of
 *    the frame the image came from. Method "tag".
 * 3. Otherwise (a QR-only board, tags too small or blurred) each sample casts
 *    a ray through the QR centre FROM THE CAMERA POSE OF THE FRAME THE CODE
 *    WAS READ IN (the result arrives a frame or two later) and hit-tests it:
 *    a tracked vertical plane ("plane"), then a Depth API point ("depth"),
 *    then the square's own pose from its four corners ("pnp", flagged; Dart
 *    doubles its sigma, CONTRACT C2).
 * 4. Gates: tracking, 0.5-2.0 m (3.0 m for an A3 board; tags from 0.3 m),
 *    within 35 degrees of square-on (40 for tags). A gated sample is
 *    dropped, never averaged in.
 * 5. Tag and QR samples are kept apart. After [TAG_SAMPLES_NEEDED] tag
 *    samples (window of [TAG_SAMPLES_MAX]) or [SAMPLES_NEEDED] QR samples:
 *    per-axis median centre, normalised mean normal, RMS spread. Spread over
 *    [MAX_TAG_SPREAD_MM] / [MAX_SPREAD_MM]: "hold still" (error event
 *    `marker-unstable`), and the older half of those samples is dropped. Else
 *    a native anchor is created at the median and ONE `marker` event is sent;
 *    the payload then cools down for 4 s.
 * 6. Print scale: a tag pose trusts the printed tag size. When ARCore also
 *    measures the wall along the tag-centre ray (plane or depth hit), their
 *    distance ratio is the print scale (reported as `qrEdgeMm` for a depth
 *    hit, the QR path's rule). A board whose
 *    median scale is off by more than [TAG_SCALE_TOLERANCE] (printed at 94%,
 *    say) stops using its tags for the session and locks by the QR path.
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

    /** Board pose from its tags, camera space (+X right, +Y up, -Z forward). */
    private class TagPose(
        val centre: FloatArray,
        val normal: FloatArray,
        val rmsPx: Float,
        val tags: Int,
        val a3: Boolean,
    )

    private class Detection(
        val payload: String,
        val corners: FloatArray,
        val snapshot: Snapshot,
        val tag: TagPose?,
        val generation: Int,
    )

    private class Sample(
        val atMs: Long,
        val centre: FloatArray,
        val normal: FloatArray,
        val method: String,
        val distance: Float,
        val viewAngle: Float,
        val qrEdgeMm: Float?,
        /** Tag samples: ARCore's metric over the tag's (print scale), when measured. */
        val scale: Float? = null,
    )

    private class Tracked(val anchor: Anchor, var lastReported: FloatArray, var lastMs: Long)

    private val scanner: BarcodeScanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build(),
    )
    private val main = Handler(Looper.getMainLooper())

    // The tag detector lives on its own thread: AprilTag isn't re-entrant and
    // must stay off the main (frame) thread. ML Kit's completion runs there too.
    private val tagPool: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "fe_ar-tags").apply { isDaemon = true } }
    private val tagExec = Executor { r ->
        try {
            tagPool.execute(r)
        } catch (e: RejectedExecutionException) {
            r.run() // closed: the handle is 0, so this only releases the image
        }
    }
    private var tagDetector = 0L // tag thread only
    private val tagGroups = HashMap<String, Int>() // tag thread only
    private val tagOut = FloatArray(MAX_DETECTIONS * TAG_STRIDE) // tag thread only

    private var inFlight = false
    private var lastRunMs = 0L
    private var generation = 0
    private val pending = ArrayList<Detection>()
    private val samples = HashMap<String, ArrayList<Sample>>()
    private val tagSamples = HashMap<String, ArrayList<Sample>>()
    private val tagDistrusted = HashSet<String>()
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
            for (d in batch) if (d.generation == generation) process(session, frame, d, now)
        }
        expire(now)
        if (tracking) schedule(frame, now)
        updateAnchors(now)
    }

    private fun schedule(frame: Frame, now: Long) {
        val locking = samples.values.any { it.isNotEmpty() } || tagSamples.values.any { it.isNotEmpty() }
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
        val gen = generation
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
        // Completion on the tag thread: the tags are searched in the SAME
        // image while it is still open, then it is closed and the results go
        // back to the main thread.
        scanner.process(input).addOnCompleteListener(tagExec) { task ->
            val found = ArrayList<Detection>()
            try {
                val codes = if (task.isSuccessful) task.result else null
                if (codes != null) {
                    for (code in codes) {
                        val raw = code.rawValue ?: continue
                        val pts = code.cornerPoints ?: continue
                        if (pts.size != 4) continue
                        val corners = FloatArray(8)
                        for (i in 0 until 4) {
                            corners[i * 2] = pts[i].x.toFloat()
                            corners[i * 2 + 1] = pts[i].y.toFloat()
                        }
                        val tag = try {
                            tagPose(raw, corners, image, snapshot)
                        } catch (e: Exception) {
                            null // a bad plane layout or a closed session: QR path
                        }
                        found += Detection(raw, corners, snapshot, tag, gen)
                    }
                }
            } finally {
                image.close()
                main.post {
                    inFlight = false
                    if (gen == generation) pending += found
                }
            }
        }
    }

    // ---------------------------------------------------------------- tags (tag thread)

    /**
     * The board pose from its AprilTags in [image] (Y plane), or null: not a
     * marker payload, fewer than [MIN_TAGS] of its tags where its frame
     * corners are, or a poor fit.
     */
    private fun tagPose(payload: String, qr: FloatArray, image: Image, s: Snapshot): TagPose? {
        val group = tagGroups.getOrPut(payload) { FeArTagCore.nativeTagGroup(payload) }
        if (group < 0) return null
        if (tagDetector == 0L) tagDetector = FeArTagCore.nativeTagDetectorCreate()
        if (tagDetector == 0L) return null
        val plane = image.planes[0]
        if (plane.pixelStride != 1) return null
        val w = image.width
        val h = image.height
        val q = diagonalCentre(qr) ?: return null

        // Region: the QR's corners pushed out past the frame corners (the
        // frame corner is 1.48 QR half-diagonals out on both formats).
        var x0 = Float.MAX_VALUE
        var y0 = Float.MAX_VALUE
        var x1 = -Float.MAX_VALUE
        var y1 = -Float.MAX_VALUE
        for (i in 0 until 4) {
            val x = q[0] + ROI_REACH * (qr[i * 2] - q[0])
            val y = q[1] + ROI_REACH * (qr[i * 2 + 1] - q[1])
            x0 = min(x0, x)
            y0 = min(y0, y)
            x1 = max(x1, x)
            y1 = max(y1, y)
        }
        val rx = max(0, x0.toInt())
        val ry = max(0, y0.toInt())
        val rw = min(w, x1.toInt() + 1) - rx
        val rh = min(h, y1.toInt() + 1) - ry
        if (rw < 32 || rh < 32) return null
        val decimate = if (max(rw, rh) > DECIMATE_ABOVE_PX) 2f else 1f
        val buffer: ByteBuffer = plane.buffer
        val n = FeArTagCore.nativeTagDetect(tagDetector, buffer, w, h, plane.rowStride, intArrayOf(rx, ry, rw, rh), decimate, tagOut)
        if (n <= 0) return null

        // Keep this payload's tags that sit where one of the QR frame's
        // corners is (either format), one per corner and format.
        val keptA4 = ArrayList<Int>()
        val keptA3 = ArrayList<Int>()
        val seen = HashSet<Int>()
        for (i in 0 until n) {
            val o = i * TAG_STRIDE
            val m = FeArTagCore.nativeTagMatch(payload, tagOut[o].toInt())
            if (m < 0 || !seen.add(m)) continue
            val a3 = m / 4 == 1
            val reach = if (a3) TAG_REACH_A3 else TAG_REACH_A4
            val tx = tagOut[o + 11]
            val ty = tagOut[o + 12]
            var near = false
            for (c in 0 until 4) {
                val vx = qr[c * 2] - q[0]
                val vy = qr[c * 2 + 1] - q[1]
                val px = q[0] + reach * vx
                val py = q[1] + reach * vy
                if (hypot(tx - px, ty - py) < TAG_POSITION_TOLERANCE * hypot(vx, vy)) {
                    near = true
                    break
                }
            }
            if (!near) continue
            if (a3) keptA3 += i else keptA4 += i
        }
        val kept = if (keptA3.size > keptA4.size) keptA3 else keptA4
        if (kept.size < MIN_TAGS) return null
        val dets = FloatArray(kept.size * TAG_STRIDE)
        kept.forEachIndexed { j, i -> System.arraycopy(tagOut, i * TAG_STRIDE, dets, j * TAG_STRIDE, TAG_STRIDE) }
        val out = FloatArray(13)
        if (!FeArTagCore.nativeTagBoardPose(payload, dets, kept.size, s.fx, s.fy, s.cx, s.cy, out)) return null
        if (out[10] > MAX_TAG_RMS_PX) return null
        return TagPose(
            floatArrayOf(out[0], out[1], out[2]),
            floatArrayOf(out[3], out[4], out[5]),
            out[10],
            out[11].toInt(),
            out[12].toInt() == 1,
        )
    }

    // ---------------------------------------------------------------- samples (main thread)

    private fun process(session: Session, frame: Frame, d: Detection, now: Long) {
        if ((cooldownUntil[d.payload] ?: 0L) > now) return
        val tag = d.tag
        if (tag != null && d.payload !in tagDistrusted) {
            processTag(session, frame, d, tag, now)
            return
        }
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
        progress(d.payload, list.size, SAMPLES_NEEDED, distance, viewAngle, gate)
        if (list.size >= SAMPLES_NEEDED) finish(session, d.payload, list, now, MAX_SPREAD_MM)
    }

    private fun processTag(session: Session, frame: Frame, d: Detection, tag: TagPose, now: Long) {
        val s = d.snapshot
        val origin = s.cameraPose.translation
        val centre = s.cameraPose.transformPoint(tag.centre)
        var n = ArMath.normalize(s.cameraPose.rotateVector(tag.normal))
        val toCam = ArMath.sub(origin, centre)
        if (ArMath.dot(n, toCam) < 0) n = ArMath.scale(n, -1f)
        val distance = ArMath.length(toCam)
        val viewAngle = Math.toDegrees(acos(ArMath.clamp(ArMath.dot(n, ArMath.normalize(toCam)), -1f, 1f).toDouble())).toFloat()

        // Print scale: ARCore's own distance to the wall along the same ray
        // (a plane or a depth point gates the tags; only a depth point is
        // precise enough to report as qrEdgeMm, as on the QR path).
        var scale: Float? = null
        var depthScale = false
        val dirWorld = ArMath.scale(ArMath.sub(centre, origin), 1f / max(distance, 1e-6f))
        val hits = try {
            frame.hitTest(origin, 0, dirWorld, 0)
        } catch (e: Exception) {
            emptyList()
        }
        for (h in hits) {
            val t = h.trackable
            val usable = (t is Plane && t.type == Plane.Type.VERTICAL && t.trackingState == TrackingState.TRACKING && t.isPoseInPolygon(h.hitPose)) ||
                t is DepthPoint
            if (usable) {
                val hd = ArMath.distance(h.hitPose.translation, origin)
                if (hd > 0.1f) {
                    scale = hd / distance
                    depthScale = t is DepthPoint
                }
                break
            }
        }
        val qrEdgeMm = if (depthScale) scale?.let { (if (tag.a3) QR_EDGE_A3_MM else QR_EDGE_A4_MM) * it } else null

        val maxDistance = if (tag.a3) 3.0f else 2.0f
        val gate = when {
            distance < 0.3f -> "tooClose"
            distance > maxDistance -> "tooFar"
            viewAngle > 40f -> "angle"
            else -> null
        }
        val list = tagSamples.getOrPut(d.payload) { ArrayList() }
        if (gate == null) {
            list += Sample(now, centre, n, "tag", distance, viewAngle, qrEdgeMm, scale)
            if (list.size > TAG_SAMPLES_MAX) list.subList(0, list.size - TAG_SAMPLES_MAX).clear()
        }
        progress(d.payload, list.size, TAG_SAMPLES_NEEDED, distance, viewAngle, gate)
        if (list.size < TAG_SAMPLES_NEEDED) return
        // A mis-scaled print moves a tag pose along the view ray by the same
        // factor: distrust the tags for this board, let the QR path lock it.
        val scales = list.mapNotNull { it.scale }
        if (scales.size >= list.size / 2 && abs(median(scales) - 1f) > TAG_SCALE_TOLERANCE) {
            tagDistrusted += d.payload
            tagSamples.remove(d.payload)
            return
        }
        finish(session, d.payload, list, now, MAX_TAG_SPREAD_MM)
    }

    private fun progress(payload: String, count: Int, needed: Int, distance: Float, viewAngle: Float, gate: String?) {
        if (!progressEvents) return
        emit(
            mapOf(
                "type" to "markerProgress",
                "rawPayload" to payload,
                "samples" to count,
                "needed" to needed,
                "distanceM" to distance.toDouble(),
                "viewAngleDeg" to viewAngle.toDouble(),
                "gate" to (gate ?: "ok"),
            ),
        )
    }

    private fun finish(session: Session, payload: String, list: ArrayList<Sample>, now: Long, maxSpreadMm: Float) {
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
        if (spreadMm > maxSpreadMm) {
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
        // median makes the whole observation pnp-grade. Tag samples are
        // never mixed with the others (separate lists).
        val method = when {
            list.any { it.method == "pnp" } -> "pnp"
            list.any { it.method == "depth" } -> "depth"
            list.all { it.method == "tag" } -> "tag"
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
                "qrEdgeMm" to if (edges.isNotEmpty() && edges.size >= list.size / 2) median(edges).toDouble() else null,
            ),
        )
        samples.remove(payload)
        tagSamples.remove(payload)
        cooldownUntil[payload] = now + COOLDOWN_MS
    }

    private fun expire(now: Long) {
        for (map in arrayOf(samples, tagSamples)) {
            val iter = map.entries.iterator()
            while (iter.hasNext()) {
                val e = iter.next()
                e.value.removeAll { s -> now - s.atMs > SAMPLE_TTL_MS }
                if (e.value.isEmpty()) iter.remove()
            }
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
        generation++
        for (t in anchors.values) runCatching { t.anchor.detach() }
        anchors.clear()
        samples.clear()
        tagSamples.clear()
        tagDistrusted.clear()
        pending.clear()
        cooldownUntil.clear()
    }

    fun close() {
        reset()
        scanner.close()
        tagExec.execute {
            if (tagDetector != 0L) FeArTagCore.nativeTagDetectorFree(tagDetector)
            tagDetector = 0L
        }
        tagPool.shutdown()
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
        if (abs(den) < 1e-6f) return null
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

        // Tags (fe_tag.h has the board geometry).
        const val MIN_TAGS = 2
        const val TAG_SAMPLES_NEEDED = 20
        const val TAG_SAMPLES_MAX = 30
        const val MAX_TAG_SPREAD_MM = 10f
        const val MAX_TAG_RMS_PX = 1.5f
        const val TAG_SCALE_TOLERANCE = 0.04f
        const val QR_EDGE_A4_MM = 115f
        const val QR_EDGE_A3_MM = 170f

        /** Search region: QR half-diagonals out from its centre (frame corner = 1.48). */
        const val ROI_REACH = 1.65f

        /** Tag centre in QR half-diagonals: 71.25 / 57.5 (A4), 105 / 85 (A3). */
        const val TAG_REACH_A4 = 1.2391f
        const val TAG_REACH_A3 = 1.2353f

        /** How far a tag may sit from its predicted spot, in QR half-diagonals (perspective, ML Kit corner noise). */
        const val TAG_POSITION_TOLERANCE = 0.25f
        const val DECIMATE_ABOVE_PX = 900
        const val MAX_DETECTIONS = 12
        const val TAG_STRIDE = 13
    }
}

/**
 * JNI bindings for the board AprilTags (packages/fe_ar/src/fe_tag.c, built into
 * libfe_ar_core by android/src/main/cpp/CMakeLists.txt; glue in fe_ar_jni.c).
 * Kept beside their only caller. A detector handle is used from one thread.
 */
internal object FeArTagCore {
    init {
        System.loadLibrary("fe_ar_core")
    }

    @JvmStatic external fun nativeTagDetectorCreate(): Long

    @JvmStatic external fun nativeTagDetectorFree(handle: Long)

    /**
     * tag36h11 in a DIRECT grey buffer (the Y plane). roi4 = [x, y, w, h].
     * out: 13 floats per detection [id, hamming, margin, 4 corners (bottom-left,
     * bottom-right, top-right, top-left as printed), centre]. Returns the count.
     */
    @JvmStatic external fun nativeTagDetect(
        handle: Long, grey: ByteBuffer, width: Int, height: Int, rowStride: Int, roi4: IntArray, decimate: Float, out: FloatArray,
    ): Int

    /** The payload's tag group (0..145), or -1 when it is not a marker code. */
    @JvmStatic external fun nativeTagGroup(payload: String): Int

    /** -1, or format * 4 + corner (format 0 A4, 1 A3; corner 0 TL, 1 TR, 2 BR, 3 BL). */
    @JvmStatic external fun nativeTagMatch(payload: String, tagId: Int): Int

    /** out13 = [centre xyz, normal xyz, up xyz, distance, rmsPx, nTags, format], camera space. */
    @JvmStatic external fun nativeTagBoardPose(
        payload: String, dets: FloatArray, n: Int, fx: Float, fy: Float, cx: Float, cy: Float, out13: FloatArray,
    ): Boolean
}
