package com.fusionapps.fe_ar

import android.content.Context
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Recomposer
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.AndroidUiDispatcher
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.google.ar.core.Config
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.github.sceneview.*
import io.github.sceneview.ar.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Platform view type `fusioneco/ar/view` (CONTRACT C8). */
internal class FeArViewFactory(private val controller: FeArController) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        FeArPlatformView(context, controller, args as? Map<*, *>)
}

/**
 * The AR surface: a ComposeView hosting SceneView's ARSceneView composable
 * (SceneView 4.x is Compose-only). All UI is Flutter's; this view only shows
 * the camera and the model (docs/ar-bim-overlay.md §6.2, "native is
 * headless").
 *
 * FlutterActivity is not a ComponentActivity, so nothing above this view
 * provides the ViewTree lifecycle / saved-state / view-model owners Compose
 * requires. [ArViewOwner] provides them, and its lifecycle is what SceneView
 * resumes and pauses the ARCore session on: RESUMED only while the session
 * is wanted, not paused by Dart, and the activity is resumed.
 *
 * Creation params: `{"surface": "texture" | "surface"}`. "texture"
 * (default) renders into a TextureView, which composes under Flutter in every
 * platform-view mode; "surface" uses a SurfaceView, faster, but it needs
 * Hybrid Composition on the Dart side (PlatformViewLink +
 * initExpensiveAndroidView). Slice 0 (AR-3) measures both.
 */
internal class FeArPlatformView(
    context: Context,
    private val controller: FeArController,
    params: Map<*, *>?,
) : PlatformView {
    private val owner = ArViewOwner()
    val composeView = ComposeView(context)

    // Compose normally installs a "window recomposer" on the window's content
    // root and looks up its lifecycle there; under Flutter that root is
    // FlutterView, which has no ViewTreeLifecycleOwner ("ViewTreeLifecycleOwner
    // not found from FlutterView" on the first device run). A recomposer of our
    // own, set as the parent composition context, keeps Compose inside this view.
    private val recomposeScope = CoroutineScope(AndroidUiDispatcher.CurrentThread + SupervisorJob())
    private val recomposer = Recomposer(recomposeScope.coroutineContext)
    private val surfaceType = if (params?.get("surface") == "surface") SurfaceType.Surface else SurfaceType.TextureSurface

    init {
        owner.create()
        composeView.setViewTreeLifecycleOwner(owner)
        composeView.setViewTreeSavedStateRegistryOwner(owner)
        composeView.setViewTreeViewModelStoreOwner(owner)
        composeView.setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnLifecycleDestroyed(owner.lifecycle))
        recomposeScope.launch { recomposer.runRecomposeAndApplyChanges() }
        composeView.setParentCompositionContext(recomposer)
        composeView.setContent {
            if (controller.sessionWanted.value) {
                FeArScene(controller, owner.lifecycle, surfaceType)
            }
        }
        controller.attachView(this)
    }

    override fun getView(): View = composeView

    override fun dispose() {
        controller.detachView(this)
        composeView.disposeComposition()
        owner.destroy()
        recomposer.cancel()
        recomposeScope.cancel()
    }

    /** RESUMED runs the ARCore session; STARTED pauses it (camera released). */
    fun setRunning(running: Boolean) {
        owner.setState(if (running) Lifecycle.State.RESUMED else Lifecycle.State.STARTED)
    }

    /** The view SceneView renders into, for capture(). */
    fun findRenderSurface(): View? = find(composeView)

    private fun find(v: View): View? {
        if (v is TextureView || v is SurfaceView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) find(v.getChildAt(i))?.let { return it }
        }
        return null
    }
}

@Composable
private fun FeArScene(controller: FeArController, lifecycle: Lifecycle, surfaceType: SurfaceType) {
    val engine = rememberEngine()
    val scene = rememberScene(engine)
    // Our own handle on the AR camera node SceneView drives from each ARCore
    // frame, so the controller can check the rendered camera really follows
    // the phone (first device run: the model looked screen-locked).
    val cameraNode = rememberARCameraNode(engine)
    DisposableEffect(cameraNode) {
        controller.cameraNode = cameraNode
        onDispose { if (controller.cameraNode === cameraNode) controller.cameraNode = null }
    }
    // Created after the engine and scene, so disposed BEFORE them (Compose
    // forgets remembered objects in reverse order): the renderer destroys its
    // assets while the engine is still alive.
    // TODO(slice-0): confirm the disposal order on the pinned SceneView.
    DisposableEffect(engine, scene) {
        controller.onRendererReady(engine, scene)
        onDispose { controller.onRendererGone() }
    }
    ARSceneView(
        modifier = Modifier.fillMaxSize(),
        surfaceType = surfaceType,
        engine = engine,
        scene = scene,
        cameraNode = cameraNode,
        sessionCameraConfig = { session -> controller.pickCameraConfig(session) },
        playbackDataset = controller.playbackFile,
        planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL,
        depthMode = if (controller.wantDepth) Config.DepthMode.AUTOMATIC else Config.DepthMode.DISABLED,
        focusMode = Config.FocusMode.AUTO,
        sessionConfiguration = { session, config -> controller.configureSession(session, config) },
        planeRenderer = false,
        onSessionCreated = { controller.onSessionCreated(it) },
        onSessionResumed = { controller.onSessionResumed(it) },
        onSessionPaused = { controller.onSessionPaused(it) },
        onSessionFailed = { controller.onSessionFailed(it) },
        onSessionUpdated = { session, frame -> controller.onFrame(session, frame) },
        onTrackingFailureChanged = { /* read per frame in onFrame, with the tracking state */ },
        onGestureListener = null,
        onTouchEvent = null,
        // Flutter owns every pixel of UI: no SceneView permission prompts or
        // overlays. The app asks for the camera (permission_handler) and
        // capabilities() reports "camera-denied" until it has it.
        permissionHandler = null,
        cameraPermissionOverlay = null,
        arCoreAvailabilityOverlay = null,
        lifecycle = lifecycle,
    )
}

/**
 * Lifecycle, saved-state and view-model owner for the ComposeView, since the
 * Flutter host activity provides none of them to platform views.
 */
internal class ArViewOwner : LifecycleOwner, SavedStateRegistryOwner, ViewModelStoreOwner {
    private val registry = LifecycleRegistry(this)
    private val savedState = SavedStateRegistryController.create(this)
    private val store = ViewModelStore()

    override val lifecycle: Lifecycle get() = registry
    override val savedStateRegistry: SavedStateRegistry get() = savedState.savedStateRegistry
    override val viewModelStore: ViewModelStore get() = store

    fun create() {
        savedState.performAttach()
        savedState.performRestore(null)
        registry.currentState = Lifecycle.State.CREATED
        registry.currentState = Lifecycle.State.STARTED
    }

    fun setState(state: Lifecycle.State) {
        if (registry.currentState == Lifecycle.State.DESTROYED) return
        registry.currentState = state
    }

    fun destroy() {
        if (registry.currentState == Lifecycle.State.DESTROYED) return
        registry.currentState = Lifecycle.State.DESTROYED
        store.clear()
    }
}
