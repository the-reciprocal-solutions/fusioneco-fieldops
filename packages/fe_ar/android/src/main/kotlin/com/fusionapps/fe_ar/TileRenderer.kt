package com.fusionapps.fe_ar

import android.content.Context
import android.util.Log
import com.google.android.filament.Engine
import com.google.android.filament.EntityManager
import com.google.android.filament.Material
import com.google.android.filament.MaterialInstance
import com.google.android.filament.Scene
import com.google.android.filament.Texture
import com.google.android.filament.TextureSampler
import com.google.android.filament.gltfio.AssetLoader
import com.google.android.filament.gltfio.FilamentAsset
import com.google.android.filament.gltfio.FilamentInstance
import com.google.android.filament.gltfio.Gltfio
import com.google.android.filament.gltfio.ResourceLoader
import com.google.android.filament.gltfio.UbershaderProvider
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Everything Filament: the tiles, their materials, the feature state, layers,
 * section, opacity, the model root transform and the overlay (grid + pins).
 * Created when SceneView hands over its engine and scene, destroyed before
 * SceneView destroys them. Main thread only.
 *
 * Each tile is ONE gltfio asset with THREE instances that share its vertex
 * and index buffers (gltfio instancing): the solid pass, the ghost pass and
 * the x-ray pass of materials/fe_feature.mat. An instance whose mode has no
 * features in the tile is switched off with its layer mask, so a typical tile
 * costs one pass of draw calls, and only tiles holding the target pay for x-ray.
 *
 * If the compiled material (assets/fe_ar/fe_feature.filamat, see
 * tool/compile_materials.sh) is missing, tiles keep gltfio's own material,
 * tinted per layer: the documented fallback (docs/ar-bim-overlay.md §5.4).
 */
internal class TileRenderer(
    private val context: Context,
    val engine: Engine,
    private val scene: Scene,
) {
    private class Pass(val entities: IntArray, val renderables: IntArray, val materials: List<MaterialInstance>)

    private class GpuTile(
        val asset: FilamentAsset,
        val passes: List<Pass>,
        var stateTexture: Texture?,
        var stateTextureHeight: Int,
        var uploadedVersion: Int,
    )

    private val materialProvider: UbershaderProvider
    private val assetLoader: AssetLoader
    private val resourceLoader: ResourceLoader
    private val featureMaterial: Material?
    private val placeholder: Texture
    private val sampler = TextureSampler(
        TextureSampler.MinFilter.NEAREST,
        TextureSampler.MagFilter.NEAREST,
        TextureSampler.WrapMode.CLAMP_TO_EDGE,
    )
    val modelRoot: Int
    private val gpu = HashMap<String, GpuTile>()
    private var gridAsset: FilamentAsset? = null
    private var pinAsset: FilamentAsset? = null

    // Current draw parameters, applied to every new material instance too.
    private var layers = LayerState()
    private var sectionWorldY = 0f
    private var translationY = 0f

    /**
     * False until Dart sends the first model transform. Before that the root is
     * identity, which puts the model wherever the session started (the phone's
     * first pose): it read as "the overlay lands somewhere random" on the first
     * device run. Tiles, grid and pins stay loaded but hidden until placed.
     */
    private var placed = false

    val hasFeatureMaterial: Boolean get() = featureMaterial != null

    init {
        Gltfio.init() // idempotent; SceneView has usually done it already
        materialProvider = UbershaderProvider(engine)
        assetLoader = AssetLoader(engine, materialProvider, EntityManager.get())
        resourceLoader = ResourceLoader(engine)
        featureMaterial = loadMaterial("fe_ar/fe_feature.filamat")
        placeholder = Texture.Builder()
            .width(1)
            .height(1)
            .levels(1)
            .sampler(Texture.Sampler.SAMPLER_2D)
            .format(Texture.InternalFormat.SRGB8_A8)
            .build(engine)
        val px = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        px.put(byteArrayOf(0, 0, 0, 170.toByte()))
        px.flip()
        placeholder.setImage(engine, 0, Texture.PixelBufferDescriptor(px, Texture.Format.RGBA, Texture.Type.UBYTE))
        modelRoot = EntityManager.get().create()
        engine.transformManager.create(modelRoot)
        if (featureMaterial == null) {
            Log.w(TAG, "fe_feature.filamat not bundled: tiles use gltfio materials tinted per layer (no feature state, no section)")
        }
    }

    private fun loadMaterial(asset: String): Material? = try {
        context.assets.open(asset).use { input ->
            val bytes = input.readBytes()
            val buf = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
            buf.put(bytes)
            buf.flip()
            Material.Builder().payload(buf, buf.remaining()).build(engine)
        }
    } catch (e: Exception) {
        null
    }

    // ------------------------------------------------------------------ tiles

    fun hasTile(hash: String) = gpu.containsKey(hash)

    /** Uploads a decoded tile. [bytes] must be the tile's GLB in a direct buffer. */
    fun addTile(entry: TileEntry, bytes: ByteBuffer): Boolean {
        if (gpu.containsKey(entry.hash)) return true
        val passCount = if (featureMaterial != null) 3 else 1
        // TODO(slice-0): confirm the instances share one vertex/index buffer
        // (gltfio instancing) and that replacing each instance's material
        // instances leaves the others untouched.
        val instances = arrayOfNulls<FilamentInstance>(passCount)
        val asset = assetLoader.createInstancedAsset(bytes, instances) ?: return false
        resourceLoader.loadResources(asset)
        asset.releaseSourceData()

        val tcm = engine.transformManager
        val rcm = engine.renderableManager
        val rootInstance = tcm.getInstance(modelRoot)
        val passes = ArrayList<Pass>(passCount)
        for (p in 0 until passCount) {
            val inst = instances[p] ?: continue
            tcm.setParent(tcm.getInstance(inst.root), rootInstance)
            val renderables = inst.entities.filter { rcm.hasComponent(it) }.toIntArray()
            val mats = ArrayList<MaterialInstance>()
            for (e in renderables) {
                val ri = rcm.getInstance(e)
                rcm.setPriority(ri, PASS_PRIORITY[p])
                rcm.setCastShadows(ri, false)
                rcm.setReceiveShadows(ri, false)
                val prims = rcm.getPrimitiveCount(ri)
                for (k in 0 until prims) {
                    if (featureMaterial != null) {
                        val mi = featureMaterial.createInstance()
                        configure(mi, entry, p)
                        rcm.setMaterialInstanceAt(ri, k, mi)
                        mats += mi
                    } else if (entry.layer != "mep") {
                        // Fallback without fe_feature.filamat: MEP keeps the
                        // tile's own per-discipline colour (the server bakes
                        // it); only architecture and structure get the layer tint.
                        val c = LayerStyle.of(entry.layer).color
                        rcm.getMaterialInstanceAt(ri, k).setParameter("baseColorFactor", c[0], c[1], c[2], c[3])
                    }
                }
            }
            scene.addEntities(inst.entities)
            passes += Pass(inst.entities, renderables, mats)
        }
        gpu[entry.hash] = GpuTile(asset, passes, null, 0, -1)
        syncTile(entry)
        return true
    }

    fun removeTile(hash: String) {
        val t = gpu.remove(hash) ?: return
        for (p in t.passes) scene.removeEntities(p.entities)
        assetLoader.destroyAsset(t.asset) // destroys the renderables before their material instances go
        for (p in t.passes) for (mi in p.materials) engine.destroyMaterialInstance(mi)
        t.stateTexture?.let { engine.destroyTexture(it) }
    }

    private fun configure(mi: MaterialInstance, entry: TileEntry, pass: Int) {
        val style = LayerStyle.of(entry.layer)
        val c = style.color
        mi.setParameter("layerColor", c[0], c[1], c[2], c[3])
        mi.setParameter("ghostAlpha", style.ghostAlpha)
        mi.setParameter("highlightColor", HIGHLIGHT[0], HIGHLIGHT[1], HIGHLIGHT[2], 1f)
        mi.setParameter("opacity", layers.opacity)
        mi.setParameter("sectionEnabled", if (layers.sectionY != null) 1f else 0f)
        mi.setParameter("sectionWorldY", sectionWorldY)
        mi.setParameter("pass", pass.toFloat())
        mi.setParameter("isLines", if (style.lines) 1f else 0f)
        mi.setParameter("time", 0f)
        mi.setParameter("stateEnabled", 0f)
        mi.setParameter("stateWidth", FeatureStates.STATE_WIDTH.toFloat())
        mi.setParameter("featureState", placeholder, sampler)
        when (pass) {
            PASS_SOLID -> mi.setDepthWrite(style.writesDepth)
            PASS_GHOST -> mi.setDepthWrite(false)
            else -> {
                mi.setDepthWrite(false)
                mi.setDepthCulling(false)
            }
        }
    }

    /** Uploads the tile's gathered feature state and sets pass visibility. */
    fun syncTile(entry: TileEntry) {
        val t = gpu[entry.hash] ?: return
        val bytes = entry.stateBytes
        if (featureMaterial != null && bytes != null && t.uploadedVersion != entry.stateVersion) {
            if (t.stateTexture == null || t.stateTextureHeight != entry.stateHeight) {
                t.stateTexture?.let { engine.destroyTexture(it) }
                t.stateTexture = Texture.Builder()
                    .width(FeatureStates.STATE_WIDTH)
                    .height(entry.stateHeight)
                    .levels(1)
                    .sampler(Texture.Sampler.SAMPLER_2D)
                    .format(Texture.InternalFormat.SRGB8_A8)
                    .build(engine)
                t.stateTextureHeight = entry.stateHeight
                for (p in t.passes) for (mi in p.materials) {
                    mi.setParameter("featureState", t.stateTexture!!, sampler)
                    mi.setParameter("stateEnabled", 1f)
                }
            }
            // A fresh buffer per upload: Filament reads it asynchronously.
            val copy = ByteBuffer.allocateDirect(bytes.capacity()).order(ByteOrder.nativeOrder())
            val src = bytes.duplicate()
            src.position(0)
            copy.put(src)
            copy.flip()
            t.stateTexture!!.setImage(engine, 0, Texture.PixelBufferDescriptor(copy, Texture.Format.RGBA, Texture.Type.UBYTE))
            t.uploadedVersion = entry.stateVersion
        }
        applyVisibility(entry, t)
    }

    private fun applyVisibility(entry: TileEntry, t: GpuTile) {
        val rcm = engine.renderableManager
        val layerOn = placed && layers.visible(entry.layer)
        for ((p, pass) in t.passes.withIndex()) {
            val on = layerOn && when {
                featureMaterial == null -> p == PASS_SOLID
                p == PASS_SOLID -> entry.countNormal + entry.countHighlight > 0
                p == PASS_GHOST -> entry.countGhost > 0
                else -> entry.countHighlight > 0
            }
            for (e in pass.renderables) rcm.setLayerMask(rcm.getInstance(e), 0xff, if (on) 0x01 else 0x00)
        }
    }

    // -------------------------------------------------------- global state

    fun setLayers(state: LayerState, entries: Collection<TileEntry>) {
        layers = state
        updateSection()
        for (t in gpu.values) for (p in t.passes) for (mi in p.materials) {
            mi.setParameter("opacity", state.opacity)
            mi.setParameter("sectionEnabled", if (state.sectionY != null) 1f else 0f)
            mi.setParameter("sectionWorldY", sectionWorldY)
        }
        for (e in entries) gpu[e.hash]?.let { applyVisibility(e, it) }
        setOverlayVisible(state)
    }

    /** Applies the (eased) model transform to the root every tile hangs from. */
    fun setModelMatrix(m: FloatArray) {
        val tcm = engine.transformManager
        tcm.setTransform(tcm.getInstance(modelRoot), m)
        if (kotlin.math.abs(m[13] - translationY) > 1e-4f) {
            translationY = m[13]
            if (layers.sectionY != null) {
                updateSection()
                for (t in gpu.values) for (p in t.passes) for (mi in p.materials) mi.setParameter("sectionWorldY", sectionWorldY)
            }
        }
    }

    private fun updateSection() {
        // user-world Y = tile Y + the fit's vertical translation (yaw-only fit)
        sectionWorldY = (layers.sectionY ?: 0f) + translationY
    }

    /** Drives the x-ray pulse; only the tiles holding a highlight pay for it. */
    fun tick(seconds: Float, entries: Collection<TileEntry>) {
        if (featureMaterial == null) return
        for (e in entries) {
            if (e.countHighlight == 0) continue
            val t = gpu[e.hash] ?: continue
            val xray = t.passes.getOrNull(PASS_XRAY) ?: continue
            for (mi in xray.materials) mi.setParameter("time", seconds)
        }
    }

    // ------------------------------------------------------------ overlay

    fun setGrid(glb: ByteArray?) {
        gridAsset = replaceOverlay(gridAsset, glb)
        setOverlayVisible(layers)
    }

    fun setPins(glb: ByteArray?) {
        pinAsset = replaceOverlay(pinAsset, glb)
        setOverlayVisible(layers)
    }

    /** Shows or hides everything under the model root (see [placed]). */
    fun setPlaced(value: Boolean, entries: Collection<TileEntry>) {
        if (placed == value) return
        placed = value
        for (e in entries) gpu[e.hash]?.let { applyVisibility(e, it) }
        setOverlayVisible(layers)
    }

    private fun replaceOverlay(old: FilamentAsset?, glb: ByteArray?): FilamentAsset? {
        if (old != null) {
            scene.removeEntities(old.entities)
            assetLoader.destroyAsset(old)
        }
        if (glb == null) return null
        val buf = ByteBuffer.allocateDirect(glb.size).order(ByteOrder.nativeOrder())
        buf.put(glb)
        buf.flip()
        val asset = assetLoader.createAsset(buf) ?: return null
        resourceLoader.loadResources(asset)
        asset.releaseSourceData()
        val tcm = engine.transformManager
        val rcm = engine.renderableManager
        tcm.setParent(tcm.getInstance(asset.root), tcm.getInstance(modelRoot))
        for (e in asset.entities) {
            if (!rcm.hasComponent(e)) continue
            val ri = rcm.getInstance(e)
            rcm.setPriority(ri, 5)
            rcm.setCastShadows(ri, false)
            rcm.setReceiveShadows(ri, false)
        }
        scene.addEntities(asset.entities)
        return asset
    }

    private fun setOverlayVisible(state: LayerState) {
        val rcm = engine.renderableManager
        // the grid is a structural guide: it follows the structure toggle
        gridAsset?.let { grid ->
            for (e in grid.entities) {
                if (rcm.hasComponent(e)) rcm.setLayerMask(rcm.getInstance(e), 0xff, if (placed && state.grid) 0x01 else 0x00)
            }
        }
        pinAsset?.let { pins ->
            for (e in pins.entities) {
                if (rcm.hasComponent(e)) rcm.setLayerMask(rcm.getInstance(e), 0xff, if (placed) 0x01 else 0x00)
            }
        }
    }

    fun destroy() {
        for (h in gpu.keys.toList()) removeTile(h)
        replaceOverlay(gridAsset, null)
        replaceOverlay(pinAsset, null)
        gridAsset = null
        pinAsset = null
        engine.destroyTexture(placeholder)
        featureMaterial?.let { engine.destroyMaterial(it) }
        engine.transformManager.destroy(modelRoot)
        EntityManager.get().destroy(modelRoot)
        assetLoader.destroy()
        resourceLoader.destroy()
        materialProvider.destroyMaterials()
        materialProvider.destroy()
    }

    companion object {
        private const val TAG = "fe_ar"
        const val PASS_SOLID = 0
        const val PASS_GHOST = 1
        const val PASS_XRAY = 2

        /** Draw order among translucent passes: solids, then ghosts, overlay (5), x-ray last. */
        private val PASS_PRIORITY = intArrayOf(2, 4, 6)

        /** Default highlight (design: indigo #6366F1) when the texel carries no tint. */
        private val HIGHLIGHT = floatArrayOf(ArMath.srgbToLinear(0x63), ArMath.srgbToLinear(0x66), ArMath.srgbToLinear(0xF1))
    }
}

/** Layer toggles, opacity and section, as Dart's LayerState sends them. */
internal data class LayerState(
    val mep: Boolean = true,
    val structure: Boolean = true,
    val architecture: Boolean = true,
    val opacity: Float = 1f,
    val sectionY: Float? = null,
    val grid: Boolean = true,
) {
    fun visible(layer: String): Boolean = when (layer) {
        "structure" -> structure
        "architecture" -> architecture
        else -> mep // "mep" and anything unknown
    }
}

/**
 * Per-layer look (docs/ar-bim-overlay.md §6.6; colours from the design
 * boards: MEP cyan #22D3EE, architecture edges sky #38BDF8, structure a faint
 * slate). Colour is linear RGB + the "normal" mode alpha.
 */
internal class LayerStyle(val color: FloatArray, val ghostAlpha: Float, val lines: Boolean, val writesDepth: Boolean) {
    companion object {
        private fun rgb(hex: Int, a: Float) = floatArrayOf(
            ArMath.srgbToLinear((hex shr 16) and 0xff),
            ArMath.srgbToLinear((hex shr 8) and 0xff),
            ArMath.srgbToLinear(hex and 0xff),
            a,
        )

        // 0.88: MEP is what people came to see; 0.62 read washed out over a
        // bright room on the first device run. Dart tints it per discipline.
        private val MEP = LayerStyle(rgb(0x22D3EE, 0.88f), 0.16f, lines = false, writesDepth = true)
        private val STRUCTURE = LayerStyle(rgb(0xCBD5E1, 0.26f), 0.10f, lines = false, writesDepth = false)
        private val ARCHITECTURE = LayerStyle(rgb(0x38BDF8, 0.90f), 0.35f, lines = true, writesDepth = false)

        fun of(layer: String): LayerStyle = when (layer) {
            "structure" -> STRUCTURE
            "architecture" -> ARCHITECTURE
            else -> MEP
        }
    }
}
