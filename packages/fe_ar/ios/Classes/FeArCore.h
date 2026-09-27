// Objective-C face of the shared C core (packages/fe_ar/src/fe_ar_core.c),
// for the Swift half of the plugin. Swift can't include the C header from
// inside this framework module without a non-modular include, so the C types
// stay behind these small classes. Plain C underneath: one implementation
// with Android, unit-tested on a laptop (src/test/fe_ar_core_test.c).
#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// One ray hit against a tile, tile frame.
@interface FeArRayHit : NSObject
@property(nonatomic, readonly) float t;
@property(nonatomic, readonly) simd_float3 point;
@property(nonatomic, readonly) simd_float3 normal;
/// TEXCOORD_1 local feature index, or -1 when the triangle carries none.
@property(nonatomic, readonly) NSInteger localIndex;
@end

/// A decoded tile's CPU pick mesh and what the tile says about itself
/// (extras.fe, CONTRACT C7). Immutable after init; safe to create off the
/// main thread, ray-cast anywhere.
@interface FeArCpuTile : NSObject
- (nullable instancetype)initWithData:(NSData*)glb error:(NSString* _Nullable* _Nullable)error;
@property(nonatomic, readonly) NSString* layer;
@property(nonatomic, readonly) NSString* buildId;
@property(nonatomic, readonly) NSInteger triangleCount;
@property(nonatomic, readonly) NSInteger localIndexCount;
/// Feature id per local index (int32), from extras.fe.featureIds.
@property(nonatomic, readonly) NSData* featureIds;
- (NSInteger)featureIdAt:(NSInteger)localIndex;
- (BOOL)localBounds:(NSInteger)localIndex min:(simd_float3*)outMin max:(simd_float3*)outMax;
/// skipMask: one byte per local index, non-zero = hidden (never picked).
- (nullable FeArRayHit*)raycastOrigin:(simd_float3)origin
                            direction:(simd_float3)direction
                                 maxT:(float)maxT
                             skipMask:(nullable NSData*)skipMask;
@end

/// A corner fitted by the core. Kinds: 0 inside, 1 outside, 2 column.
@interface FeArCorner : NSObject
@property(nonatomic, readonly) simd_float3 position;
@property(nonatomic, readonly) simd_float2 faceA;
@property(nonatomic, readonly) simd_float2 faceB;
@property(nonatomic, readonly) float angleDeg;
@property(nonatomic, readonly) NSInteger kind;
@property(nonatomic, readonly) float spanA;
@property(nonatomic, readonly) float spanB;
@property(nonatomic, readonly) float rms;
@end

@interface FeArGeometry : NSObject
/// xyz: packed float triples, AR world.
+ (nullable FeArCorner*)cornerFromPoints:(NSData*)xyz
                                    hint:(simd_float3)hint
                                  camera:(simd_float3)camera
                                  floorY:(float)floorY
                              floorKnown:(BOOL)floorKnown
                                  noiseM:(float)noiseM;
+ (nullable FeArCorner*)cornerFromPlaneCentre:(simd_float3)centreA
                                       normal:(simd_float3)normalA
                                   halfExtent:(float)halfA
                                  otherCentre:(simd_float3)centreB
                                  otherNormal:(simd_float3)normalB
                              otherHalfExtent:(float)halfB
                                         hint:(simd_float3)hint
                                       camera:(simd_float3)camera
                                       floorY:(float)floorY
                                   floorKnown:(BOOL)floorKnown;
/// Returns NO for a degenerate set. rms may be NULL.
+ (BOOL)fitPlane:(NSData*)xyz centroid:(simd_float3*)centroid normal:(simd_float3*)normal rms:(float* _Nullable)rms;
/// corners: 8 floats (x, y) clockwise from top-left, image pixels. Camera space out.
+ (BOOL)squarePoseCorners:(const float*)corners
                       fx:(float)fx
                       fy:(float)fy
                       cx:(float)cx
                       cy:(float)cy
                    edgeM:(float)edgeM
                   centre:(simd_float3*)centre
                   normal:(simd_float3*)normal
                 distance:(float*)distance;
/// Mean QR edge (metres) on a known camera-space plane, or < 0.
+ (float)squareEdgeCorners:(const float*)corners
                        fx:(float)fx
                        fy:(float)fy
                        cx:(float)cx
                        cy:(float)cy
              planePoint:(simd_float3)planePoint
             planeNormal:(simd_float3)planeNormal;
/// lines: 4 floats each (x0, z0, x1, z1). pins: 8 floats each
/// (x, y, z, nx, ny, nz, alpha, shape); pinRgb: one int32 0xRRGGBB per pin.
+ (nullable NSData*)overlayGlbLines:(nullable NSData*)lines
                             floorY:(float)floorY
                            gridRgb:(uint32_t)gridRgb
                               pins:(nullable NSData*)pins
                             pinRgb:(nullable NSData*)pinRgb;
@end

/// A board pose from its AprilTag fiducials (src/fe_tag.h), camera space
/// (+X right, +Y up, -Z forward).
@interface FeArTagPose : NSObject
/// The board centre (the QR centre).
@property(nonatomic, readonly) simd_float3 centre;
/// Unit normal out of the board, toward the camera.
@property(nonatomic, readonly) simd_float3 normal;
@property(nonatomic, readonly) float rmsPx;
/// Tags used (2..4).
@property(nonatomic, readonly) NSInteger tags;
/// The tag ids say the board is the A3 print.
@property(nonatomic, readonly) BOOL a3;
@end

/// The board-tag search Android's MarkerDetector.tagPose does, in one call
/// (same constants): tag36h11 detection in a region around the QR on the
/// camera image's luma plane, keeping only this payload's tags that sit at
/// the QR frame's corners, then the C core's planar PnP. NOT thread-safe
/// (AprilTag isn't re-entrant): use one instance from one queue.
@interface FeArTagDetector : NSObject
/// nil when the detector can't be allocated.
+ (nullable FeArTagDetector*)create;
/// qrCorners: 8 floats (x, y), image pixels, clockwise from top-left (the
/// Vision corners). luma: 8-bit Y plane of the same image. Returns nil for a
/// non-marker payload, fewer than 2 matching tags, or a poor fit (RMS over
/// 1.5 px).
- (nullable FeArTagPose*)boardPoseForPayload:(NSString*)payload
                                   qrCorners:(const float*)qrCorners
                                        luma:(const uint8_t*)luma
                                       width:(NSInteger)width
                                      height:(NSInteger)height
                                 bytesPerRow:(NSInteger)bytesPerRow
                                          fx:(float)fx
                                          fy:(float)fy
                                          cx:(float)cx
                                          cy:(float)cy;
@end

NS_ASSUME_NONNULL_END
