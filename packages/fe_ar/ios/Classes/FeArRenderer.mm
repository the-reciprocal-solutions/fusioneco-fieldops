// FeArRenderer.mm: see FeArRenderer.h.
//
// Checked with `clang++ -fsyntax-only -std=c++20` against Filament 1.72.1's
// public headers on 2026-09-26 (UIKit stubbed; only the build-generated
// gltfio/materials/uberarchive.h was stubbed). Runtime behaviour is what
// slice 0 still has to prove: see the TODO(slice-0) notes. The structure is
// hello-ar's; the tile handling mirrors android/.../TileRenderer.kt line for
// line, so a fix in one belongs in the other.
#import "FeArRenderer.h"

#include <filament/Camera.h>
#include <filament/ColorGrading.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/SwapChain.h>
#include <filament/Texture.h>
#include <filament/TextureSampler.h>
#include <filament/ToneMapper.h>
#include <filament/TransformManager.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <filament/Viewport.h>

#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/FilamentInstance.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/materials/uberarchive.h>

#include <math/half.h>
#include <math/mat3.h>
#include <math/mat4.h>
#include <math/vec4.h>
#include <utils/EntityManager.h>

#include <cmath>
#include <map>
#include <string>
#include <vector>

using namespace filament;
using namespace filament::math;
using namespace filament::gltfio;
using utils::Entity;
using utils::EntityManager;

namespace {

constexpr int kPassSolid = 0;
constexpr int kPassGhost = 1;
constexpr int kPassXray = 2;
constexpr uint8_t kPassPriority[3] = {2, 4, 6};
constexpr int kStateWidth = 256;
// Layer bits: every model renderable (tiles, grid, pins; gltfio's default
// mask) is on kLayerModel, the camera triangle on kLayerCamera. setPlaced
// flips the view's visible layers, so hiding the unplaced model never
// touches the per-tile pass masks applyVisibility owns.
constexpr uint8_t kLayerModel = 0x01;
constexpr uint8_t kLayerCamera = 0x02;

struct Pass {
    std::vector<Entity> entities;
    std::vector<Entity> renderables;
    std::vector<MaterialInstance*> materials;
};

struct GpuTile {
    FilamentAsset* asset = nullptr;
    std::vector<Pass> passes;
    Texture* state = nullptr;
    int stateHeight = 0;
    long version = -1;
    std::string layer;
    long highlight = 0;
};

float srgbToLinear(int c) {
    const double x = c / 255.0;
    return (float)(x <= 0.04045 ? x / 12.92 : std::pow((x + 0.055) / 1.055, 2.4));
}

float4 linearRgb(uint32_t hex, float a) {
    return float4{srgbToLinear((hex >> 16) & 0xff), srgbToLinear((hex >> 8) & 0xff), srgbToLinear(hex & 0xff), a};
}

// Per-layer look, as android/.../TileRenderer.kt LayerStyle (design colours).
struct LayerLook {
    float4 color;
    float ghostAlpha;
    bool lines;
    bool writesDepth;
};

// Sunlight mode (setLayers extra `contrast`), as Android LayerStyle *_SUN:
// opaque MEP, white architecture edges, stronger structure and ghosts. MEP
// normal alpha 0.88 matches Android (was 0.62: washed out in a bright room).
LayerLook lookFor(const std::string& layer, bool contrast = false) {
    if (layer == "structure")
        return contrast ? LayerLook{linearRgb(0xE2E8F0, 0.45f), 0.20f, false, false}
                        : LayerLook{linearRgb(0xCBD5E1, 0.26f), 0.10f, false, false};
    if (layer == "architecture")
        return contrast ? LayerLook{linearRgb(0xFFFFFF, 1.0f), 0.55f, true, false}
                        : LayerLook{linearRgb(0x38BDF8, 0.90f), 0.35f, true, false};
    return contrast ? LayerLook{linearRgb(0x22D3EE, 1.0f), 0.30f, false, true}
                    : LayerLook{linearRgb(0x22D3EE, 0.88f), 0.16f, false, true};
}

struct CamVertex {
    half4 position;
    half2 uv;
};

// hello-ar's full-screen triangle (device domain).
const CamVertex kCamVertices[3] = {
    {{-1.0_h, -1.0_h, 1.0_h, 1.0_h}, {0.0_h, 1.0_h}},
    {{3.0_h, -1.0_h, 1.0_h, 1.0_h}, {2.0_h, 1.0_h}},
    {{-1.0_h, 3.0_h, 1.0_h, 1.0_h}, {0.0_h, -1.0_h}},
};
const uint16_t kCamIndices[3] = {0, 1, 2};

mat4f toMat4f(simd_float4x4 m) {
    return mat4f(m.columns[0][0], m.columns[0][1], m.columns[0][2], m.columns[0][3],
                 m.columns[1][0], m.columns[1][1], m.columns[1][2], m.columns[1][3],
                 m.columns[2][0], m.columns[2][1], m.columns[2][2], m.columns[2][3],
                 m.columns[3][0], m.columns[3][1], m.columns[3][2], m.columns[3][3]);
}

mat4 toMat4(simd_float4x4 m) {
    return mat4(m.columns[0][0], m.columns[0][1], m.columns[0][2], m.columns[0][3],
                m.columns[1][0], m.columns[1][1], m.columns[1][2], m.columns[1][3],
                m.columns[2][0], m.columns[2][1], m.columns[2][2], m.columns[2][3],
                m.columns[3][0], m.columns[3][1], m.columns[3][2], m.columns[3][3]);
}

struct CaptureRequest {
    void* block; // CFBridgingRetain'd completion
    uint32_t width;
    uint32_t height;
};

}  // namespace

@implementation FeArRenderer {
    Engine* _engine;
    SwapChain* _swapChain;
    Renderer* _renderer;
    Scene* _scene;
    View* _view;
    Camera* _camera;
    Entity _cameraEntity;
    ColorGrading* _colorGrading;

    MaterialProvider* _materialProvider;
    AssetLoader* _assetLoader;
    ResourceLoader* _resourceLoader;
    Material* _featureMaterial;
    Texture* _placeholder;
    TextureSampler _sampler;
    Entity _modelRoot;

    // camera feed
    Material* _cameraMaterial;
    MaterialInstance* _cameraInstance;
    Texture* _cameraTexture;
    VertexBuffer* _cameraVertices;
    IndexBuffer* _cameraIndices;
    Entity _cameraTriangle;

    std::map<std::string, GpuTile> _tiles;
    FilamentAsset* _grid;
    FilamentAsset* _pins;

    float _opacity;
    bool _contrast;
    bool _sectionEnabled;
    float _sectionY;
    float _translationY;
    NSMutableArray* _captureQueue;
}

- (nullable instancetype)initWithLayer:(CAMetalLayer*)layer {
    if (!(self = [super init])) return nil;
    _engine = Engine::create(Engine::Backend::METAL);
    if (!_engine) return nil;
    _opacity = 1.0f;
    _sectionEnabled = false;
    _sectionY = 0;
    _translationY = 0;
    _grid = nullptr;
    _pins = nullptr;
    _captureQueue = [NSMutableArray new];
    _sampler = TextureSampler(TextureSampler::MinFilter::NEAREST, TextureSampler::MagFilter::NEAREST);

    NSData* featureMat = [self materialNamed:@"fe_feature"];
    NSData* cameraMat = [self materialNamed:@"fe_camera_feed"];
    _drawsCamera = cameraMat != nil;

    // Without the camera material the model is drawn over a transparent
    // background and the view shows the camera beneath (Core Image).
    layer.opaque = _drawsCamera;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _swapChain = _engine->createSwapChain((__bridge void*)layer, _drawsCamera ? 0 : SwapChain::CONFIG_TRANSPARENT);
    _renderer = _engine->createRenderer();
    Renderer::ClearOptions clear;
    clear.clearColor = {0.0f, 0.0f, 0.0f, 0.0f};
    clear.clear = true;
    _renderer->setClearOptions(clear);

    _scene = _engine->createScene();
    _view = _engine->createView();
    _cameraEntity = EntityManager::get().create();
    _camera = _engine->createCamera(_cameraEntity);
    _view->setScene(_scene);
    _view->setCamera(_camera);
    _view->setShadowingEnabled(false);
    _view->setVisibleLayers(0xff, kLayerCamera); // unplaced: camera only
    if (!_drawsCamera) _view->setBlendMode(View::BlendMode::TRANSLUCENT);
    // LINEAR tone mapping: overlay colours come out exactly as Dart asked
    // (fe_camera_feed.mat decodes the camera from sRGB to match).
    LinearToneMapper linear;
    _colorGrading = ColorGrading::Builder().toneMapper(&linear).build(*_engine);
    _view->setColorGrading(_colorGrading);

    _materialProvider = createUbershaderProvider(_engine, UBERARCHIVE_DEFAULT_DATA, UBERARCHIVE_DEFAULT_SIZE);
    AssetConfiguration assetConfig = {};
    assetConfig.engine = _engine;
    assetConfig.materials = _materialProvider;
    assetConfig.entities = &EntityManager::get();
    _assetLoader = AssetLoader::create(assetConfig);
    ResourceConfiguration resourceConfig = {};
    resourceConfig.engine = _engine;
    resourceConfig.normalizeSkinningWeights = true;
    _resourceLoader = new ResourceLoader(resourceConfig);

    _featureMaterial = featureMat ? Material::Builder().package(featureMat.bytes, featureMat.length).build(*_engine) : nullptr;
    _hasFeatureMaterial = _featureMaterial != nullptr;
    if (!_featureMaterial) {
        NSLog(@"fe_ar: fe_feature.filamat not bundled; tiles use gltfio materials tinted per layer");
    }

    _placeholder = Texture::Builder()
                       .width(1)
                       .height(1)
                       .levels(1)
                       .sampler(Texture::Sampler::SAMPLER_2D)
                       .format(Texture::InternalFormat::SRGB8_A8)
                       .build(*_engine);
    uint8_t* px = (uint8_t*)malloc(4);
    px[0] = px[1] = px[2] = 0;
    px[3] = 170;
    _placeholder->setImage(*_engine, 0,
                           Texture::PixelBufferDescriptor(px, 4, Texture::Format::RGBA, Texture::Type::UBYTE,
                                                          [](void* buf, size_t, void*) { free(buf); }));

    _modelRoot = EntityManager::get().create();
    _engine->getTransformManager().create(_modelRoot);

    if (cameraMat) [self setUpCameraFeed:cameraMat];
    return self;
}

- (nullable NSData*)materialNamed:(NSString*)name {
    NSBundle* bundle = [NSBundle bundleForClass:[FeArRenderer class]];
    NSURL* assets = [bundle URLForResource:@"fe_ar_assets" withExtension:@"bundle"];
    NSBundle* res = assets ? [NSBundle bundleWithURL:assets] : bundle;
    NSURL* url = [res URLForResource:name withExtension:@"filamat"];
    return url ? [NSData dataWithContentsOfURL:url] : nil;
}

- (void)setUpCameraFeed:(NSData*)package {
    _cameraMaterial = Material::Builder().package(package.bytes, package.length).build(*_engine);
    _cameraTexture = Texture::Builder().levels(1).sampler(Texture::Sampler::SAMPLER_EXTERNAL).build(*_engine);
    _cameraVertices = VertexBuffer::Builder()
                          .vertexCount(3)
                          .bufferCount(1)
                          .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::HALF4, offsetof(CamVertex, position), sizeof(CamVertex))
                          .attribute(VertexAttribute::UV0, 0, VertexBuffer::AttributeType::HALF2, offsetof(CamVertex, uv), sizeof(CamVertex))
                          .build(*_engine);
    _cameraVertices->setBufferAt(*_engine, 0, VertexBuffer::BufferDescriptor(kCamVertices, sizeof(kCamVertices), nullptr));
    _cameraIndices = IndexBuffer::Builder().indexCount(3).bufferType(IndexBuffer::IndexType::USHORT).build(*_engine);
    _cameraIndices->setBuffer(*_engine, IndexBuffer::BufferDescriptor(kCamIndices, sizeof(kCamIndices), nullptr));
    _cameraTriangle = EntityManager::get().create();
    _cameraInstance = _cameraMaterial->createInstance();
    RenderableManager::Builder(1)
        .material(0, _cameraInstance)
        .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, _cameraVertices, _cameraIndices)
        .culling(false)
        .castShadows(false)
        .receiveShadows(false)
        .priority(0)
        .layerMask(0xff, kLayerCamera)
        .build(*_engine, _cameraTriangle);
    _cameraInstance->setParameter("cameraFeed", _cameraTexture, TextureSampler());
    _scene->addEntity(_cameraTriangle);
}

- (void)dealloc {
    for (auto& kv : _tiles) [self destroyTile:kv.second];
    _tiles.clear();
    [self replaceOverlay:&_grid with:nil];
    [self replaceOverlay:&_pins with:nil];
    if (_cameraMaterial) {
        _scene->remove(_cameraTriangle);
        _engine->destroy(_cameraTriangle);
        EntityManager::get().destroy(_cameraTriangle);
        _engine->destroy(_cameraInstance);
        _engine->destroy(_cameraMaterial);
        _engine->destroy(_cameraTexture);
        _engine->destroy(_cameraVertices);
        _engine->destroy(_cameraIndices);
    }
    _engine->destroy(_placeholder);
    if (_featureMaterial) _engine->destroy(_featureMaterial);
    _engine->getTransformManager().destroy(_modelRoot);
    EntityManager::get().destroy(_modelRoot);
    AssetLoader::destroy(&_assetLoader);
    delete _resourceLoader;
    _materialProvider->destroyMaterials();
    delete _materialProvider;
    _engine->destroy(_colorGrading);
    _engine->destroyCameraComponent(_cameraEntity);
    EntityManager::get().destroy(_cameraEntity);
    _engine->destroy(_view);
    _engine->destroy(_scene);
    _engine->destroy(_renderer);
    _engine->destroy(_swapChain);
    Engine::destroy(&_engine);
}

// ------------------------------------------------------------------ frame

- (void)renderFrame:(nullable CVPixelBufferRef)cameraImage
    textureTransform:(simd_float3x3)textureTransform
          projection:(simd_float4x4)projection
         cameraModel:(simd_float4x4)cameraModel
        drawableSize:(CGSize)drawableSize
             seconds:(double)seconds {
    if (drawableSize.width < 1 || drawableSize.height < 1) return;
    if (_cameraMaterial && cameraImage) {
        // Filament retains the pixel buffer until the GPU is done with it (hello-ar).
        // TODO(slice-0): move to the ExternalImageHandleRef overload; this one is deprecated.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _cameraTexture->setExternalImage(*_engine, (void*)cameraImage);
#pragma clang diagnostic pop
        const simd_float3x3 t = textureTransform;
        _cameraInstance->setParameter("textureTransform",
                                      mat3f(t.columns[0][0], t.columns[0][1], t.columns[0][2],
                                            t.columns[1][0], t.columns[1][1], t.columns[1][2],
                                            t.columns[2][0], t.columns[2][1], t.columns[2][2]));
    }
    _view->setViewport(Viewport(0, 0, (uint32_t)drawableSize.width, (uint32_t)drawableSize.height));
    _camera->setCustomProjection(toMat4(projection), 0.05, 100.0);
    _camera->setModelMatrix(toMat4f(cameraModel));

    // x-ray pulse, only on tiles that hold a highlight
    if (_featureMaterial) {
        for (auto& kv : _tiles) {
            if (kv.second.highlight <= 0 || kv.second.passes.size() <= kPassXray) continue;
            for (MaterialInstance* mi : kv.second.passes[kPassXray].materials) mi->setParameter("time", (float)seconds);
        }
    }

    if (_renderer->beginFrame(_swapChain)) {
        _renderer->render(_view);
        if (_captureQueue.count > 0) [self readPixels:drawableSize];
        _renderer->endFrame();
    }
}

- (void)captureNextFrame:(void (^)(UIImage* _Nullable))completion {
    [_captureQueue addObject:[completion copy]];
}

- (void)readPixels:(CGSize)size {
    void (^completion)(UIImage*) = _captureQueue.firstObject;
    [_captureQueue removeObjectAtIndex:0];
    const uint32_t w = (uint32_t)size.width, h = (uint32_t)size.height;
    const size_t bytes = (size_t)w * h * 4;
    uint8_t* buffer = (uint8_t*)malloc(bytes);
    CaptureRequest* req = new CaptureRequest{(void*)CFBridgingRetain(completion), w, h};
    backend::PixelBufferDescriptor pbd(
        buffer, bytes, backend::PixelDataFormat::RGBA, backend::PixelDataType::UBYTE,
        [](void* buf, size_t, void* user) {
            CaptureRequest* r = (CaptureRequest*)user;
            void (^done)(UIImage*) = (void (^)(UIImage*))CFBridgingRelease(r->block);
            const uint32_t width = r->width, height = r->height;
            delete r;
            // Filament's origin is bottom-left: flip rows into a CGImage.
            const size_t row = (size_t)width * 4;
            uint8_t* flipped = (uint8_t*)malloc(row * height);
            for (uint32_t y = 0; y < height; y++) memcpy(flipped + y * row, (uint8_t*)buf + (height - 1 - y) * row, row);
            free(buf);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(flipped, width, height, 8, row, cs, kCGImageAlphaPremultipliedLast);
            CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
            UIImage* image = img ? [UIImage imageWithCGImage:img] : nil;
            if (img) CGImageRelease(img);
            if (ctx) CGContextRelease(ctx);
            CGColorSpaceRelease(cs);
            free(flipped);
            dispatch_async(dispatch_get_main_queue(), ^{
              done(image);
            });
        },
        req);
    _renderer->readPixels(0, 0, w, h, std::move(pbd));
}

// ------------------------------------------------------------------ tiles

- (BOOL)hasTile:(NSString*)hash {
    return _tiles.count(hash.UTF8String) > 0;
}

- (BOOL)addTile:(NSString*)hash data:(NSData*)glb layer:(NSString*)layer {
    const std::string key = hash.UTF8String;
    if (_tiles.count(key)) return YES;
    const size_t passCount = _featureMaterial ? 3 : 1;
    std::vector<FilamentInstance*> instances(passCount, nullptr);
    FilamentAsset* asset =
        _assetLoader->createInstancedAsset((const uint8_t*)glb.bytes, (uint32_t)glb.length, instances.data(), passCount);
    if (!asset) return NO;
    _resourceLoader->loadResources(asset);
    asset->releaseSourceData();

    GpuTile tile;
    tile.asset = asset;
    tile.layer = layer.UTF8String;
    const LayerLook look = lookFor(tile.layer, _contrast);
    auto& tcm = _engine->getTransformManager();
    auto& rcm = _engine->getRenderableManager();
    for (size_t p = 0; p < passCount; p++) {
        FilamentInstance* inst = instances[p];
        Pass pass;
        if (!inst) {
            tile.passes.push_back(pass);
            continue;
        }
        tcm.setParent(tcm.getInstance(inst->getRoot()), tcm.getInstance(_modelRoot));
        const Entity* ents = inst->getEntities();
        const size_t n = inst->getEntityCount();
        for (size_t i = 0; i < n; i++) {
            pass.entities.push_back(ents[i]);
            if (!rcm.hasComponent(ents[i])) continue;
            pass.renderables.push_back(ents[i]);
            auto ri = rcm.getInstance(ents[i]);
            rcm.setPriority(ri, kPassPriority[p]);
            rcm.setCastShadows(ri, false);
            rcm.setReceiveShadows(ri, false);
            const size_t prims = rcm.getPrimitiveCount(ri);
            for (size_t k = 0; k < prims; k++) {
                if (_featureMaterial) {
                    MaterialInstance* mi = _featureMaterial->createInstance();
                    [self configure:mi look:look pass:(int)p];
                    rcm.setMaterialInstanceAt(ri, k, mi);
                    pass.materials.push_back(mi);
                } else {
                    rcm.getMaterialInstanceAt(ri, k)->setParameter("baseColorFactor", look.color);
                }
            }
        }
        _scene->addEntities(pass.entities.data(), pass.entities.size());
        tile.passes.push_back(pass);
    }
    _tiles[key] = tile;
    // default: everything "normal" until the first state arrives
    [self applyVisibility:_tiles[key] normal:1 ghost:0 highlight:0 layerVisible:YES];
    return YES;
}

- (void)configure:(MaterialInstance*)mi look:(const LayerLook&)look pass:(int)pass {
    mi->setParameter("layerColor", look.color);
    mi->setParameter("ghostAlpha", look.ghostAlpha);
    const float4 hl = linearRgb(0x6366F1, 1.0f); // design indigo
    mi->setParameter("highlightColor", hl);
    mi->setParameter("opacity", _opacity);
    mi->setParameter("sectionEnabled", _sectionEnabled ? 1.0f : 0.0f);
    mi->setParameter("sectionWorldY", _sectionY + _translationY);
    mi->setParameter("pass", (float)pass);
    mi->setParameter("isLines", look.lines ? 1.0f : 0.0f);
    mi->setParameter("time", 0.0f);
    mi->setParameter("stateEnabled", 0.0f);
    mi->setParameter("stateWidth", (float)kStateWidth);
    mi->setParameter("featureState", _placeholder, _sampler);
    if (pass == kPassSolid) {
        mi->setDepthWrite(look.writesDepth);
    } else if (pass == kPassGhost) {
        mi->setDepthWrite(false);
    } else {
        mi->setDepthWrite(false);
        mi->setDepthCulling(false);
    }
}

- (void)destroyTile:(GpuTile&)t {
    for (auto& p : t.passes) _scene->removeEntities(p.entities.data(), p.entities.size());
    _assetLoader->destroyAsset(t.asset);  // renderables go before their material instances
    for (auto& p : t.passes)
        for (MaterialInstance* mi : p.materials) _engine->destroy(mi);
    if (t.state) _engine->destroy(t.state);
}

- (void)removeTile:(NSString*)hash {
    auto it = _tiles.find(hash.UTF8String);
    if (it == _tiles.end()) return;
    [self destroyTile:it->second];
    _tiles.erase(it);
}

- (void)syncTile:(NSString*)hash
           state:(nullable NSData*)rgba
     stateHeight:(NSInteger)height
         version:(NSInteger)version
          normal:(NSInteger)normal
           ghost:(NSInteger)ghost
       highlight:(NSInteger)highlight
    layerVisible:(BOOL)layerVisible {
    auto it = _tiles.find(hash.UTF8String);
    if (it == _tiles.end()) return;
    GpuTile& t = it->second;
    if (_featureMaterial && rgba && t.version != version && height > 0) {
        if (!t.state || t.stateHeight != (int)height) {
            if (t.state) _engine->destroy(t.state);
            t.state = Texture::Builder()
                          .width(kStateWidth)
                          .height((uint32_t)height)
                          .levels(1)
                          .sampler(Texture::Sampler::SAMPLER_2D)
                          .format(Texture::InternalFormat::SRGB8_A8)
                          .build(*_engine);
            t.stateHeight = (int)height;
            for (auto& p : t.passes)
                for (MaterialInstance* mi : p.materials) {
                    mi->setParameter("featureState", t.state, _sampler);
                    mi->setParameter("stateEnabled", 1.0f);
                }
        }
        const size_t size = (size_t)kStateWidth * (size_t)height * 4;
        uint8_t* copy = (uint8_t*)calloc(size, 1);
        memcpy(copy, rgba.bytes, MIN(size, rgba.length));
        t.state->setImage(*_engine, 0,
                          Texture::PixelBufferDescriptor(copy, size, Texture::Format::RGBA, Texture::Type::UBYTE,
                                                         [](void* buf, size_t, void*) { free(buf); }));
        t.version = version;
    }
    t.highlight = highlight;
    [self applyVisibility:t normal:normal ghost:ghost highlight:highlight layerVisible:layerVisible];
}

- (void)applyVisibility:(GpuTile&)t normal:(NSInteger)normal ghost:(NSInteger)ghost highlight:(NSInteger)highlight layerVisible:(BOOL)layerVisible {
    auto& rcm = _engine->getRenderableManager();
    for (size_t p = 0; p < t.passes.size(); p++) {
        bool on = layerVisible;
        if (on) {
            if (!_featureMaterial) on = p == kPassSolid;
            else if (p == kPassSolid) on = normal + highlight > 0;
            else if (p == kPassGhost) on = ghost > 0;
            else on = highlight > 0;
        }
        for (Entity e : t.passes[p].renderables) rcm.setLayerMask(rcm.getInstance(e), 0xff, on ? 0x01 : 0x00);
    }
}

// ------------------------------------------------------------------ global state

- (void)setModelMatrix:(simd_float4x4)matrix {
    auto& tcm = _engine->getTransformManager();
    tcm.setTransform(tcm.getInstance(_modelRoot), toMat4f(matrix));
    const float ty = matrix.columns[3][1];
    if (std::fabs(ty - _translationY) > 1e-4f) {
        _translationY = ty;
        if (_sectionEnabled) [self pushSection];
    }
}

- (void)setPlaced:(BOOL)placed {
    _view->setVisibleLayers(0xff, placed ? (uint8_t)(kLayerCamera | kLayerModel) : kLayerCamera);
}

- (void)setOpacity:(float)opacity sectionY:(nullable NSNumber*)sectionY {
    _opacity = opacity;
    _sectionEnabled = sectionY != nil;
    _sectionY = sectionY ? sectionY.floatValue : 0.0f;
    for (auto& kv : _tiles)
        for (auto& p : kv.second.passes)
            for (MaterialInstance* mi : p.materials) {
                mi->setParameter("opacity", _opacity);
                mi->setParameter("sectionEnabled", _sectionEnabled ? 1.0f : 0.0f);
            }
    [self pushSection];
}

- (void)setContrast:(BOOL)contrast {
    if (_contrast == (bool)contrast) return;
    _contrast = contrast;
    for (auto& kv : _tiles) {
        const LayerLook look = lookFor(kv.second.layer, _contrast);
        for (auto& p : kv.second.passes)
            for (MaterialInstance* mi : p.materials) {
                mi->setParameter("layerColor", look.color);
                mi->setParameter("ghostAlpha", look.ghostAlpha);
            }
    }
}

- (void)pushSection {
    // user-world Y = tile Y + the fit's vertical translation (yaw-only fit, CONTRACT C2)
    const float y = _sectionY + _translationY;
    for (auto& kv : _tiles)
        for (auto& p : kv.second.passes)
            for (MaterialInstance* mi : p.materials) mi->setParameter("sectionWorldY", y);
}

// ------------------------------------------------------------------ overlay

- (void)replaceOverlay:(FilamentAsset**)slot with:(nullable NSData*)glb {
    if (*slot) {
        _scene->removeEntities((*slot)->getEntities(), (*slot)->getEntityCount());
        _assetLoader->destroyAsset(*slot);
        *slot = nullptr;
    }
    if (!glb) return;
    FilamentAsset* asset = _assetLoader->createAsset((const uint8_t*)glb.bytes, (uint32_t)glb.length);
    if (!asset) return;
    _resourceLoader->loadResources(asset);
    asset->releaseSourceData();
    auto& tcm = _engine->getTransformManager();
    auto& rcm = _engine->getRenderableManager();
    tcm.setParent(tcm.getInstance(asset->getRoot()), tcm.getInstance(_modelRoot));
    const Entity* ents = asset->getEntities();
    for (size_t i = 0; i < asset->getEntityCount(); i++) {
        if (!rcm.hasComponent(ents[i])) continue;
        auto ri = rcm.getInstance(ents[i]);
        rcm.setPriority(ri, 5);
        rcm.setCastShadows(ri, false);
        rcm.setReceiveShadows(ri, false);
    }
    _scene->addEntities(asset->getEntities(), asset->getEntityCount());
    *slot = asset;
}

- (void)setGridGlb:(nullable NSData*)glb visible:(BOOL)visible {
    [self replaceOverlay:&_grid with:glb];
    if (!_grid) return;
    auto& rcm = _engine->getRenderableManager();
    const Entity* ents = _grid->getEntities();
    for (size_t i = 0; i < _grid->getEntityCount(); i++) {
        if (rcm.hasComponent(ents[i])) rcm.setLayerMask(rcm.getInstance(ents[i]), 0xff, visible ? 0x01 : 0x00);
    }
}

- (void)setPinsGlb:(nullable NSData*)glb {
    [self replaceOverlay:&_pins with:glb];
}

@end
