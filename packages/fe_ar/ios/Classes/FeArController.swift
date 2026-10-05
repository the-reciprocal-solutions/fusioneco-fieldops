import ARKit
import AVFoundation
import Flutter
import UIKit

/// The iOS half of the `fusioneco/ar` channel (CHANNEL.md, CONTRACT C8).
/// Mirrors android/.../FeArController.kt: native executes, Dart decides.
/// Keeps the last command of each kind so a recreated view comes back exactly
/// as Dart left it. Main thread only (ARSession delegate on main).
final class FeArController: NSObject, FlutterStreamHandler, ARSessionDelegate {
    private var sink: FlutterEventSink?
    private let session = ARSession()
    private var sessionWanted = false
    private var paused = false
    private var running = false
    private var wantDepth = true
    private var layerContrast = false
    private var thermalObserver: NSObjectProtocol?
    private var needsReset = true

    private weak var platformView: FeArPlatformView?
    private var renderer: FeArRenderer?
    private let tiles = FeArTileStore()
    private let states = FeArFeatureStates()
    private lazy var markers = FeArMarkerDetector(emit: { [weak self] in self?.emit($0) })
    private lazy var corners = FeArCornerDetector(emit: { [weak self] in self?.emit($0) })
    private let depthProbe = FeArDepthProbe()
    private lazy var scanner = FeArScanner(emit: { [weak self] in self?.emit($0) })

    // room-scan overlay (extension `setScanOverlay`): Dart's wish, the Sunlight
    // look, and the overlay's animated opacity (fades in 0.4 s, out 0.8 s)
    private var scanWanted = false
    private var scanContrast = false
    private var scanAlpha: Float = 0
    private var lastFrameTime: CFTimeInterval = 0
    /// (depth semantics, scene mesh) of the configuration the session runs.
    private var runningConfig: (depth: Bool, mesh: Bool)?
    /// The scene mesh runs for corner snaps (with depth) and while the scan
    /// overlay shows or is still fading out (turning it off mid-fade would
    /// swap the fading mesh for the plane grid).
    private var wantMesh: Bool { wantDepth || scanWanted || scanAlpha > 0 }

    // model reveal: on the first placement the model builds up from its
    // lowest point to its highest (a moving section plane) while it fades in
    private var revealStart: CFTimeInterval = 0
    private var revealBottom: Float = 0
    private var revealTop: Float = 0
    private var revealing = false
    static let revealSeconds: CFTimeInterval = 1.1

    // drawing state
    private var modelCurrent = matrix_identity_float4x4
    /// True once Dart has sent a model transform this session (Android
    /// TileRenderer.placed). Until then tiles, grid and pins are loaded but
    /// hidden: the identity root would put the model at the session origin,
    /// which read as "the overlay lands somewhere random" on the first
    /// Android device run.
    private var modelPlaced = false
    private var easeFrom = matrix_identity_float4x4
    private var easeTo = matrix_identity_float4x4
    private var easeStart: CFTimeInterval = 0
    private var easeDuration: CFTimeInterval = 0
    private var layerMep = true, layerStructure = true, layerArchitecture = true, layerGrid = true
    private var opacity: Float = 1
    private var sectionY: Float?
    private var targetIds: Set<Int>?
    private var targetBuild: String?
    private var gridGlb: Data?
    private var pinGlb: Data?

    // per-frame state
    private var viewMatrix = matrix_identity_float4x4
    private var projMatrix = matrix_identity_float4x4
    private var matricesValid = false
    private var lastState: String?
    private var lastReason: String?
    private var lastPose: CFTimeInterval = 0
    private var lastTarget: CFTimeInterval = 0
    private let startTime = CACurrentMediaTime()

    // floor extension event (CHANNEL.md `floor`), as Android detectFloor
    private var lastFloorCheck: CFTimeInterval = 0
    private var lastFloorY: Float?
    private var floorAnchorId: UUID?
    static let floorMinAreaM2: Float = 0.25
    static let floorMinDropM: Float = 0.8
    static let floorMaxDropM: Float = 2.3
    static let floorSwitchRatio: Float = 1.5

    // torch (extension `setTorch`): as Android, reset by startSession/stop and
    // kept across pause/resume. ARKit turns it off whenever the capture
    // session restarts, so it is re-applied on the first frame after a run.
    private var torchOn = false
    private var torchNeedsApply = false

    override init() {
        super.init()
        session.delegate = self
        tiles.onWarning = { [weak self] code, detail in self?.emitError(code, detail) }
    }

    // MARK: events

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    private func emit(_ event: [String: Any]) {
        if Thread.isMainThread { sink?(event) } else { DispatchQueue.main.async { self.sink?(event) } }
    }

    private func emitError(_ code: String, _ detail: String) {
        emit(["type": "error", "code": code, "detail": detail])
    }

    private func emitTracking(_ state: String, _ reason: String?) {
        if state == lastState && reason == lastReason { return }
        lastState = state
        lastReason = reason
        emit(["type": "tracking", "state": state, "reason": reason.map { $0 as Any } ?? NSNull()])
    }

    // MARK: view

    func attach(_ view: FeArPlatformView) {
        platformView = view
        renderer = nil
        guard let r = FeArRenderer(layer: view.container.modelView.metalLayer) else {
            emitError("renderer-failed", "Filament could not start (no Metal device?)")
            return
        }
        renderer = r
        scanner.rendererChanged()
        r.setScanAlpha(scanAlpha, contrast: scanContrast)
        if !r.drawsCamera { view.container.enableCameraFallback() }
        r.setModelMatrix(modelCurrent)
        r.setPlaced(modelPlaced)
        r.setOpacity(opacity, sectionY: sectionY.map { NSNumber(value: $0) })
        r.setGridGlb(gridGlb, visible: layerGrid)
        r.setPinsGlb(pinGlb)
        for e in tiles.entries { upload(e) }
    }

    /// Called (asynchronously) when a platform view goes away. The weak
    /// reference is usually nil by then, which still means "ours went": only
    /// a newer view that has already attached keeps the renderer.
    func detach(_ id: ObjectIdentifier) {
        if let v = platformView, ObjectIdentifier(v) != id { return }
        platformView = nil
        renderer = nil // dealloc tears Filament down
        scanner.rendererChanged()
        matricesValid = false
    }

    private func upload(_ e: FeArTileEntry) {
        guard let r = renderer else {
            e.pendingData = nil // re-read when a renderer exists again
            return
        }
        if r.hasTile(e.hash) { return }
        if let data = e.pendingData {
            if !r.addTile(e.hash, data: data, layer: e.layer) { emitError("tile-upload-failed", e.hash) }
            e.pendingData = nil
            sync(e)
        } else {
            tiles.readData(e) { [weak self] data in
                guard let self = self, let data = data, let r2 = self.renderer, r2 === r, self.tiles.tiles[e.hash] === e, !r2.hasTile(e.hash) else { return }
                if !r2.addTile(e.hash, data: data, layer: e.layer) { self.emitError("tile-upload-failed", e.hash) }
                self.sync(e)
            }
        }
    }

    private func layerVisible(_ layer: String) -> Bool {
        switch layer {
        case "structure": return layerStructure
        case "architecture": return layerArchitecture
        default: return layerMep
        }
    }

    private func sync(_ e: FeArTileEntry) {
        renderer?.syncTile(e.hash, state: e.stateBytes, stateHeight: e.stateHeight, version: e.stateVersion,
                           normal: e.countNormal, ghost: e.countGhost, highlight: e.countHighlight,
                           layerVisible: layerVisible(e.layer))
    }

    // MARK: session

    private func configuration() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal, .vertical]
        c.isAutoFocusEnabled = true
        c.environmentTexturing = .none
        if let f = Self.preferredVideoFormat() { c.videoFormat = f }
        // LiDAR's scene mesh: for corner snaps while depth is on, and for the
        // room-scan overlay whenever that shows (it is the overlay).
        if wantMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            c.sceneReconstruction = .meshWithClassification
        }
        if wantDepth {
            // Both when the device has them: smoothed for markers and corners,
            // the per-frame map (with its own confidence) for depthPointAt's
            // "rawDepth", as Android pairs smoothed and raw depth.
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                c.frameSemantics.insert(.smoothedSceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                c.frameSemantics.insert(.sceneDepth)
            }
        }
        return c
    }

    /// Re-runs the session (no reset: tracking and anchors continue) when
    /// depth or the scene mesh should change. ARKit restarts the capture,
    /// which turns the torch off, so it is re-applied on the next frame.
    private func reconfigureIfNeeded() {
        guard running else { return }
        let want = (depth: wantDepth, mesh: wantMesh)
        if let r = runningConfig, r.depth == want.depth, r.mesh == want.mesh { return }
        session.run(configuration(), options: [])
        runningConfig = want
        torchNeedsApply = torchOn
    }

    /// The QR must decode from ~2 m (docs/ar-markers-and-qr.md §2.2), so take
    /// the largest back wide-angle format up to 1920 wide (Android
    /// pickCameraConfig's 1080p cap), higher frame rate on a tie. ARKit's
    /// captured image is also what Filament draws full-screen, so bigger is
    /// sharper on screen too. 4K formats (iOS 16) are skipped: they cost
    /// frame rate and the Vision pass for no QR gain at these distances.
    static func preferredVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats.filter { f in
            if #available(iOS 16.0, *), f.captureDeviceType != .builtInWideAngleCamera { return false }
            return f.captureDevicePosition == .back && f.imageResolution.width <= 1920
        }
        return formats.max { a, b in
            let pa = a.imageResolution.width * a.imageResolution.height
            let pb = b.imageResolution.width * b.imageResolution.height
            return pa != pb ? pa < pb : a.framesPerSecond < b.framesPerSecond
        }
    }

    private func updateRunning() {
        let should = sessionWanted && !paused
        if should && !running {
            session.run(configuration(), options: needsReset ? [.resetTracking, .removeExistingAnchors] : [])
            runningConfig = (depth: wantDepth, mesh: wantMesh)
            needsReset = false
            running = true
            torchNeedsApply = torchOn
        } else if !should && running {
            session.pause()
            running = false
            emitTracking("paused", nil)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let (state, reason) = Self.tracking(camera.trackingState)
        emitTracking(state, reason)
    }

    static func tracking(_ s: ARCamera.TrackingState) -> (String, String?) {
        switch s {
        case .normal: return ("tracking", nil)
        case .notAvailable: return ("notAvailable", nil)
        case .limited(let r):
            switch r {
            case .initializing: return ("initializing", "initializing")
            case .excessiveMotion: return ("limited", "excessiveMotion")
            case .insufficientFeatures: return ("limited", "insufficientFeatures")
            case .relocalizing: return ("limited", "relocalizing")
            @unknown default: return ("limited", nil)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let code: String
        if let e = error as? ARError {
            switch e.code {
            case .cameraUnauthorized: code = "camera-denied"
            case .unsupportedConfiguration: code = "device-not-supported"
            case .sensorUnavailable, .sensorFailed: code = "camera-unavailable"
            default: code = "session-failed"
            }
        } else {
            code = "session-failed"
        }
        emitError(code, error.localizedDescription)
        emitTracking("notAvailable", code)
        running = false
    }

    func sessionWasInterrupted(_ session: ARSession) {
        emitTracking("paused", "interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // ARKit resumes tracking itself; markers' anchors survive relocalisation.
        emitTracking("limited", "relocalizing")
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        markers.anchorsRemoved(anchors)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = CACurrentMediaTime()
        let tracking: Bool
        if case .normal = frame.camera.trackingState { tracking = true } else { tracking = false }

        stepEase(now)
        let dt = lastFrameTime > 0 ? min(max(now - lastFrameTime, 0), 0.1) : 0
        lastFrameTime = now
        stepScanAlpha(dt)
        stepReveal(now)
        // Before the render, so a surface found this frame draws this frame.
        scanner.onFrame(frame, now: now, seconds: now - startTime, renderer: renderer,
                        drawing: scanWanted || scanAlpha > 0, stats: scanWanted)
        if let pv = platformView {
            let container = pv.container
            let size = container.bounds.size
            if size.width > 0, size.height > 0 {
                let orientation = container.interfaceOrientation
                projMatrix = frame.camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.05, zFar: 100)
                viewMatrix = frame.camera.viewMatrix(for: orientation)
                matricesValid = true
                if let r = renderer {
                    // hello-ar fixes landscapeRight; this follows the live orientation.
                    // TODO(slice-0): check the feed isn't mirrored or rotated in all four.
                    let inv = frame.displayTransform(for: orientation, viewportSize: size).inverted()
                    let uv = simd_float3x3(columns: (
                        SIMD3<Float>(Float(inv.a), Float(inv.b), 0),
                        SIMD3<Float>(Float(inv.c), Float(inv.d), 0),
                        SIMD3<Float>(Float(inv.tx), Float(inv.ty), 1)
                    ))
                    r.renderFrame(frame.capturedImage, textureTransform: uv, projection: projMatrix,
                                  cameraModel: viewMatrix.inverse, drawableSize: container.drawableSize,
                                  seconds: now - startTime)
                    if !r.drawsCamera { container.drawCamera(frame) }
                }
            }
        }

        if tracking && now - lastPose >= 0.2 {
            lastPose = now
            // Display-oriented, as Android's displayOrientedPose: +X right and
            // +Y up on screen. camera.transform is the sensor's landscape frame.
            let orientation = platformView?.container.interfaceOrientation ?? .portrait
            emit(["type": "pose", "arFromCamera": Self.list(frame.camera.viewMatrix(for: orientation).inverse)])
        }
        markers.onFrame(session: session, frame: frame, tracking: tracking)
        if tracking && now - lastFloorCheck >= 1 {
            lastFloorCheck = now
            detectFloor(frame)
        }
        if torchNeedsApply {
            torchNeedsApply = false
            applyTorch()
        }
        if targetIds != nil && tracking && now - lastTarget >= 0.1 {
            lastTarget = now
            if let e = targetScreen() { emit(e) }
        }
    }

    // MARK: floor

    /// The floor for the fit's height (extension event `floor`), as Android
    /// FeArController.detectFloor: the largest tracked horizontal plane of at
    /// least 0.25 m² that sits a standing phone's height (0.8-2.3 m) below the
    /// camera. The largest, not the lowest: a small false plane under the
    /// floor won on "lowest" in the first Android device run (27 cm too low).
    /// Sticky: the current plane stays while ARKit still has it, unless
    /// another is 1.5x bigger (two planes ~10 cm apart traded places as each
    /// grew and the model bounced). Emitted when it first appears or moves by
    /// 1 cm; called at most once a second.
    private func detectFloor(_ frame: ARFrame) {
        let cameraY = frame.camera.transform.columns.3.y
        var best: ARPlaneAnchor?
        var bestArea: Float = 0
        var current: ARPlaneAnchor?
        for case let p as ARPlaneAnchor in frame.anchors where p.alignment == .horizontal {
            if p.identifier == floorAnchorId { current = p }
            if ARPlaneAnchor.isClassificationSupported {
                switch p.classification {
                case .ceiling, .table, .seat: continue
                default: break
                }
            }
            let area = Self.planeArea(p)
            if area < Self.floorMinAreaM2 { continue }
            let drop = cameraY - FeArCornerDetector.centre(p).y
            if drop < Self.floorMinDropM || drop > Self.floorMaxDropM { continue }
            if area > bestArea {
                best = p
                bestArea = area
            }
        }
        // ARKit removes a plane anchor it merged into another (didRemove), so
        // "still in frame.anchors" is the equivalent of ARCore's TRACKING and
        // the merged-into plane competes on its own.
        if let c = current, let b = best, b.identifier != c.identifier, bestArea < Self.floorSwitchRatio * Self.planeArea(c) {
            best = c
        }
        guard let floor = best else { return }
        floorAnchorId = floor.identifier
        let y = FeArCornerDetector.centre(floor).y
        if let last = lastFloorY, abs(y - last) < 0.01 { return }
        lastFloorY = y
        emit(["type": "floor", "yAr": Double(y), "areaM2": Double(Self.planeArea(floor))])
    }

    static func planeArea(_ p: ARPlaneAnchor) -> Float {
        if #available(iOS 16.0, *) { return p.planeExtent.width * p.planeExtent.height }
        return p.extent.x * p.extent.z
    }

    // MARK: torch

    /// The back camera's torch while ARKit owns the capture session. iOS 16+
    /// hands out the exact AVCaptureDevice ARKit runs
    /// (configurableCaptureDeviceForPrimaryCamera); before that the default
    /// video device is the same back wide-angle camera.
    private static func torchDevice() -> AVCaptureDevice? {
        if #available(iOS 16.0, *), let d = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera { return d }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Applies `torchOn` now; false with no running session (it is applied
    /// when one runs) or no torch. `torch-failed` when the device refuses.
    @discardableResult
    private func applyTorch() -> Bool {
        guard running, let d = Self.torchDevice(), d.hasTorch else { return false }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            if torchOn {
                guard d.isTorchAvailable else { return false }
                try d.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else if d.torchMode != .off {
                d.torchMode = .off
            }
            return true
        } catch {
            emitError("torch-failed", error.localizedDescription)
            return false
        }
    }

    // MARK: model transform

    private func setModel(_ m: simd_float4x4, easeMs: Int) {
        if !modelPlaced {
            // First placement: jump straight there (never ease in from the
            // session origin), then show the model. As Android.
            modelPlaced = true
            modelCurrent = m
            easeDuration = 0
            renderer?.setModelMatrix(m)
            renderer?.setPlaced(true)
            startReveal()
            return
        }
        if easeMs <= 0 || !Self.isYawTranslation(modelCurrent) || !Self.isYawTranslation(m) {
            modelCurrent = m
            easeDuration = 0
            renderer?.setModelMatrix(m)
            return
        }
        easeFrom = modelCurrent
        easeTo = m
        easeStart = CACurrentMediaTime()
        easeDuration = Double(easeMs) / 1000
    }

    /// Yaw along the shortest arc, translation linearly, smoothstep. Never snaps.
    private func stepEase(_ now: CFTimeInterval) {
        guard easeDuration > 0 else { return }
        let t = Float(min(max((now - easeStart) / easeDuration, 0), 1))
        if t >= 1 {
            modelCurrent = easeTo
            easeDuration = 0
        } else {
            let s = t * t * (3 - 2 * t)
            let y0 = Self.yaw(easeFrom), y1 = Self.yaw(easeTo)
            var dy = y1 - y0
            while dy > .pi { dy -= 2 * .pi }
            while dy <= -.pi { dy += 2 * .pi }
            let a = easeFrom.columns.3, b = easeTo.columns.3
            modelCurrent = Self.fromYaw(y0 + dy * s, SIMD3<Float>(a.x + (b.x - a.x) * s, a.y + (b.y - a.y) * s, a.z + (b.z - a.z) * s))
        }
        renderer?.setModelMatrix(modelCurrent)
    }

    // MARK: model reveal and scan fade

    /// The first placement builds the model up from its lowest point to its
    /// highest over ~1 s (a rising section plane, tile frame) while it fades
    /// in. Skipped when Dart has a section of its own or no tile is loaded
    /// yet (the model then simply appears).
    private func startReveal() {
        guard sectionY == nil else { return }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        var a = SIMD3<Float>(repeating: 0), b = SIMD3<Float>(repeating: 0)
        var checked = 0
        for e in tiles.entries {
            for l in 0..<e.cpu.localIndexCount where checked < 50_000 {
                checked += 1
                if e.cpu.localBounds(l, min: &a, max: &b) {
                    lo = min(lo, a.y)
                    hi = max(hi, b.y)
                }
            }
        }
        guard lo < hi else { return }
        revealBottom = lo
        revealTop = hi + 0.05
        revealStart = CACurrentMediaTime()
        revealing = true
        stepReveal(revealStart)
    }

    private func stepReveal(_ now: CFTimeInterval) {
        guard revealing else { return }
        let t = Float(min(max((now - revealStart) / Self.revealSeconds, 0), 1))
        if t >= 1 || sectionY != nil {
            revealing = false
            renderer?.setOpacity(opacity, sectionY: sectionY.map { NSNumber(value: $0) })
            return
        }
        let k = t * t * (3 - 2 * t)
        renderer?.setOpacity(opacity * (0.25 + 0.75 * k), sectionY: NSNumber(value: revealBottom + (revealTop - revealBottom) * k))
    }

    /// Eases the room-scan overlay toward Dart's wish.
    private func stepScanAlpha(_ dt: CFTimeInterval) {
        let target: Float = scanWanted ? 1 : 0
        guard scanAlpha != target else { return }
        let step = Float(dt / (scanWanted ? 0.4 : 0.8))
        scanAlpha = scanWanted ? min(target, scanAlpha + step) : max(target, scanAlpha - step)
        renderer?.setScanAlpha(scanAlpha, contrast: scanContrast)
        if scanAlpha == 0 { reconfigureIfNeeded() } // faded out: the mesh can stop
    }

    // x' = x cos + z sin, z' = -x sin + z cos (CONTRACT C2): column 2 is (sin, 0, cos)
    static func yaw(_ m: simd_float4x4) -> Float { atan2(m.columns.2.x, m.columns.0.x) }

    static func fromYaw(_ yaw: Float, _ t: SIMD3<Float>) -> simd_float4x4 {
        let c = cos(yaw), s = sin(yaw)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        ))
    }

    static func isYawTranslation(_ m: simd_float4x4) -> Bool {
        let e: Float = 1e-3
        return abs(m.columns.0.y) < e && abs(m.columns.1.x) < e && abs(m.columns.1.z) < e && abs(m.columns.2.y) < e &&
            abs(m.columns.1.y - 1) < e && abs(m.columns.0.x * m.columns.0.x + m.columns.0.z * m.columns.0.z - 1) < 2 * e &&
            abs(m.columns.0.w) < e && abs(m.columns.1.w) < e && abs(m.columns.2.w) < e && abs(m.columns.3.w - 1) < e
    }

    static func list(_ m: simd_float4x4) -> [Double] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
    }

    static func matrix(_ raw: Any?) -> simd_float4x4? {
        guard let l = raw as? [Any], l.count >= 16 else { return nil }
        var v = [Float](repeating: 0, count: 16)
        for i in 0..<16 {
            guard let n = l[i] as? NSNumber else { return nil }
            v[i] = n.floatValue
        }
        return simd_float4x4(columns: (
            SIMD4<Float>(v[0], v[1], v[2], v[3]), SIMD4<Float>(v[4], v[5], v[6], v[7]),
            SIMD4<Float>(v[8], v[9], v[10], v[11]), SIMD4<Float>(v[12], v[13], v[14], v[15])
        ))
    }

    static func vec3(_ raw: Any?) -> SIMD3<Float>? {
        guard let l = raw as? [Any], l.count >= 3,
              let x = l[0] as? NSNumber, let y = l[1] as? NSNumber, let z = l[2] as? NSNumber else { return nil }
        return SIMD3<Float>(x.floatValue, y.floatValue, z.floatValue)
    }

    static func vec2(_ raw: Any?) -> SIMD2<Float>? {
        guard let l = raw as? [Any], l.count >= 2, let x = l[0] as? NSNumber, let y = l[1] as? NSNumber else { return nil }
        return SIMD2<Float>(x.floatValue, y.floatValue)
    }

    // MARK: geometry queries

    /// World ray through a view point (points = Flutter logical pixels).
    private func ray(_ p: CGPoint) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard matricesValid, let size = platformView?.container.bounds.size, size.width > 0, size.height > 0 else { return nil }
        let inv = (projMatrix * viewMatrix).inverse
        let nx = Float(2 * p.x / size.width - 1), ny = Float(1 - 2 * p.y / size.height)
        func unproject(_ z: Float) -> SIMD3<Float> {
            let v = inv * SIMD4<Float>(nx, ny, z, 1)
            return SIMD3<Float>(v.x, v.y, v.z) / v.w
        }
        let near = unproject(-1), far = unproject(1)
        return (near, simd_normalize(far - near))
    }

    /// Projects an AR-world point to view points; mirrored when behind, so an
    /// edge arrow still points the way to turn.
    private func project(_ w: SIMD3<Float>) -> (Double, Double, Bool)? {
        guard matricesValid, let size = platformView?.container.bounds.size, size.width > 0, size.height > 0 else { return nil }
        let vp = projMatrix * viewMatrix
        let c = vp * SIMD4<Float>(w.x, w.y, w.z, 1)
        let behind = c.w <= 1e-6
        let ww = behind ? max(-c.w, 1e-6) : c.w
        var x = Double((c.x / ww + 1) / 2) * Double(size.width)
        var y = Double((1 - c.y / ww) / 2) * Double(size.height)
        if behind {
            x = Double(size.width) - x
            y = Double(size.height) - y
        }
        let on = !behind && x >= 0 && x <= Double(size.width) && y >= 0 && y <= Double(size.height)
        return (x, y, on)
    }

    private func pick(_ p: CGPoint) -> [String: Any]? {
        guard let r = ray(p) else { return nil }
        let (origin, dir) = r
        let tileFromAr = modelCurrent.inverse
        let o4 = tileFromAr * SIMD4<Float>(origin.x, origin.y, origin.z, 1)
        let d4 = tileFromAr * SIMD4<Float>(dir.x, dir.y, dir.z, 0)
        let o = SIMD3<Float>(o4.x, o4.y, o4.z), d = SIMD3<Float>(d4.x, d4.y, d4.z)
        var bestT: Float = 100
        var best: (FeArTileEntry, FeArRayHit)?
        for e in tiles.entries where layerVisible(e.layer) {
            if let h = e.cpu.raycastOrigin(o, direction: d, maxT: bestT, skipMask: e.skipMask), h.t < bestT {
                bestT = h.t
                best = (e, h)
            }
        }
        guard let found = best else { return nil }
        let (entry, hit) = found
        let fid = entry.featureId(at: hit.localIndex)
        guard fid >= 0 else { return nil }
        let world = modelCurrent * SIMD4<Float>(hit.point.x, hit.point.y, hit.point.z, 1)
        var distance = Double(bestT)
        if let cam = session.currentFrame?.camera.transform.columns.3 {
            distance = Double(simd_distance(SIMD3<Float>(cam.x, cam.y, cam.z), SIMD3<Float>(world.x, world.y, world.z)))
        }
        return [
            "featureId": fid,
            "buildId": entry.buildId.isEmpty ? NSNull() as Any : entry.buildId as Any,
            "tileHash": entry.hash,
            "localIndex": hit.localIndex,
            "hitPointTile": [Double(hit.point.x), Double(hit.point.y), Double(hit.point.z)],
            "normalTile": [Double(hit.normal.x), Double(hit.normal.y), Double(hit.normal.z)],
            "distanceM": distance,
        ]
    }

    private func computeTargetLocals(_ e: FeArTileEntry) {
        guard let ids = targetIds, targetBuild == nil || targetBuild == e.buildId else {
            e.targetLocals = []
            return
        }
        e.targetLocals = e.featureIds.indices.filter { ids.contains(Int(e.featureIds[$0])) }
    }

    private func targetScreen() -> [String: Any]? {
        var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude), mx = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for e in tiles.entries {
            for l in e.targetLocals {
                var a = SIMD3<Float>(repeating: 0), b = SIMD3<Float>(repeating: 0)
                if e.cpu.localBounds(l, min: &a, max: &b) {
                    any = true
                    mn = simd_min(mn, a)
                    mx = simd_max(mx, b)
                }
            }
        }
        guard any else { return nil }
        let c = (mn + mx) / 2
        let w = modelCurrent * SIMD4<Float>(c.x, c.y, c.z, 1)
        guard let s = project(SIMD3<Float>(w.x, w.y, w.z)) else { return nil }
        return ["type": "targetScreen", "x": s.0, "y": s.1, "onScreen": s.2]
    }

    /// `pickMany` point list: `[[x, y]]` or `[{x, y}]`, logical pixels.
    static func points(_ raw: Any?) -> [CGPoint?] {
        (raw as? [Any] ?? []).map { item -> CGPoint? in
            if let v = vec2(item) { return CGPoint(x: CGFloat(v.x), y: CGFloat(v.y)) }
            if let m = item as? [String: Any], let x = (m["x"] as? NSNumber)?.doubleValue, let y = (m["y"] as? NSNumber)?.doubleValue {
                return CGPoint(x: x, y: y)
            }
            return nil
        }
    }

    // MARK: capabilities

    private func capabilities() -> [String: Any] {
        let supported = ARWorldTrackingConfiguration.isSupported
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        let denied = auth == .denied || auth == .restricted
        let lidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let mesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        let reason: Any = !supported ? "device-not-supported" as Any : denied ? "camera-denied" as Any : NSNull() as Any
        let ok = supported && !denied
        return [
            "supported": ok,
            "depth": ok && lidar,
            "lidar": ok && lidar,
            "recording": false,
            "platform": "ios",
            "reason": reason,
            "featureMaterial": renderer?.hasFeatureMaterial ?? Self.bundledMaterial("fe_feature"),
            "cameraMaterial": renderer?.drawsCamera ?? Self.bundledMaterial("fe_camera_feed"),
            // extras: the classified LiDAR mesh (corner snaps), a torch to switch
            "mesh": ok && mesh,
            "torch": Self.torchDevice()?.hasTorch ?? false,
            // the room-scan overlay can draw (fe_scan.filamat bundled)
            "scanOverlay": ok && (renderer?.hasScanMaterial ?? Self.bundledMaterial("fe_scan")),
        ]
    }

    static func bundledMaterial(_ name: String) -> Bool {
        let bundle = Bundle(for: FeArController.self)
        let res = bundle.url(forResource: "fe_ar_assets", withExtension: "bundle").flatMap { Bundle(url: $0) } ?? bundle
        return res.url(forResource: name, withExtension: "filamat") != nil
    }

    // MARK: capture

    private func capture(_ result: @escaping FlutterResult) {
        guard let r = renderer, let pv = platformView else {
            result(nil)
            return
        }
        let fallbackFrame = r.drawsCamera ? nil : session.currentFrame
        // The read-back happens on the next rendered frame; if none comes
        // (paused session, view gone), answer null rather than hang Dart.
        var answered = false
        let answer: FlutterResult = { value in
            if answered { return }
            answered = true
            result(value)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { answer(nil) }
        r.captureNextFrame { image in
            guard var img = image else {
                answer(nil)
                return
            }
            if let f = fallbackFrame, let composite = pv.container.composite(model: img, over: f) { img = composite }
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fe_ar", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("capture_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
                let ok = (try? img.jpegData(compressionQuality: 0.88)?.write(to: url)) != nil
                DispatchQueue.main.async { answer(ok ? url.path : nil) }
            }
        }
    }

    // MARK: commands

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "capabilities":
            result(capabilities())
        case "startSession":
            wantDepth = (a["depth"] as? Bool) ?? true
            markers.progressEvents = (a["progressEvents"] as? Bool) ?? false
            if a["recordTo"] is String { emitError("recording-unsupported", "ARKit sessions can't be recorded in-app; use Reality Composer") }
            if a["playbackFrom"] is String { emitError("playback-unsupported", "ARKit replay runs from Xcode's scheme settings") }
            guard ARWorldTrackingConfiguration.isSupported else {
                emitTracking("notAvailable", "device-not-supported")
                result(nil)
                return
            }
            sessionWanted = true
            startThermal()
            paused = false
            torchOn = false // reset by startSession, as Android
            if running { applyTorch() }
            lastState = nil
            emitTracking("initializing", "initializing")
            updateRunning()
            result(nil)
        case "loadTiles":
            let refs: [(hash: String, path: String)] = (a["tiles"] as? [Any] ?? []).compactMap {
                guard let m = $0 as? [String: Any], let h = m["hash"] as? String, let p = m["path"] as? String else { return nil }
                return (h, p)
            }
            tiles.load(refs, onEntry: { [weak self] e in
                guard let self = self else { return }
                self.states.gather(e)
                self.computeTargetLocals(e)
                self.upload(e)
            }, done: { loaded, failed in
                result(["loaded": loaded, "failed": failed])
            })
        case "unloadTiles":
            let hashes = (a["hashes"] as? [Any] ?? []).compactMap { $0 as? String }
            tiles.unload(hashes) { [weak self] e in self?.renderer?.removeTile(e.hash) }
            result(nil)
        case "setModelTransform":
            guard let m = Self.matrix(a["matrix"] ?? a["arFromTile"]) else {
                result(FlutterError(code: "bad-args", message: "matrix must be 16 numbers, column-major", details: nil))
                return
            }
            setModel(m, easeMs: (a["easeMs"] as? NSNumber)?.intValue ?? 300)
            result(nil)
        case "setFeatureState":
            guard let data = (a["rgba"] as? FlutterStandardTypedData)?.data, ((a["width"] as? NSNumber)?.intValue ?? 0) > 0 else {
                result(FlutterError(code: "bad-args", message: "rgba and width are required", details: nil))
                return
            }
            states.set(buildId: a["buildId"] as? String, rgba: data)
            for e in tiles.entries {
                states.gather(e)
                sync(e)
            }
            result(nil)
        case "setLayers":
            layerMep = (a["mep"] as? Bool) ?? true
            layerStructure = (a["structure"] as? Bool) ?? true
            layerArchitecture = (a["architecture"] as? Bool) ?? true
            layerGrid = (a["grid"] as? Bool) ?? true
            opacity = min(max((a["opacity"] as? NSNumber)?.floatValue ?? 1, 0), 1)
            sectionY = (a["sectionY"] as? NSNumber)?.floatValue
            layerContrast = (a["contrast"] as? Bool) ?? false
            // A running reveal ends on these values itself (stepReveal); a
            // section of Dart's own ends it now.
            if !revealing || sectionY != nil {
                revealing = false
                renderer?.setOpacity(opacity, sectionY: sectionY.map { NSNumber(value: $0) })
            }
            renderer?.setContrast(layerContrast)
            renderer?.setGridGlb(gridGlb, visible: layerGrid)
            for e in tiles.entries { sync(e) }
            result(nil)
        case "setTarget":
            if let ids = a["featureIds"] as? [Any] {
                targetIds = Set(ids.compactMap { ($0 as? NSNumber)?.intValue })
            } else {
                targetIds = nil
            }
            targetBuild = a["buildId"] as? String
            for e in tiles.entries { computeTargetLocals(e) }
            lastTarget = 0
            result(nil)
        case "setGridLines":
            var flat: [Float] = []
            for l in a["lines"] as? [Any] ?? [] {
                guard let m = l as? [String: Any], let p0 = Self.vec2(m["p0"]), let p1 = Self.vec2(m["p1"]) else { continue }
                flat += [p0.x, p0.y, p1.x, p1.y]
            }
            let floorY = (a["floorY"] as? NSNumber)?.floatValue ?? 0
            gridGlb = flat.isEmpty ? nil : FeArGeometry.overlayGlbLines(flat.withUnsafeBufferPointer { Data(buffer: $0) },
                                                                        floorY: floorY, gridRgb: 0xFB923C, pins: nil, pinRgb: nil)
            renderer?.setGridGlb(gridGlb, visible: layerGrid)
            result(nil)
        case "setPins":
            pinGlb = buildPins(a["pins"] as? [Any] ?? [])
            renderer?.setPinsGlb(pinGlb)
            result(nil)
        case "detectCornerAt":
            guard let x = (a["x"] as? NSNumber)?.doubleValue, let y = (a["y"] as? NSNumber)?.doubleValue,
                  let frame = session.currentFrame, let pv = platformView else {
                result(nil)
                return
            }
            let p = CGPoint(x: x, y: y)
            guard let r = ray(p) else {
                result(nil)
                return
            }
            let corner = corners.detect(session: session, frame: frame, point: p, viewSize: pv.container.bounds.size,
                                        orientation: pv.container.interfaceOrientation, rayOrigin: r.0, rayDir: r.1)
            result(corner.map { FeArCornerDetector.verified($0, frame: frame) })
        case "pick":
            guard let x = (a["x"] as? NSNumber)?.doubleValue, let y = (a["y"] as? NSNumber)?.doubleValue else {
                result(nil)
                return
            }
            result(pick(CGPoint(x: x, y: y)))
        case "capture":
            capture(result)
        case "pause":
            paused = true
            updateRunning()
            result(nil)
        case "resume":
            paused = false
            updateRunning()
            result(nil)
        case "stop":
            stopThermal()
            stop()
            result(nil)
        // ---- extensions (CHANNEL.md "Extensions"; not in C8)
        case "projectTile":
            let pts = (a["points"] as? [Any] ?? []).map { raw -> Any in
                guard let v = Self.vec3(raw) else { return NSNull() }
                let w = modelCurrent * SIMD4<Float>(v.x, v.y, v.z, 1)
                guard let s = project(SIMD3<Float>(w.x, w.y, w.z)) else { return NSNull() }
                return [s.0, s.1, s.2] as [Any]
            }
            result(pts)
        case "installArCore":
            result(false)
        case "anchorAt":
            guard let p = Self.vec3(a["posAr"]) else {
                result(nil)
                return
            }
            result(markers.anchorAt(session: session, p))
        case "pickMany":
            // Batched `pick` for lasso selection (one channel round trip
            // instead of ~120): results in the same order, null for a miss.
            let hits: [Any] = Self.points(a["points"]).map { p in
                if let p = p, let hit = pick(p) { return hit }
                return NSNull()
            }
            result(hits)
        case "depthPointAt":
            guard let x = (a["x"] as? NSNumber)?.doubleValue, let y = (a["y"] as? NSNumber)?.doubleValue else {
                result(nil)
                return
            }
            let p = CGPoint(x: x, y: y)
            guard let frame = session.currentFrame, let pv = platformView, let r = ray(p) else {
                result(nil)
                return
            }
            result(depthProbe.pointAt(session: session, frame: frame, point: p, viewSize: pv.container.bounds.size,
                                      orientation: pv.container.interfaceOrientation, rayOrigin: r.0, rayDir: r.1))
        case "refocus":
            // ARKit has no focus-at-point either: rerun with autofocus off, then
            // on again a moment later, which restarts the sweep. Same config
            // type and no reset options, so tracking and anchors continue.
            guard running else { result(false); return }
            let fixed = configuration()
            fixed.isAutoFocusEnabled = false
            session.run(fixed, options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, self.running else { return }
                self.session.run(self.configuration(), options: [])
                self.torchNeedsApply = self.torchOn
            }
            torchNeedsApply = torchOn
            result(true)
        case "setDepth":
            // Depth and the scene mesh are the costly parts; Dart turns them
            // off once the model is placed and back on for setup.
            wantDepth = (a["on"] as? Bool) ?? true
            reconfigureIfNeeded()
            result(true)
        case "setTorch":
            // Remembered while paused (re-applied on the next run's first
            // frame); the answer says whether it is applied now.
            torchOn = (a["on"] as? Bool) ?? false
            result(applyTorch())
        case "setScanOverlay":
            // The room-scan overlay: LiDAR mesh, else the plane grid. It fades
            // in or out natively; the scene mesh runs while it shows.
            scanWanted = (a["on"] as? Bool) ?? false
            scanContrast = (a["contrast"] as? Bool) ?? scanContrast
            renderer?.setScanAlpha(scanAlpha, contrast: scanContrast)
            reconfigureIfNeeded()
            result(renderer?.hasScanMaterial ?? Self.bundledMaterial("fe_scan"))
        case "pulseAt":
            // Two expanding rings where a board or corner was confirmed;
            // `tone` from Dart's depth-check verdict.
            guard let p = Self.vec3(a["posAr"]), let r = renderer, r.hasScanMaterial else {
                result(false)
                return
            }
            let n = Self.vec3(a["normalAr"]) ?? SIMD3<Float>(0, 1, 0)
            let rgb: UInt32
            switch a["tone"] as? String {
            case "ok": rgb = 0x22C55E
            case "warn": rgb = 0xF59E0B
            default: rgb = 0x38BDF8
            }
            r.pulse(at: p, normal: n, rgb: rgb)
            result(true)
        case "startRecording":
            // ARKit sessions can't be recorded in-app (Reality Composer does it)
            result(false)
        case "stopRecording":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Ends the session and resets every piece of drawing state, so the next
    /// startSession is a clean slate (matches Android).
    private func stop() {
        sessionWanted = false
        paused = false
        updateRunning()
        needsReset = true
        markers.reset(session: session)
        tiles.clear { [weak self] e in self?.renderer?.removeTile(e.hash) }
        states.clear()
        modelCurrent = matrix_identity_float4x4
        modelPlaced = false
        easeDuration = 0
        renderer?.setModelMatrix(modelCurrent)
        renderer?.setPlaced(false)
        lastFloorY = nil
        floorAnchorId = nil
        scanWanted = false
        scanAlpha = 0
        renderer?.setScanAlpha(0, contrast: scanContrast)
        scanner.reset(renderer: renderer)
        revealing = false
        runningConfig = nil
        torchOn = false
        torchNeedsApply = false
        layerMep = true
        layerStructure = true
        layerArchitecture = true
        layerGrid = true
        opacity = 1
        sectionY = nil
        renderer?.setOpacity(1, sectionY: nil)
        targetIds = nil
        targetBuild = nil
        gridGlb = nil
        pinGlb = nil
        renderer?.setGridGlb(nil, visible: true)
        renderer?.setPinsGlb(nil)
        emitTracking("stopped", nil)
    }

    private static let pinColours: [String: Int] = [
        "snag": 0xEF4444, "finding": 0xF59E0B, "clash": 0xA855F7,
        "ghostBoard": 0x38BDF8, "board": 0x22C55E, "measure": 0xF1F5F9,
    ]

    private func buildPins(_ list: [Any]) -> Data? {
        var data: [Float] = []
        var rgb: [Int32] = []
        for raw in list {
            guard let m = raw as? [String: Any], let pos = Self.vec3(m["posTile"] ?? m["pos"]) else { continue }
            let kind = m["kind"] as? String ?? "snag"
            let board = kind == "board" || kind == "ghostBoard"
            let n = Self.vec3(m["normalTile"]) ?? SIMD3<Float>(0, 0, 1)
            let alpha: Float = kind == "ghostBoard" ? 0.45 : kind == "board" ? 0.85 : 1
            data += [pos.x, pos.y, pos.z, n.x, n.y, n.z, alpha, board ? 1 : 0]
            rgb.append(Int32((m["colorRgb"] as? NSNumber)?.intValue ?? Self.pinColours[kind] ?? 0xEF4444))
        }
        if data.isEmpty { return nil }
        return FeArGeometry.overlayGlbLines(nil, floorY: 0, gridRgb: 0,
                                            pins: data.withUnsafeBufferPointer { Data(buffer: $0) },
                                            pinRgb: rgb.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    // MARK: thermal (fe_ar extension event `thermal`)

    /// ProcessInfo's thermal state as Android's PowerManager levels, so Dart
    /// pauses AR on both platforms before the OS throttles it.
    private func startThermal() {
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.emitThermal()
        }
        emitThermal()
    }

    private func stopThermal() {
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
        thermalObserver = nil
    }

    private func emitThermal() {
        let (status, level): (Int, String)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: (status, level) = (0, "none")
        case .fair: (status, level) = (1, "light")
        // .serious is where iOS starts trimming performance, which an iPhone
        // running LiDAR, the scene mesh and 60 Hz rendering reaches within
        // minutes of normal use: Android's "moderate" (Dart warns), not
        // "severe" (Dart pauses AR). .critical is the device asking apps to
        // cut work now: pause.
        case .serious: (status, level) = (2, "moderate")
        case .critical: (status, level) = (4, "critical")
        @unknown default: (status, level) = (0, "none")
        }
        emit(["type": "thermal", "status": status, "level": level])
    }

}
