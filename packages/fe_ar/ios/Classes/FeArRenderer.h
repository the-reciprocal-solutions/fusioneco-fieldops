// FeArRenderer: Filament (Metal) for fe_ar on iPhone and iPad.
//
// Pure Objective-C interface over an Objective-C++ implementation, so the
// Swift half never sees C++ (Filament's API is C++). Structure follows
// google/filament ios/samples/hello-ar (Apache-2.0): Metal swap chain on a
// CAMetalLayer, the ARKit camera image as an external texture on a
// full-screen triangle, ARKit's projection as a custom projection.
//
// It draws what Android draws, from the same tiles and the same compiled
// material (materials/fe_feature.mat): three gltfio instances per tile for
// the solid, ghost and x-ray passes, a per-tile feature-state texture and
// the overlay GLB. iOS adds the room-scan overlay (LiDAR mesh or plane grid)
// and pulse rings (materials/fe_scan.mat). Main thread only.
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface FeArRenderer : NSObject

/// nil when Filament can't start (no Metal device, e.g. the simulator).
- (nullable instancetype)initWithLayer:(CAMetalLayer*)layer;

/// fe_feature.filamat was bundled: feature state, section and x-ray work.
/// NO = gltfio's own material tinted per layer (the documented fallback).
@property(nonatomic, readonly) BOOL hasFeatureMaterial;

/// fe_camera_feed.filamat was bundled and Filament draws the camera image.
/// NO = the Filament layer is transparent and the view draws the camera
/// underneath with Core Image (slower, but never a black screen).
@property(nonatomic, readonly) BOOL drawsCamera;

/// One frame. projection and cameraModel (camera-to-world) must come from
/// the same ARKit orientation and viewport as the displayed image.
- (void)renderFrame:(nullable CVPixelBufferRef)cameraImage
    textureTransform:(simd_float3x3)textureTransform
          projection:(simd_float4x4)projection
         cameraModel:(simd_float4x4)cameraModel
        drawableSize:(CGSize)drawableSize
             seconds:(double)seconds;

- (BOOL)hasTile:(NSString*)hash;
/// Uploads a tile GLB (tile frame, CONTRACT C7) under the model root.
- (BOOL)addTile:(NSString*)hash data:(NSData*)glb layer:(NSString*)layer;
- (void)removeTile:(NSString*)hash;

/// Uploads the tile's gathered feature state (RGBA8, 256 texels a row,
/// indexed by local feature index) when `version` changed, and switches
/// each pass on only if the tile has features in that mode.
- (void)syncTile:(NSString*)hash
           state:(nullable NSData*)rgba
     stateHeight:(NSInteger)height
         version:(NSInteger)version
          normal:(NSInteger)normal
           ghost:(NSInteger)ghost
       highlight:(NSInteger)highlight
    layerVisible:(BOOL)layerVisible;

/// The (eased) arFromTile transform every tile hangs from.
- (void)setModelMatrix:(simd_float4x4)matrix;

/// Shows or hides everything under the model root (tiles, grid, pins).
/// Starts hidden: until Dart's first setModelTransform the identity root
/// would draw the model at the session origin (Android TileRenderer.placed).
- (void)setPlaced:(BOOL)placed;

/// Global opacity and the section plane (tile-frame Y, or nil for none).
- (void)setOpacity:(float)opacity sectionY:(nullable NSNumber*)sectionY;
/// Sunlight mode (setLayers extra `contrast`): stronger per-layer colours.
- (void)setContrast:(BOOL)contrast;

- (void)setGridGlb:(nullable NSData*)glb visible:(BOOL)visible;
- (void)setPinsGlb:(nullable NSData*)glb;

// ---- room-scan overlay and pulse rings (materials/fe_scan.mat)

/// fe_scan.filamat was bundled: the room-scan overlay and pulse rings draw.
/// NO = both are silently skipped (the rest of AR is unaffected).
@property(nonatomic, readonly) BOOL hasScanMaterial;

/// Adds or replaces one scan surface (a LiDAR mesh anchor or a tracked
/// plane), in its anchor's own frame. `vertices`: non-indexed triangles,
/// 24 bytes a vertex: float x, y, z; uint8 r, g, b, a (linear tint); float
/// u, v (the barycentric corner for the mesh wireframe). `grid` draws the
/// world-space plane grid instead of the wireframe. `bornTime` is in the
/// renderFrame `seconds` clock: the surface paints in from then.
- (void)setScanSurface:(NSString*)key
              vertices:(NSData*)vertices
             transform:(simd_float4x4)transform
              bornTime:(double)bornTime
                  grid:(BOOL)grid NS_SWIFT_NAME(setScanSurface(_:vertices:transform:bornTime:grid:));
/// The anchor moved (ARKit refined it) but its geometry did not.
- (void)setScanSurfaceTransform:(NSString*)key transform:(simd_float4x4)transform NS_SWIFT_NAME(setScanSurfaceTransform(_:transform:));
- (void)removeScanSurface:(NSString*)key NS_SWIFT_NAME(removeScanSurface(_:));
- (void)clearScanSurfaces;
/// Overlay opacity 0..1 (0 takes the scan layer out of the view) and the
/// Sunlight look.
- (void)setScanAlpha:(float)alpha contrast:(BOOL)contrast NS_SWIFT_NAME(setScanAlpha(_:contrast:));
/// Two expanding rings at `position` (AR world) in the plane facing
/// `normal`, colour 0xRRGGBB (sRGB). They remove themselves.
- (void)pulseAt:(simd_float3)position normal:(simd_float3)normal rgb:(uint32_t)rgb NS_SWIFT_NAME(pulse(at:normal:rgb:));

/// Reads back the next rendered frame (model, plus camera when
/// drawsCamera). The completion runs on the main thread.
- (void)captureNextFrame:(void (^)(UIImage* _Nullable image))completion;

@end

NS_ASSUME_NONNULL_END
