package com.fusionapps.fe_ar

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.TextureView
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.google.android.filament.Engine
import com.google.android.filament.Scene
import com.google.ar.core.ArCoreApk
import com.google.ar.core.CameraConfig
import com.google.ar.core.CameraConfigFilter
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.RecordingConfig
import com.google.ar.core.RecordingStatus
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.UnavailableApkTooOldException
import com.google.ar.core.exceptions.UnavailableArcoreNotInstalledException
import com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException
import com.google.ar.core.exceptions.UnavailableSdkTooOldException
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.EnumSet
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * The Android half of the `fusioneco/ar` channel (CHANNEL.md, CONTRACT C8).
 *
 * **Native executes, Dart decides** (docs/ar-bim-overlay.md §6.1): nothing in
 * here chooses where the model goes, which tiles are resident or what is
 * highlighted. It keeps the last command of each kind so a recreated view
 * (rotation, backgrounding, a new route) comes back exactly as Dart left it.
 *
 * Threading: everything runs on the main thread (method calls, SceneView's
 * render-loop callbacks, ML Kit listeners); only file I/O, tile decoding and
 * JPEG encoding go to background executors and post back.
 */
internal class FeArController(private val appContext: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "fe_ar-io").apply { isDaemon = true } }
    private var sink: EventChannel.EventSink? = null

    private val tiles = TileStore { code, detail -> emitError(code, detail) }
    private val states = FeatureStates()
    private val markers = MarkerDetector(::emit)
    private val corners = CornerDetector(::emit)
    private val depthProbe = DepthProbe()
    private var renderer: TileRenderer? = null
    private var view: FeArPlatformView? = null

    // ---- activity lifecycle
    private var activity: Activity? = null
    private var activityResumed = false
    private var lifecycleObserver: LifecycleEventObserver? = null
    private var callbacks: Application.ActivityLifecycleCallbacks? = null

    // ---- session wishes (read by the composable)
    val sessionWanted = mutableStateOf(false)
    private var paused = false
    var wantDepth = true
        private set
    var playbackFile: File? = null
        private set
    private var recordTo: String? = null

    /** One recording per startSession (ARCore stops it itself on pause). */
    private var recordingStarted = false

    /**
     * Bumped when a startSession changes the playback file: the composable
     * is keyed on it, so SceneView builds a fresh ARCore session that reads
     * the new dataset. A stop immediately followed by a start (Dart's
     * restart) can otherwise land in one frame, and Compose would keep the
     * old session, still on the camera (or on the old recording).
     */
    val sessionGeneration = mutableIntStateOf(0)

    /** The torch as Dart last asked (`setTorch`); applied in configureSession too. */
    private var torchOn = false

    /**
     * The room-scan overlay (extension `setScanOverlay`): on Android it is
     * SceneView's own animated plane grid over the tracked planes (iOS draws
     * the LiDAR mesh or its own grid). Read by the composable, so a change
     * recomposes and SceneView's plane renderer follows (ARSceneView applies
     * `planeRenderer` in a SideEffect on every recomposition).
     */
    val scanOverlay = mutableStateOf(false)
    private var lastScanMs = 0L
    private var lastScan: Map<String, Double> = emptyMap()

    // ---- drawing state (replayed onto a new renderer)
    private var modelCurrent = ArMath.identity()
    /** True once Dart has sent a model transform this session (TileRenderer.placed). */
    private var modelPlaced = false
    /**
     * An at-once transform waiting for the next frame: "Place by hand" sends
     * one per finger move, and only the newest per frame reaches Filament.
     */
    private var modelDirty = false
    private var lastFloorMs = 0L
    private var lastFloorY: Float? = null
    private var floorPlane: Plane? = null
    private var easeFrom = ArMath.identity()
    private var easeTo = ArMath.identity()
    private var easeStartNs = 0L
    private var easeDurNs = 0L
    private var layers = LayerState()
    private var targetIds: Set<Int>? = null
    private var targetBuild: String? = null
    private var gridGlb: ByteArray? = null
    private var pinGlb: ByteArray? = null

    // ---- per-frame state
    private var latestSession: Session? = null
    private var latestFrame: Frame? = null
    private val viewMatrix = FloatArray(16)
    private val projMatrix = FloatArray(16)
    private var matricesValid = false
    private var lastState: String? = null
    private var lastReason: String? = null
    private var everTracked = false
    private var lastPoseMs = 0L
    private var lastCamCheckMs = 0L

    // Developer diagnostic (`fe_ar diag …` in logcat, never on screen):
    // checked twice a second, logged only when it changes.
    private var lastDiagMs = 0L
    private var lastDiag: String? = null

    /**
     * The per-2 s `camera check` log (Filament camera vs ARCore pose). It
     * settled P-012 on 2026-09-27 (the camera follows ARCore to the
     * millimetre), so it is off unless this flag is flipped in a debuggable
     * build.
     */
    private val cameraCheckLog = CAMERA_CHECK_LOG && (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /** SceneView's AR camera node for this view (FeArScene), for the camera check below. */
    var cameraNode: io.github.sceneview.ar.node.ARCameraNode? = null
    private var lastTargetMs = 0L
    private val startNs = SystemClock.elapsedRealtimeNanos()
    private var depthSupportCache: Boolean? = null

    private val density: Float get() = appContext.resources.displayMetrics.density

    // ======================================================== events

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) sink?.success(event) else main.post { sink?.success(event) }
    }

    private fun emitError(code: String, detail: String) = emit(mapOf("type" to "error", "code" to code, "detail" to detail))

    private fun emitTracking(state: String, reason: String?) {
        if (state == lastState && reason == lastReason) return
        lastState = state
        lastReason = reason
        emit(mapOf("type" to "tracking", "state" to state, "reason" to reason))
    }

    // ======================================================== activity / view

    fun attachActivity(act: Activity) {
        detachActivity()
        activity = act
        val owner = act as? LifecycleOwner
        if (owner != null) {
            val obs = LifecycleEventObserver { _, _ ->
                activityResumed = owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
                updateRunning()
            }
            owner.lifecycle.addObserver(obs)
            lifecycleObserver = obs
        } else {
            activityResumed = true
            val cb = object : Application.ActivityLifecycleCallbacks {
                override fun onActivityResumed(a: Activity) {
                    if (a === activity) {
                        activityResumed = true
                        updateRunning()
                    }
                }
                override fun onActivityPaused(a: Activity) {
                    if (a === activity) {
                        activityResumed = false
                        updateRunning()
                    }
                }
                override fun onActivityCreated(a: Activity, b: Bundle?) = Unit
                override fun onActivityStarted(a: Activity) = Unit
                override fun onActivityStopped(a: Activity) = Unit
                override fun onActivitySaveInstanceState(a: Activity, b: Bundle) = Unit
                override fun onActivityDestroyed(a: Activity) = Unit
            }
            act.application.registerActivityLifecycleCallbacks(cb)
            callbacks = cb
        }
        updateRunning()
    }

    fun detachActivity() {
        val act = activity ?: return
        lifecycleObserver?.let { (act as? LifecycleOwner)?.lifecycle?.removeObserver(it) }
        callbacks?.let { act.application.unregisterActivityLifecycleCallbacks(it) }
        lifecycleObserver = null
        callbacks = null
        activity = null
        activityResumed = false
        updateRunning()
    }

    fun attachView(v: FeArPlatformView) {
        view = v
        updateRunning()
    }

    fun detachView(v: FeArPlatformView) {
        if (view === v) view = null
    }

    private fun updateRunning() {
        view?.setRunning(sessionWanted.value && !paused && activityResumed)
    }

    /** SceneView's engine and scene are up: build the renderer and replay state. */
    fun onRendererReady(engine: Engine, scene: Scene) {
        renderer?.destroy()
        val r = TileRenderer(appContext, engine, scene)
        renderer = r
        r.setModelMatrix(modelCurrent)
        r.setLayers(layers, tiles.tiles.values)
        r.setPlaced(modelPlaced, tiles.tiles.values)
        r.setGrid(gridGlb)
        r.setPins(pinGlb)
        for (e in tiles.tiles.values) upload(e)
    }

    fun onRendererGone() {
        renderer?.destroy()
        renderer = null
        latestFrame = null
        latestSession = null
        matricesValid = false
    }

    private fun upload(entry: TileEntry) {
        val r = renderer
        if (r == null) {
            entry.pendingBytes = null // re-read when a renderer exists again
            return
        }
        if (r.hasTile(entry.hash)) return
        val bytes = entry.pendingBytes
        if (bytes != null) {
            if (!r.addTile(entry, bytes)) emitError("tile-upload-failed", entry.hash)
            entry.pendingBytes = null
        } else {
            tiles.readBytes(entry) { b ->
                if (b != null && renderer === r && tiles.tiles[entry.hash] === entry && !r.hasTile(entry.hash)) {
                    if (!r.addTile(entry, b)) emitError("tile-upload-failed", entry.hash)
                }
            }
        }
    }

    // ======================================================== session callbacks

    fun pickCameraConfig(session: Session): CameraConfig {
        // A recording plays back with the camera config it was recorded with;
        // choosing another one here would not match the dataset.
        if (playbackFile != null) return session.cameraConfig
        // The QR must be decodable from ~2 m (docs/ar-markers-and-qr.md §2.2):
        // take the largest CPU image up to 1080p at 30 fps.
        // The camera image on screen is the GPU texture, not the CPU image: a
        // config chosen by CPU size alone can come with a small texture, which
        // looked blurred full-screen on the first device run. Largest texture
        // first, then the largest CPU image up to 1080p for the QR decoder.
        return try {
            val filter = CameraConfigFilter(session).setTargetFps(EnumSet.of(CameraConfig.TargetFps.TARGET_FPS_30))
            val all = session.getSupportedCameraConfigs(filter)
            for (c in all) {
                android.util.Log.i("fe_ar", "camera config: cpu ${c.imageSize.width}x${c.imageSize.height} texture ${c.textureSize.width}x${c.textureSize.height} depth ${c.depthSensorUsage}")
            }
            val chosen = all
                .filter { it.imageSize.width <= 1920 }
                .maxWithOrNull(
                    compareBy<CameraConfig>({ it.textureSize.width * it.textureSize.height }, { it.imageSize.width * it.imageSize.height }),
                )
                ?: session.cameraConfig
            android.util.Log.i("fe_ar", "camera config chosen: cpu ${chosen.imageSize.width}x${chosen.imageSize.height} texture ${chosen.textureSize.width}x${chosen.textureSize.height}")
            chosen
        } catch (e: Exception) {
            session.cameraConfig
        }
    }

    fun configureSession(session: Session, config: Config) {
        config.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
        config.focusMode = Config.FocusMode.AUTO
        config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
        config.lightEstimationMode = Config.LightEstimationMode.DISABLED
        val depth = wantDepth && session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
        config.depthMode = if (depth) Config.DepthMode.AUTOMATIC else Config.DepthMode.DISABLED
        corners.depthEnabled = depth
        // AUTOMATIC also serves Raw Depth (acquireRawDepthImage16Bits), which
        // depthPointAt prefers for its per-pixel confidence.
        depthProbe.depthEnabled = depth
        // Kept across SceneView's own reconfigures (sessionConfiguration runs on each).
        config.flashMode = if (torchOn && playbackFile == null) Config.FlashMode.TORCH else Config.FlashMode.OFF
    }

    fun onSessionCreated(session: Session) {
        markers.reset()
        everTracked = false
        emitTracking("initializing", "initializing")
    }

    fun onSessionResumed(session: Session) {
        val target = recordTo
        if (target != null && !recordingStarted) {
            recordingStarted = true
            try {
                session.startRecording(
                    RecordingConfig(session).setMp4DatasetUri(Uri.fromFile(File(target))).setAutoStopOnPause(true),
                )
            } catch (e: Exception) {
                emitError("recording-failed", e.message ?: "")
            }
        }
    }

    fun onSessionPaused(session: Session) {
        emitTracking(ArTracking.PAUSED, null)
    }

    fun onSessionFailed(e: Exception) {
        val code = when (e) {
            is SecurityException -> "camera-denied"
            is CameraNotAvailableException -> "camera-unavailable"
            is UnavailableArcoreNotInstalledException, is UnavailableApkTooOldException -> "arcore-missing"
            is UnavailableSdkTooOldException -> "arcore-sdk-too-old"
            is UnavailableDeviceNotCompatibleException -> "device-not-supported"
            else -> "session-failed"
        }
        emitError(code, e.message ?: e.javaClass.simpleName)
        emitTracking(ArTracking.NOT_AVAILABLE, code)
    }

    /** SceneView's per-frame callback (main thread, render loop). */
    fun onFrame(session: Session, frame: Frame) {
        latestSession = session
        latestFrame = frame
        val cam = frame.camera
        val nowMs = SystemClock.elapsedRealtime()
        val tracking = cam.trackingState == TrackingState.TRACKING

        when (cam.trackingState) {
            TrackingState.TRACKING -> {
                everTracked = true
                emitTracking(ArTracking.TRACKING, null)
            }
            TrackingState.PAUSED ->
                if (!everTracked) emitTracking(ArTracking.INITIALIZING, "initializing")
                else emitTracking(ArTracking.LIMITED, reasonOf(cam.trackingFailureReason))
            else -> emitTracking(ArTracking.STOPPED, null)
        }

        cam.getViewMatrix(viewMatrix, 0)
        cam.getProjectionMatrix(projMatrix, 0, NEAR_M, FAR_M)
        matricesValid = true

        stepEase()
        if (modelDirty) {
            modelDirty = false
            renderer?.setModelMatrix(modelCurrent)
        }
        renderer?.tick((SystemClock.elapsedRealtimeNanos() - startNs) / 1e9f, tiles.tiles.values)
        if (nowMs - lastDiagMs >= 500L) {
            lastDiagMs = nowMs
            logDiagnostics()
        }

        if (tracking && nowMs - lastPoseMs >= POSE_INTERVAL_MS) {
            lastPoseMs = nowMs
            val m = FloatArray(16)
            cam.displayOrientedPose.toMatrix(m, 0)
            emit(mapOf("type" to "pose", "arFromCamera" to ArMath.toDoubleList(m)))
        }

        markers.onFrame(session, frame, tracking)

        // Debug check, every 2 s: the camera Filament renders with must sit
        // where ARCore says the phone is. If it doesn't move while the phone
        // does, the model is drawn screen-locked (P-012). Off by default
        // ([cameraCheckLog]).
        if (cameraCheckLog && tracking && nowMs - lastCamCheckMs >= 2000L) {
            lastCamCheckMs = nowMs
            val node = cameraNode
            if (node != null) {
                val fm = FloatArray(16)
                node.camera.getModelMatrix(fm)
                val a = cam.displayOrientedPose
                android.util.Log.d(
                    "fe_ar",
                    "camera check: filament=(%.3f, %.3f, %.3f) arcore=(%.3f, %.3f, %.3f) model=(%.3f, %.3f, %.3f) placed=%b"
                        .format(fm[12], fm[13], fm[14], a.tx(), a.ty(), a.tz(), modelCurrent[12], modelCurrent[13], modelCurrent[14], modelPlaced),
                )
            } else {
                android.util.Log.d("fe_ar", "camera check: no camera node")
            }
        }

        if (tracking && nowMs - lastFloorMs >= FLOOR_INTERVAL_MS) {
            lastFloorMs = nowMs
            detectFloor(session, cam.pose.ty())
        }

        if (targetIds != null && tracking && nowMs - lastTargetMs >= TARGET_INTERVAL_MS) {
            lastTargetMs = nowMs
            targetScreen()?.let { emit(it) }
        }

        if (scanOverlay.value && nowMs - lastScanMs >= SCAN_INTERVAL_MS) {
            lastScanMs = nowMs
            reportScan(session)
        }
    }

    /**
     * The `scan` event (extension, CHANNEL.md) from ARCore's tracked planes:
     * how many floors and walls, and their area. iOS sends the same shape
     * from its LiDAR mesh or planes. At most 1 Hz, only when it changed.
     */
    private fun reportScan(session: Session) {
        var walls = 0
        var floors = 0
        var floorM2 = 0.0
        var wallM2 = 0.0
        var ceilingM2 = 0.0
        for (p in session.getAllTrackables(Plane::class.java)) {
            if (p.trackingState != TrackingState.TRACKING || p.subsumedBy != null) continue
            val area = (p.extentX * p.extentZ).toDouble()
            when (p.type) {
                Plane.Type.HORIZONTAL_UPWARD_FACING -> { floors++; floorM2 += area }
                Plane.Type.VERTICAL -> { walls++; wallM2 += area }
                else -> ceilingM2 += area
            }
        }
        val now = mapOf(
            "walls" to walls.toDouble(), "floors" to floors.toDouble(),
            "floorM2" to floorM2, "wallM2" to wallM2, "ceilingM2" to ceilingM2, "otherM2" to 0.0,
        )
        val changed = now.any { (k, v) -> kotlin.math.abs(v - (lastScan[k] ?: -1.0)) >= (if (k.endsWith("M2")) 0.1 else 0.5) }
        if (!changed) return
        lastScan = now
        val event = mutableMapOf<String, Any?>("type" to "scan", "source" to "planes", "surfaces" to walls + floors)
        for ((k, v) in now) event[k] = if (k.endsWith("M2")) Math.round(v * 100) / 100.0 else v
        emit(event)
    }

    /**
     * The tracked floor height and ARCore's planes (extension `planes`,
     * CHANNEL.md revision 2), for "Place by hand": walls for Snap to wall,
     * wall pairs for the room corners Snap corner magnets to. Wall normals are
     * levelled and turned to face the camera (into the room); `segment` is
     * the wall's measured horizontal extent from its polygon. Read-only.
     */
    private fun trackedPlanes(): Map<String, Any?> {
        val out = ArrayList<Map<String, Any?>>()
        val session = latestSession
        val cam = latestFrame?.camera?.pose?.translation
        if (session != null) {
            for (p in session.getAllTrackables(Plane::class.java)) {
                if (out.size >= MAX_PLANES) break
                if (p.trackingState != TrackingState.TRACKING || p.subsumedBy != null) continue
                val vertical = p.type == Plane.Type.VERTICAL
                if (p.extentX * p.extentZ < (if (vertical) WALL_MIN_AREA_M2 else FLOOR_MIN_AREA_M2)) continue
                val pose = p.centerPose
                val centre = pose.translation
                var n = pose.getTransformedAxis(1, 1f)
                val entry = HashMap<String, Any?>()
                entry["id"] = "plane-${System.identityHashCode(p)}"
                if (vertical) {
                    val level = floatArrayOf(n[0], 0f, n[2])
                    if (ArMath.length(level) < 0.5f) continue
                    n = ArMath.normalize(level)
                    if (cam != null && ArMath.dot(ArMath.sub(cam, centre), n) < 0f) n = ArMath.scale(n, -1f)
                    entry["kind"] = "wall"
                    // Horizontal extent along the wall, vertical extent up it.
                    val along = floatArrayOf(n[2], 0f, -n[0])
                    var lo = Float.MAX_VALUE
                    var hi = -Float.MAX_VALUE
                    var bottom = Float.MAX_VALUE
                    var top = -Float.MAX_VALUE
                    val poly = p.polygon
                    poly.rewind()
                    while (poly.remaining() >= 2) {
                        val w = pose.transformPoint(floatArrayOf(poly.get(), 0f, poly.get()))
                        val u = ArMath.dot(ArMath.sub(w, centre), along)
                        lo = min(lo, u)
                        hi = max(hi, u)
                        bottom = min(bottom, w[1])
                        top = max(top, w[1])
                    }
                    if (lo < hi) {
                        val a0 = ArMath.add(centre, ArMath.scale(along, lo))
                        val b0 = ArMath.add(centre, ArMath.scale(along, hi))
                        entry["segment"] = listOf(listOf(a0[0].toDouble(), a0[2].toDouble()), listOf(b0[0].toDouble(), b0[2].toDouble()))
                        entry["widthM"] = (hi - lo).toDouble()
                        entry["heightM"] = max(0f, top - bottom).toDouble()
                    }
                } else {
                    entry["kind"] = if (p.type == Plane.Type.HORIZONTAL_UPWARD_FACING) "floor" else "ceiling"
                }
                entry["centerAr"] = ArMath.toDoubleList(centre)
                entry["normalAr"] = ArMath.toDoubleList(n)
                out.add(entry)
            }
        }
        return mapOf("floorY" to lastFloorY?.toDouble(), "planes" to out)
    }

    /**
     * The floor for the fit's height (extension event `floor`): the largest
     * tracked upward plane of at least [FLOOR_MIN_AREA_M2] that sits a
     * standing phone's height below the camera (a table or bed is too high).
     * Emitted when it first appears or moves by 1 cm, at most once a second.
     */
    private fun detectFloor(session: Session, cameraY: Float) {
        var best: Plane? = null
        for (p in session.getAllTrackables(Plane::class.java)) {
            if (p.type != Plane.Type.HORIZONTAL_UPWARD_FACING || p.trackingState != TrackingState.TRACKING || p.subsumedBy != null) continue
            if (p.extentX * p.extentZ < FLOOR_MIN_AREA_M2) continue
            val drop = cameraY - p.centerPose.ty()
            if (drop < FLOOR_MIN_DROP_M || drop > FLOOR_MAX_DROP_M) continue
            // The largest, not the lowest: a small false plane under the floor
            // won on "lowest" in the first device run (27 cm too low).
            if (best == null || p.extentX * p.extentZ > best.extentX * best.extentZ) best = p
        }
        // Sticky: two floor planes ~10 cm apart traded places as each grew, and
        // the model bounced. Keep the current plane while it is tracked (or
        // follow what it merged into) unless another is clearly bigger.
        val current = floorPlane?.let { it.subsumedBy ?: it }
        if (current != null && current.trackingState == TrackingState.TRACKING && best != null && best != current &&
            best.extentX * best.extentZ < FLOOR_SWITCH_RATIO * current.extentX * current.extentZ
        ) {
            best = current
        }
        val floor = best ?: return
        floorPlane = floor
        val y = floor.centerPose.ty()
        val last = lastFloorY
        if (last != null && kotlin.math.abs(y - last) < 0.01f) return
        lastFloorY = y
        emit(mapOf("type" to "floor", "yAr" to y.toDouble(), "areaM2" to (floor.extentX * floor.extentZ).toDouble()))
    }

    private fun reasonOf(r: TrackingFailureReason): String = when (r) {
        TrackingFailureReason.INSUFFICIENT_LIGHT -> "insufficientLight"
        TrackingFailureReason.EXCESSIVE_MOTION -> "excessiveMotion"
        TrackingFailureReason.INSUFFICIENT_FEATURES -> "insufficientFeatures"
        TrackingFailureReason.CAMERA_UNAVAILABLE -> "cameraUnavailable"
        TrackingFailureReason.BAD_STATE -> "badState"
        else -> "relocalizing"
    }

    // ======================================================== model transform

    private fun setModel(m: FloatArray, easeMs: Int) {
        if (!modelPlaced) {
            // First placement: jump straight there (never ease in from the
            // session origin), then show the model.
            modelPlaced = true
            modelCurrent = m
            easeDurNs = 0L
            renderer?.setModelMatrix(modelCurrent)
            renderer?.setPlaced(true, tiles.tiles.values)
            return
        }
        if (easeMs <= 0 || !ArMath.isYawTranslation(modelCurrent) || !ArMath.isYawTranslation(m)) {
            // At once (a scaled "Place by hand" matrix is never 4-DoF), applied
            // on the next frame: at most one transform per frame.
            modelCurrent = m
            easeDurNs = 0L
            modelDirty = true
            return
        }
        easeFrom = modelCurrent.copyOf()
        easeTo = m
        easeStartNs = SystemClock.elapsedRealtimeNanos()
        easeDurNs = easeMs * 1_000_000L
    }

    /** Eases the model over easeMs: yaw along the shortest arc, translation linearly. Never snaps. */
    /**
     * "Model elements sometimes don't show" (2026-10-09): what native holds
     * against what it draws, for device tests. Compare with Dart's
     * `[ar-diag] dart tiles=N/M …` (see the iOS twin in FeArController.swift).
     */
    private fun logDiagnostics() {
        val scale = kotlin.math.sqrt(modelCurrent[4] * modelCurrent[4] + modelCurrent[5] * modelCurrent[5] + modelCurrent[6] * modelCurrent[6])
        val line = "store=${tiles.tiles.size} modelPlaced=${if (modelPlaced) 1 else 0} " +
            "layers=${if (layers.mep) "M" else "m"}${if (layers.structure) "S" else "s"}${if (layers.architecture) "A" else "a"} " +
            "scale=${"%.1f".format(scale)} " + (renderer?.diagnostics() ?: "renderer=null")
        if (line == lastDiag) return
        lastDiag = line
        android.util.Log.i("fe_ar", "fe_ar diag $line")
    }

    private fun stepEase() {
        if (easeDurNs == 0L) return
        val t = ((SystemClock.elapsedRealtimeNanos() - easeStartNs).toFloat() / easeDurNs).coerceIn(0f, 1f)
        if (t >= 1f) {
            modelCurrent = easeTo
            easeDurNs = 0L
        } else {
            val s = ArMath.ease(t)
            val y0 = ArMath.yawOf(easeFrom)
            val y1 = ArMath.yawOf(easeTo)
            val yaw = y0 + ArMath.wrapAngle(y1 - y0) * s
            modelCurrent = ArMath.fromYawTranslation(
                yaw,
                easeFrom[12] + (easeTo[12] - easeFrom[12]) * s,
                easeFrom[13] + (easeTo[13] - easeFrom[13]) * s,
                easeFrom[14] + (easeTo[14] - easeFrom[14]) * s,
            )
        }
        renderer?.setModelMatrix(modelCurrent)
    }

    // ======================================================== geometry queries

    private fun viewSizePx(): Pair<Float, Float>? {
        val v = view?.composeView ?: return null
        if (v.width <= 0 || v.height <= 0) return null
        return v.width.toFloat() to v.height.toFloat()
    }

    private fun viewProj(): FloatArray? = if (matricesValid) ArMath.multiply(projMatrix, viewMatrix) else null

    /** World ray through a view pixel: origin on the near plane, unit direction. */
    private fun rayThrough(xPx: Float, yPx: Float): Pair<FloatArray, FloatArray>? {
        val (w, h) = viewSizePx() ?: return null
        val inv = viewProj()?.let { ArMath.invert(it) } ?: return null
        val nx = 2f * xPx / w - 1f
        val ny = 1f - 2f * yPx / h
        fun unproject(z: Float): FloatArray {
            val p = floatArrayOf(nx, ny, z, 1f)
            val o = FloatArray(4)
            for (r in 0 until 4) o[r] = inv[r] * p[0] + inv[4 + r] * p[1] + inv[8 + r] * p[2] + inv[12 + r] * p[3]
            return floatArrayOf(o[0] / o[3], o[1] / o[3], o[2] / o[3])
        }
        val near = unproject(-1f)
        val far = unproject(1f)
        return near to ArMath.normalize(ArMath.sub(far, near))
    }

    /** Projects an AR-world point; x, y in LOGICAL pixels. */
    private fun project(world: FloatArray): Triple<Float, Float, Boolean>? {
        val (w, h) = viewSizePx() ?: return null
        val vp = viewProj() ?: return null
        val c = FloatArray(4)
        for (r in 0 until 4) c[r] = vp[r] * world[0] + vp[4 + r] * world[1] + vp[8 + r] * world[2] + vp[12 + r]
        val behind = c[3] <= 1e-6f
        val ww = if (behind) max(-c[3], 1e-6f) else c[3]
        var px = (c[0] / ww + 1f) / 2f * w
        var py = (1f - c[1] / ww) / 2f * h
        if (behind) {
            // mirrored, so an edge arrow still points the way to turn
            px = w - px
            py = h - py
        }
        val on = !behind && px in 0f..w && py in 0f..h
        return Triple(px / density, py / density, on)
    }

    private fun pick(xLogical: Float, yLogical: Float): Map<String, Any?>? {
        val (origin, dir) = rayThrough(xLogical * density, yLogical * density) ?: return null
        // A hand placement at another size is not rigid: the general inverse
        // then, and the tile-frame direction re-normalised so t stays metres.
        val tileFromAr = if (ArMath.isYawTranslation(modelCurrent)) ArMath.invertRigid(modelCurrent)
        else ArMath.invert(modelCurrent) ?: ArMath.invertRigid(modelCurrent)
        val o = ArMath.transformPoint(tileFromAr, origin)
        val d = ArMath.normalize(ArMath.transformDir(tileFromAr, dir))
        val out = FloatArray(7)
        var bestT = FAR_M
        var best: Pair<TileEntry, Int>? = null
        var bestHit: FloatArray? = null
        for (e in tiles.tiles.values) {
            if (!layers.visible(e.layer)) continue
            val li = FeArCore.nativeTileRaycast(e.handle, o, d, bestT, e.skipMask, out)
            if (li == -2 || out[0] >= bestT) continue
            bestT = out[0]
            best = e to li
            bestHit = out.copyOf()
        }
        val (entry, local) = best ?: return null
        val hit = bestHit!!
        val featureId = entry.featureIdAt(local)
        if (featureId < 0) return null
        val hitTile = floatArrayOf(hit[1], hit[2], hit[3])
        val camPos = latestFrame?.camera?.displayOrientedPose?.translation
        val hitWorld = ArMath.transformPoint(modelCurrent, hitTile)
        return mapOf(
            "featureId" to featureId,
            "buildId" to entry.buildId.ifEmpty { null },
            "tileHash" to entry.hash,
            "localIndex" to local,
            "hitPointTile" to ArMath.toDoubleList(hitTile),
            "normalTile" to listOf(hit[4].toDouble(), hit[5].toDouble(), hit[6].toDouble()),
            "distanceM" to (camPos?.let { ArMath.distance(it, hitWorld) } ?: bestT).toDouble(),
        )
    }

    private fun computeTargetLocals(e: TileEntry) {
        val ids = targetIds
        if (ids == null || (targetBuild != null && targetBuild != e.buildId)) {
            e.targetLocals = IntArray(0)
            return
        }
        val locals = ArrayList<Int>()
        for (i in e.featureIds.indices) if (e.featureIds[i] in ids) locals += i
        e.targetLocals = locals.toIntArray()
    }

    private fun targetScreen(): Map<String, Any?>? {
        val mn = floatArrayOf(Float.MAX_VALUE, Float.MAX_VALUE, Float.MAX_VALUE)
        val mx = floatArrayOf(-Float.MAX_VALUE, -Float.MAX_VALUE, -Float.MAX_VALUE)
        val b = FloatArray(6)
        var any = false
        for (e in tiles.tiles.values) {
            for (l in e.targetLocals) {
                if (!FeArCore.nativeTileLocalBounds(e.handle, l, b)) continue
                any = true
                for (k in 0 until 3) {
                    mn[k] = min(mn[k], b[k])
                    mx[k] = max(mx[k], b[3 + k])
                }
            }
        }
        if (!any) return null
        val centre = floatArrayOf((mn[0] + mx[0]) / 2f, (mn[1] + mx[1]) / 2f, (mn[2] + mx[2]) / 2f)
        val (x, y, on) = project(ArMath.transformPoint(modelCurrent, centre)) ?: return null
        return mapOf("type" to "targetScreen", "x" to x.toDouble(), "y" to y.toDouble(), "onScreen" to on)
    }

    // ======================================================== capabilities

    private fun capabilities(): Map<String, Any?> {
        val availability = try {
            ArCoreApk.getInstance().checkAvailability(appContext)
        } catch (e: Exception) {
            ArCoreApk.Availability.UNKNOWN_ERROR
        }
        val cameraOk = appContext.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        val reason = when {
            availability == ArCoreApk.Availability.UNSUPPORTED_DEVICE_NOT_CAPABLE -> "device-not-supported"
            availability == ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED ||
                availability == ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD -> "arcore-missing"
            availability.isTransient -> "arcore-checking"
            availability != ArCoreApk.Availability.SUPPORTED_INSTALLED -> "arcore-unknown"
            !cameraOk -> "camera-denied"
            else -> null
        }
        val supported = reason == null
        return mapOf(
            "supported" to supported,
            "depth" to (supported && depthSupported()),
            "lidar" to false,
            "recording" to supported,
            "platform" to "android",
            "reason" to reason,
            // extras (Dart ignores unknown keys)
            "arcore" to availability.name,
            "featureMaterial" to hasAsset("fe_ar/fe_feature.filamat"),
            "torch" to (supported && torchAvailable()),
            // the room-scan overlay (SceneView's plane grid); no LiDAR mesh here
            "scanOverlay" to supported,
            "mesh" to false,
        )
    }

    /** The back camera has a flash unit (ARCore drives it as a torch: Config.FlashMode.TORCH). */
    private fun torchAvailable(): Boolean = try {
        val cm = appContext.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        cm.cameraIdList.any { id ->
            val ch = cm.getCameraCharacteristics(id)
            ch.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK &&
                ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        }
    } catch (e: Exception) {
        false
    }

    /**
     * Applies [torchOn] to the running session now (session.configure with
     * the current config plus the flash mode). False when there is no
     * session yet (configureSession applies it when one starts) or during
     * playback (a recording has no torch).
     */
    /**
     * `setDepth {on}` (extension): ARCore depth is one of the heaviest parts
     * of a session and only corner snaps, wall taps and the print-scale check
     * use it. Dart turns it off once the model is placed and back on for
     * setup (device test 2026-09-27: the phone ran hot).
     */
    private fun setDepth(on: Boolean): Boolean {
        if (wantDepth == on) return true
        wantDepth = on
        val s = latestSession ?: return true // applied by configureSession on start
        return try {
            val cfg = s.config
            val depth = on && s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
            cfg.depthMode = if (depth) Config.DepthMode.AUTOMATIC else Config.DepthMode.DISABLED
            s.configure(cfg)
            corners.depthEnabled = depth
            depthProbe.depthEnabled = depth
            true
        } catch (e: Exception) {
            false
        }
    }

    // ------------------------------------------------ power: refresh + thermal

    private var savedModeId: Int? = null
    private var thermalListener: Any? = null

    /**
     * The camera runs at 30 fps, but SceneView draws on every display frame:
     * 90 Hz on a OnePlus 7 Pro, three draws per camera image. While AR runs,
     * ask for the lowest refresh mode ≥ 30 Hz at the current resolution.
     */
    private fun lowerRefreshRate() {
        val act = activity ?: return
        try {
            @Suppress("DEPRECATION")
            val display = if (android.os.Build.VERSION.SDK_INT >= 30) act.display else act.windowManager.defaultDisplay
            display ?: return
            val cur = display.mode
            val mode = display.supportedModes
                .filter { it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight && it.refreshRate >= 29f }
                .minByOrNull { it.refreshRate } ?: return
            val attrs = act.window.attributes
            if (savedModeId == null) savedModeId = attrs.preferredDisplayModeId
            attrs.preferredDisplayModeId = mode.modeId
            act.window.attributes = attrs
        } catch (_: Exception) {
            // Best effort: some devices refuse; AR still runs.
        }
    }

    private fun restoreRefreshRate() {
        val act = activity ?: return
        val id = savedModeId ?: return
        try {
            val attrs = act.window.attributes
            attrs.preferredDisplayModeId = id
            act.window.attributes = attrs
        } catch (_: Exception) {
        }
        savedModeId = null
    }

    /** Thermal status (API 29+) as a `thermal` event, so Dart can pause AR before the OS throttles it. */
    private fun startThermal() {
        if (android.os.Build.VERSION.SDK_INT < 29 || thermalListener != null) return
        val pm = appContext.getSystemService(android.content.Context.POWER_SERVICE) as? android.os.PowerManager ?: return
        val l = android.os.PowerManager.OnThermalStatusChangedListener { status ->
            emit(mapOf("type" to "thermal", "status" to status, "level" to thermalLevel(status)))
        }
        pm.addThermalStatusListener(l)
        thermalListener = l
    }

    private fun stopThermal() {
        if (android.os.Build.VERSION.SDK_INT < 29) return
        val l = thermalListener as? android.os.PowerManager.OnThermalStatusChangedListener ?: return
        (appContext.getSystemService(android.content.Context.POWER_SERVICE) as? android.os.PowerManager)?.removeThermalStatusListener(l)
        thermalListener = null
    }

    private fun thermalLevel(status: Int): String = when (status) {
        0 -> "none"
        1 -> "light"
        2 -> "moderate"
        3 -> "severe"
        4 -> "critical"
        5 -> "emergency"
        else -> "shutdown"
    }

    /**
     * `refocus` (extension): ARCore has no focus-at-point API, only AUTO or
     * FIXED. Switching to FIXED and back to AUTO a moment later restarts the
     * autofocus sweep, which clears a lens that settled on the wrong
     * distance (first device run: "too blurred, sometimes never focusing").
     */
    private fun refocus(): Boolean {
        if (playbackFile != null) return false
        val s = latestSession ?: return false
        return try {
            val cfg = s.config
            cfg.focusMode = Config.FocusMode.FIXED
            s.configure(cfg)
            main.postDelayed({
                try {
                    val c = s.config
                    c.focusMode = Config.FocusMode.AUTO
                    s.configure(c)
                } catch (_: Exception) {
                    // Session gone meanwhile: the next configureSession sets AUTO.
                }
            }, REFOCUS_DELAY_MS)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun applyTorch(): Boolean {
        if (playbackFile != null) return false
        val s = latestSession ?: return false
        return try {
            val cfg = s.config
            cfg.flashMode = if (torchOn) Config.FlashMode.TORCH else Config.FlashMode.OFF
            s.configure(cfg)
            true
        } catch (e: Exception) {
            emitError("torch-failed", e.message ?: e.javaClass.simpleName)
            false
        }
    }

    // ======================================================== recording (debug rig)

    /** `startRecording {path}`: records the running session to an MP4 (ARCore Recording & Playback). */
    private fun startRecording(path: String): Boolean {
        File(path).parentFile?.mkdirs()
        val s = latestSession
        if (s == null) {
            // No session yet: onSessionResumed starts it, as for startSession's recordTo.
            recordTo = path
            recordingStarted = false
            return true
        }
        return try {
            if (s.recordingStatus == RecordingStatus.OK) s.stopRecording()
            s.startRecording(RecordingConfig(s).setMp4DatasetUri(Uri.fromFile(File(path))).setAutoStopOnPause(true))
            recordTo = path
            recordingStarted = true
            true
        } catch (e: Exception) {
            emitError("recording-failed", e.message ?: e.javaClass.simpleName)
            false
        }
    }

    /** `stopRecording`: finishes the MP4; its path, or null when nothing was recording. */
    private fun stopRecording(): String? {
        val path = recordTo
        recordTo = null
        val s = latestSession
        try {
            if (s != null && s.recordingStatus == RecordingStatus.OK) s.stopRecording()
        } catch (e: Exception) {
            emitError("recording-failed", e.message ?: e.javaClass.simpleName)
        }
        return path
    }

    /**
     * Depth support needs a Session; made once (never resumed, so no camera)
     * and cached. TODO(slice-0): confirm a second, never-resumed Session is
     * harmless while SceneView's is alive (capabilities is normally asked
     * before the AR screen opens).
     */
    private fun depthSupported(): Boolean {
        depthSupportCache?.let { return it }
        val result = try {
            val s = Session(appContext)
            try {
                s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
            } finally {
                s.close()
            }
        } catch (e: Exception) {
            false
        }
        depthSupportCache = result
        return result
    }

    private fun hasAsset(path: String): Boolean = try {
        appContext.assets.open(path).use { true }
    } catch (e: Exception) {
        false
    }

    // ======================================================== capture

    private fun capture(result: MethodChannel.Result) {
        val surface = view?.findRenderSurface()
        fun save(bmp: Bitmap) {
            io.execute {
                val path = runCatching {
                    val dir = File(appContext.cacheDir, "fe_ar").apply { mkdirs() }
                    val file = File(dir, "capture_${System.currentTimeMillis()}.jpg")
                    FileOutputStream(file).use { bmp.compress(Bitmap.CompressFormat.JPEG, 88, it) }
                    file.absolutePath
                }.getOrNull()
                bmp.recycle()
                main.post { result.success(path) }
            }
        }
        when (surface) {
            is TextureView -> {
                val bmp = surface.bitmap
                if (bmp == null) result.success(null) else save(bmp)
            }
            is SurfaceView -> {
                if (surface.width <= 0 || surface.height <= 0) {
                    result.success(null)
                    return
                }
                val bmp = Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888)
                try {
                    PixelCopy.request(surface, bmp, { code ->
                        if (code == PixelCopy.SUCCESS) save(bmp) else {
                            bmp.recycle()
                            result.success(null)
                        }
                    }, main)
                } catch (e: Exception) {
                    bmp.recycle()
                    result.success(null)
                }
            }
            else -> result.success(null)
        }
    }

    // ======================================================== commands

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val a = Args.map(call.arguments)
        try {
            when (call.method) {
                "capabilities" -> result.success(capabilities())
                "startSession" -> startSession(a, result)
                "loadTiles" -> loadTiles(a, result)
                "unloadTiles" -> {
                    val hashes = (a["hashes"] as? List<*>).orEmpty().mapNotNull { it?.toString() }
                    tiles.unload(hashes) { e -> renderer?.removeTile(e.hash) }
                    result.success(null)
                }
                "setModelTransform" -> {
                    val m = Args.floats(a["matrix"] ?: a["arFromTile"], 16)
                    if (m == null) result.error("bad-args", "matrix must be 16 numbers, column-major", null)
                    else {
                        setModel(m, Args.int(a["easeMs"]) ?: 300)
                        result.success(null)
                    }
                }
                "setFeatureState" -> {
                    val rgba = Args.bytes(a["rgba"])
                    val width = Args.int(a["width"]) ?: 0
                    if (rgba == null || width <= 0) result.error("bad-args", "rgba and width are required", null)
                    else {
                        states.set(Args.string(a["buildId"]), FeatureStates.Texture(rgba, width))
                        for (e in tiles.tiles.values) {
                            states.gather(e)
                            renderer?.syncTile(e)
                        }
                        result.success(null)
                    }
                }
                "setLayers" -> {
                    layers = LayerState(
                        mep = Args.bool(a["mep"]) ?: true,
                        structure = Args.bool(a["structure"]) ?: true,
                        architecture = Args.bool(a["architecture"]) ?: true,
                        opacity = (Args.float(a["opacity"]) ?: 1f).coerceIn(0f, 1f),
                        sectionY = Args.float(a["sectionY"]),
                        grid = Args.bool(a["grid"]) ?: true,
                        contrast = Args.bool(a["contrast"]) ?: false,
                    )
                    renderer?.setLayers(layers, tiles.tiles.values)
                    result.success(null)
                }
                "setTarget" -> {
                    val ids = Args.ints(a["featureIds"])
                    targetIds = ids?.toHashSet()
                    targetBuild = Args.string(a["buildId"])
                    for (e in tiles.tiles.values) computeTargetLocals(e)
                    lastTargetMs = 0L
                    result.success(null)
                }
                "setGridLines" -> {
                    val lines = (a["lines"] as? List<*>).orEmpty()
                    val flat = ArrayList<Float>()
                    for (l in lines) {
                        val m = l as? Map<*, *> ?: continue
                        val p0 = Args.floats(m["p0"], 2) ?: continue
                        val p1 = Args.floats(m["p1"], 2) ?: continue
                        flat += listOf(p0[0], p0[1], p1[0], p1[1])
                    }
                    val floorY = Args.float(a["floorY"]) ?: 0f
                    gridGlb = if (flat.isEmpty()) null else FeArCore.nativeOverlayGlb(flat.toFloatArray(), floorY, GRID_RGB, null, null)
                    renderer?.setGrid(gridGlb)
                    result.success(null)
                }
                "setPins" -> {
                    pinGlb = buildPins((a["pins"] as? List<*>).orEmpty())
                    renderer?.setPins(pinGlb)
                    result.success(null)
                }
                "detectCornerAt" -> {
                    val s = latestSession
                    val f = latestFrame
                    val x = Args.float(a["x"])
                    val y = Args.float(a["y"])
                    if (s == null || f == null || x == null || y == null) result.success(null)
                    else result.success(corners.detect(s, f, x * density, y * density))
                }
                "anchorAt" -> {
                    val s = latestSession
                    val p = Args.floats(a["posAr"], 3)
                    result.success(if (s == null || p == null) null else markers.anchorAt(s, p))
                }
                "pick" -> {
                    val x = Args.float(a["x"])
                    val y = Args.float(a["y"])
                    result.success(if (x == null || y == null) null else pick(x, y))
                }
                // ---- extensions (CHANNEL.md "Extensions")
                "pickMany" -> {
                    val pts = (a["points"] as? List<*>).orEmpty()
                    result.success(pts.map { p -> Args.floats(p, 2)?.let { pick(it[0], it[1]) } })
                }
                "depthPointAt" -> {
                    val f = latestFrame
                    val x = Args.float(a["x"])
                    val y = Args.float(a["y"])
                    result.success(if (f == null || x == null || y == null) null else depthProbe.pointAt(f, x * density, y * density))
                }
                "refocus" -> result.success(refocus())
                "setDepth" -> result.success(setDepth(Args.bool(a["on"]) ?: true))
                "setTorch" -> {
                    torchOn = Args.bool(a["on"]) ?: false
                    result.success(applyTorch())
                }
                "setScanOverlay" -> {
                    scanOverlay.value = Args.bool(a["on"]) ?: false
                    if (!scanOverlay.value) lastScan = emptyMap()
                    result.success(true)
                }
                "startRecording" -> {
                    val path = Args.string(a["path"])
                    if (path == null) result.error("bad-args", "path is required", null)
                    else result.success(startRecording(path))
                }
                "stopRecording" -> result.success(stopRecording())
                "capture" -> capture(result)
                "pause" -> {
                    paused = true
                    updateRunning()
                    result.success(null)
                }
                "resume" -> {
                    paused = false
                    updateRunning()
                    result.success(null)
                }
                "stop" -> {
                    stopSession()
                    result.success(null)
                }
                // ---- extensions (CHANNEL.md "Extensions"; not in C8)
                "projectTile" -> {
                    val pts = (a["points"] as? List<*>).orEmpty()
                    result.success(pts.map { p ->
                        val v = Args.floats(p, 3) ?: return@map null
                        project(ArMath.transformPoint(modelCurrent, v))?.let { (x, y, on) -> listOf(x.toDouble(), y.toDouble(), on) }
                    })
                }
                "rayAt" -> {
                    // World rays through view points ("Place by hand" drags the
                    // model along the floor; Dart meets them with the floor plane).
                    val pts = (a["points"] as? List<*>).orEmpty()
                    result.success(pts.map { p ->
                        val v = Args.floats(p, 2) ?: return@map null
                        val (o, d) = rayThrough(v[0] * density, v[1] * density) ?: return@map null
                        mapOf("originAr" to ArMath.toDoubleList(o), "dirAr" to ArMath.toDoubleList(d))
                    })
                }
                "planes" -> result.success(trackedPlanes())
                "installArCore" -> {
                    val act = activity
                    if (act == null) result.success(false)
                    else result.success(
                        try {
                            ArCoreApk.getInstance().requestInstall(act, true) == ArCoreApk.InstallStatus.INSTALLED
                        } catch (e: Exception) {
                            false
                        },
                    )
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native-error", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun startSession(a: Map<*, *>, result: MethodChannel.Result) {
        wantDepth = Args.bool(a["depth"]) ?: true
        lowerRefreshRate()
        startThermal()
        markers.progressEvents = Args.bool(a["progressEvents"]) ?: false
        recordTo = Args.string(a["recordTo"])
        recordingStarted = false
        val playback = Args.string(a["playbackFrom"])?.let { File(it) }
        if (playback?.path != playbackFile?.path) sessionGeneration.intValue++
        playbackFile = playback
        torchOn = false
        val act = activity
        val availability = try {
            ArCoreApk.getInstance().checkAvailability(appContext)
        } catch (e: Exception) {
            ArCoreApk.Availability.UNKNOWN_ERROR
        }
        if (act != null && (availability == ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED ||
                availability == ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD)
        ) {
            // Google Play Services for AR is missing or old: ask the Play Store
            // for it. The app resumes after the install; Dart retries.
            val status = try {
                ArCoreApk.getInstance().requestInstall(act, true)
            } catch (e: Exception) {
                emitError("arcore-missing", e.message ?: "")
                result.success(null)
                return
            }
            if (status == ArCoreApk.InstallStatus.INSTALL_REQUESTED) {
                emitError("arcore-install-requested", "Installing Google Play Services for AR")
                result.success(null)
                return
            }
        }
        paused = false
        everTracked = false
        lastState = null
        sessionWanted.value = true
        updateRunning()
        emitTracking(ArTracking.INITIALIZING, "initializing")
        result.success(null)
    }

    /**
     * Ends the session: the camera and the GPU are released (the composable
     * leaves, SceneView destroys its engine) and every piece of drawing state
     * resets, so the next startSession is a clean slate. Tiles are unloaded
     * too: Dart's residency starts again from nothing after a stop.
     */
    private fun stopSession() {
        restoreRefreshRate()
        stopThermal()
        // Finish a debug recording before the session goes (autoStopOnPause
        // would too, but only once SceneView pauses it).
        if (recordTo != null && recordingStarted) stopRecording()
        recordTo = null
        torchOn = false
        scanOverlay.value = false
        lastScan = emptyMap()
        sessionWanted.value = false
        updateRunning()
        markers.reset()
        tiles.clear { e -> renderer?.removeTile(e.hash) }
        states.clear()
        modelCurrent = ArMath.identity()
        modelPlaced = false
        modelDirty = false
        renderer?.setPlaced(false, tiles.tiles.values)
        lastFloorY = null
        floorPlane = null
        easeDurNs = 0L
        layers = LayerState()
        targetIds = null
        targetBuild = null
        gridGlb = null
        pinGlb = null
        emitTracking(ArTracking.STOPPED, null)
    }

    private fun loadTiles(a: Map<*, *>, result: MethodChannel.Result) {
        val refs = (a["tiles"] as? List<*>).orEmpty().mapNotNull {
            val m = it as? Map<*, *> ?: return@mapNotNull null
            val h = m["hash"]?.toString() ?: return@mapNotNull null
            val p = m["path"]?.toString() ?: return@mapNotNull null
            h to p
        }
        tiles.load(
            refs,
            onEntry = { e ->
                states.gather(e)
                computeTargetLocals(e)
                upload(e)
            },
            done = { loaded, failed -> result.success(mapOf("loaded" to loaded, "failed" to failed)) },
        )
    }

    private fun buildPins(list: List<*>): ByteArray? {
        val data = ArrayList<Float>()
        val rgb = ArrayList<Int>()
        for (raw in list) {
            val m = raw as? Map<*, *> ?: continue
            val pos = Args.floats(m["posTile"] ?: m["pos"], 3) ?: continue
            val kind = m["kind"]?.toString() ?: "snag"
            val board = kind == "board" || kind == "ghostBoard"
            val normal = Args.floats(m["normalTile"], 3) ?: floatArrayOf(0f, 0f, 1f)
            val alpha = when (kind) {
                "ghostBoard" -> 0.45f
                "board" -> 0.85f
                else -> 1f
            }
            data += listOf(pos[0], pos[1], pos[2], normal[0], normal[1], normal[2], alpha, if (board) FeArCore.PIN_BOARD.toFloat() else FeArCore.PIN_MARKER.toFloat())
            rgb += Args.int(m["colorRgb"]) ?: PIN_COLOURS[kind] ?: 0xEF4444
        }
        if (data.isEmpty()) return null
        return FeArCore.nativeOverlayGlb(null, 0f, 0, data.toFloatArray(), rgb.toIntArray())
    }

    fun dispose() {
        stopSession()
        renderer?.destroy()
        renderer = null
        markers.close()
        tiles.shutdown()
        io.shutdownNow()
        detachActivity()
        sink = null
    }

    /** Tracking states (lib/core/ar/ar_engine.dart ArTracking). */
    private object ArTracking {
        const val INITIALIZING = "initializing"
        const val TRACKING = "tracking"
        const val LIMITED = "limited"
        const val PAUSED = "paused"
        const val STOPPED = "stopped"
        const val NOT_AVAILABLE = "notAvailable"
    }

    companion object {
        /** Flip to log `camera check` every 2 s in debuggable builds (P-012 tooling). */
        private const val CAMERA_CHECK_LOG = false

        private const val NEAR_M = 0.05f
        private const val FAR_M = 100f
        private const val POSE_INTERVAL_MS = 200L // 5 Hz (§6.4)
        private const val TARGET_INTERVAL_MS = 100L // 10 Hz (§6.4)
        private const val FLOOR_INTERVAL_MS = 1000L
        private const val SCAN_INTERVAL_MS = 1000L
        private const val REFOCUS_DELAY_MS = 150L
        /** A floor plane must be at least this big (a doormat is not the floor). */
        private const val FLOOR_MIN_AREA_M2 = 0.25f
        /** Camera height above the floor while standing: tables and beds sit higher than MIN below the phone. */
        private const val FLOOR_MIN_DROP_M = 0.8f
        private const val FLOOR_MAX_DROP_M = 2.3f
        /** Another plane replaces the current floor only when this much bigger. */
        private const val FLOOR_SWITCH_RATIO = 1.5f
        /** `planes` (Place by hand): at most this many, walls from this size. */
        private const val MAX_PLANES = 24
        private const val WALL_MIN_AREA_M2 = 0.15f

        /** GAMMA-style orange slab gridlines (design board TabSnap: #FB923C). */
        private const val GRID_RGB = 0xFB923C

        /** Default pin colours by ArPin.kind when Dart sends no colorRgb. */
        private val PIN_COLOURS = mapOf(
            "snag" to 0xEF4444,
            "finding" to 0xF59E0B,
            "clash" to 0xA855F7,
            "ghostBoard" to 0x38BDF8,
            "board" to 0x22C55E,
            "measure" to 0xF1F5F9,
        )
    }
}
