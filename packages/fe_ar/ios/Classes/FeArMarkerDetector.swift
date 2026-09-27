import ARKit
import Vision

/// Marker observations (docs/ar-bim-overlay.md §4.2), iPhone and iPad.
/// Same pipeline as android/.../MarkerDetector.kt:
///
/// 1. Vision reads QR codes from ARKit's captured image: about 5 Hz idle,
///    then back to back while a code is being locked (~15 samples a second).
/// 2. TAG (boards printed from 2026-09-27, src/fe_tag.h): the same image's
///    luma plane is searched for the board's four AprilTag tag36h11
///    fiducials in a region around the QR (on the Vision queue, while the
///    image is still held). A tag counts only if its id is in that payload's
///    group AND it sits at one of the QR frame's corners in the image. With
///    at least 2 tags, the C core's planar PnP gives the board pose in camera
///    space, moved to world space by the camera pose of the frame the image
///    came from. Method "tag"; 0.3-2.0 m (3.0 m A3), within 40 degrees;
///    20 samples in a window of 30, spread gate 10 mm. Print scale: LiDAR
///    depth (or a tracked vertical plane) on the tag-centre ray; a median
///    scale off by more than 4 % distrusts that board's tags for the
///    session and it locks by the QR path. Android MarkerDetector.kt, same
///    constants.
/// 3. Otherwise each sample casts a ray through the QR centre from the camera pose OF
///    THE FRAME THE CODE WAS READ IN and measures the wall:
///    LiDAR scene depth, a plane fitted to the depth under the QR ("lidar",
///    works on plain painted walls); else a tracked vertical plane
///    ("plane"); else ARKit's estimated plane ("depth"); else the square's
///    own pose from its corners ("pnp", flagged, assumes the A4 board's
///    115 mm QR).
/// 4. Gates: tracking normal, 0.5-2.0 m (3.0 m for an A3 board), within 35
///    degrees of square-on.
/// 5. After 15 QR samples (tag samples: above): per-axis median, normalised mean normal, RMS spread;
///    over 15 mm -> `marker-unstable` ("hold still"); else an ARAnchor at the
///    median and one `marker` event; the payload cools down for 4 s.
final class FeArMarkerDetector {
    private struct Snapshot {
        let cameraTransform: simd_float4x4
        let fx: Float, fy: Float, cx: Float, cy: Float
        let imageWidth: Float, imageHeight: Float
        let depth: CVPixelBuffer?
        let confidence: CVPixelBuffer?
    }

    private struct Detection {
        let payload: String
        let corners: [Float] // 8: clockwise from top-left, image pixels
        let snapshot: Snapshot
        /// The board pose from its AprilTags, when found in the same image.
        let tag: FeArTagPose?
        let generation: Int
    }

    private struct Sample {
        let at: CFTimeInterval
        let centre: SIMD3<Float>
        let normal: SIMD3<Float>
        let method: String
        let distance: Float
        let viewAngle: Float
        let qrEdgeMm: Float?
        /// Tag samples: the measured wall distance over the tag pose's (print scale).
        var scale: Float? = nil
    }

    private struct Tracked {
        let anchor: ARAnchor
        var last: SIMD3<Float>
    }

    static let samplesNeeded = 15
    static let maxSpreadMm: Float = 15
    static let idleInterval: CFTimeInterval = 0.2
    static let sampleTtl: CFTimeInterval = 2.5
    static let cooldown: CFTimeInterval = 4
    static let qrEdgeA4M: Float = 0.115
    // tags (Android MarkerDetector companion; the search constants live in FeArCore.m)
    static let tagSamplesNeeded = 20
    static let tagSamplesMax = 30
    static let maxTagSpreadMm: Float = 10
    static let tagScaleTolerance: Float = 0.04
    static let qrEdgeA4Mm: Float = 115
    static let qrEdgeA3Mm: Float = 170

    private let emit: ([String: Any]) -> Void
    private let queue = DispatchQueue(label: "fe_ar.vision", qos: .userInitiated)
    private var inFlight = false
    private var lastRun: CFTimeInterval = 0
    private var pending: [Detection] = []
    private var samples: [String: [Sample]] = [:]
    private var tagSamples: [String: [Sample]] = [:]
    private var tagDistrusted = Set<String>()
    /// Bumped by reset: results of an image read before it are dropped.
    private var generation = 0
    /// Vision queue only (AprilTag isn't re-entrant).
    private var tagDetector: FeArTagDetector?
    private var tagDetectorFailed = false
    private var cooldownUntil: [String: CFTimeInterval] = [:]
    private var tracked: [UUID: Tracked] = [:]
    private var lastAnchorCheck: CFTimeInterval = 0
    var progressEvents = false

    init(emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
    }

    func onFrame(session: ARSession, frame: ARFrame, tracking: Bool) {
        let now = CACurrentMediaTime()
        if tracking, !pending.isEmpty {
            let batch = pending
            pending.removeAll()
            for d in batch where d.generation == generation { process(session: session, d, now: now) }
        }
        expire(now)
        if tracking {
            updateAnchors(frame, now: now)
            schedule(frame, now: now)
        }
    }

    private func schedule(_ frame: ARFrame, now: CFTimeInterval) {
        let locking = samples.values.contains { !$0.isEmpty } || tagSamples.values.contains { !$0.isEmpty }
        if inFlight || now - lastRun < (locking ? 0 : Self.idleInterval) { return }
        let cam = frame.camera
        let k = cam.intrinsics
        let depth = frame.smoothedSceneDepth ?? frame.sceneDepth
        let snapshot = Snapshot(
            cameraTransform: cam.transform,
            fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
            imageWidth: Float(cam.imageResolution.width), imageHeight: Float(cam.imageResolution.height),
            depth: depth?.depthMap, confidence: depth?.confidenceMap
        )
        let image = frame.capturedImage // retained only while Vision runs; never the ARFrame itself
        lastRun = now
        inFlight = true
        let gen = generation
        queue.async { [weak self] in
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up, options: [:])
            var found: [Detection] = []
            if (try? handler.perform([request])) != nil {
                for obs in request.results ?? [] {
                    guard let payload = obs.payloadStringValue else { continue }
                    // Vision: normalised, origin bottom-left. To image pixels, v down.
                    // TODO(slice-0): confirm with orientation .up on the raw landscape buffer.
                    let w = snapshot.imageWidth, h = snapshot.imageHeight
                    let pts = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft]
                    var corners: [Float] = []
                    for p in pts {
                        corners.append(Float(p.x) * w)
                        corners.append((1 - Float(p.y)) * h)
                    }
                    let tag = self?.tagPose(payload, corners: corners, image: image, snapshot: snapshot)
                    found.append(Detection(payload: payload, corners: corners, snapshot: snapshot, tag: tag, generation: gen))
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if gen == self.generation { self.pending.append(contentsOf: found) }
                self.inFlight = false
            }
        }
    }

    // MARK: tags (Vision queue)

    /// The board pose from its AprilTags in the captured image's luma plane
    /// (ARKit's 420f buffer, plane 0, the same pixels Vision read), or nil.
    private func tagPose(_ payload: String, corners: [Float], image: CVPixelBuffer, snapshot s: Snapshot) -> FeArTagPose? {
        if tagDetector == nil && !tagDetectorFailed {
            tagDetector = FeArTagDetector.create()
            tagDetectorFailed = tagDetector == nil
        }
        guard let detector = tagDetector, CVPixelBufferGetPlaneCount(image) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(image, 0), h = CVPixelBufferGetHeightOfPlane(image, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        return corners.withUnsafeBufferPointer { qr in
            detector.boardPose(forPayload: payload, qrCorners: qr.baseAddress!, luma: base.assumingMemoryBound(to: UInt8.self),
                               width: w, height: h, bytesPerRow: row, fx: s.fx, fy: s.fy, cx: s.cx, cy: s.cy)
        }
    }

    // MARK: samples (main thread)

    private func processTag(session: ARSession, _ d: Detection, _ tag: FeArTagPose, now: CFTimeInterval) {
        let s = d.snapshot
        let origin = SIMD3<Float>(s.cameraTransform.columns.3.x, s.cameraTransform.columns.3.y, s.cameraTransform.columns.3.z)
        let centre = Self.transform(s.cameraTransform, tag.centre)
        var n = simd_normalize(Self.rotate(s.cameraTransform, tag.normal))
        let toCam = origin - centre
        if simd_dot(n, toCam) < 0 { n = -n }
        let distance = simd_length(toCam)
        let viewAngle = acos(max(-1, min(1, simd_dot(n, simd_normalize(toCam))))) * 180 / .pi

        // Print scale: the wall's own measured distance along the same ray.
        // LiDAR depth plays Android's DepthPoint (precise enough to report as
        // qrEdgeMm); a tracked vertical plane only gates the tags.
        var scale: Float?
        var depthScale = false
        if let z = Self.depthAt(s, cameraPoint: tag.centre), tag.centre.z < -0.1 {
            scale = z / -tag.centre.z
            depthScale = true
        } else if distance > 1e-6 {
            let q = ARRaycastQuery(origin: origin, direction: (centre - origin) / distance, allowing: .existingPlaneGeometry, alignment: .vertical)
            if let hit = session.raycast(q).first {
                let p = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
                let hd = simd_distance(p, origin)
                if hd > 0.1 { scale = hd / distance }
            }
        }
        let qrEdgeMm: Float? = depthScale ? scale.map { (tag.a3 ? Self.qrEdgeA3Mm : Self.qrEdgeA4Mm) * $0 } : nil

        let maxDistance: Float = tag.a3 ? 3.0 : 2.0
        let gate: String?
        if distance < 0.3 { gate = "tooClose" } else if distance > maxDistance { gate = "tooFar" } else if viewAngle > 40 { gate = "angle" } else { gate = nil }
        var list = tagSamples[d.payload] ?? []
        if gate == nil {
            list.append(Sample(at: now, centre: centre, normal: n, method: "tag", distance: distance, viewAngle: viewAngle,
                               qrEdgeMm: qrEdgeMm, scale: scale))
            if list.count > Self.tagSamplesMax { list.removeFirst(list.count - Self.tagSamplesMax) }
        }
        tagSamples[d.payload] = list
        progress(d.payload, list.count, Self.tagSamplesNeeded, distance, viewAngle, gate)
        if list.count < Self.tagSamplesNeeded { return }
        // A mis-scaled print moves a tag pose along the view ray by the same
        // factor: distrust the tags for this board, let the QR path lock it.
        let scales = list.compactMap { $0.scale }
        if scales.count >= list.count / 2, abs(Self.median(scales) - 1) > Self.tagScaleTolerance {
            tagDistrusted.insert(d.payload)
            tagSamples[d.payload] = nil
            return
        }
        finish(session: session, payload: d.payload, list: list, now: now, tag: true)
    }

    /// LiDAR depth (metres along -Z) at a camera-space point's pixel: the
    /// median of the confident pixels in a 3x3 window, or nil.
    private static func depthAt(_ s: Snapshot, cameraPoint c: SIMD3<Float>) -> Float? {
        guard let depth = s.depth, c.z < 0 else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let conf = s.confidence { CVPixelBufferLockBaseAddress(conf, .readOnly) }
        defer { if let conf = s.confidence { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
        let rowFloats = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let depths = base.assumingMemoryBound(to: Float32.self)
        let confBase = s.confidence.flatMap { CVPixelBufferGetBaseAddress($0) }?.assumingMemoryBound(to: UInt8.self)
        let confRow = s.confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        // camera space -> image pixels (inverse of the unprojection used above)
        let u = s.cx + s.fx * c.x / -c.z, v = s.cy - s.fy * c.y / -c.z
        let du = Int(u * Float(dw) / s.imageWidth), dv = Int(v * Float(dh) / s.imageHeight)
        guard du >= 0, dv >= 0, du < dw, dv < dh else { return nil }
        var ds: [Float] = []
        for y in max(0, dv - 1)...min(dh - 1, dv + 1) {
            for x in max(0, du - 1)...min(dw - 1, du + 1) {
                if let cb = confBase, cb[y * confRow + x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let z = depths[y * rowFloats + x]
                if z.isFinite, z > 0.1, z < 6 { ds.append(z) }
            }
        }
        return ds.count >= 3 ? median(ds) : nil
    }

    private func progress(_ payload: String, _ count: Int, _ needed: Int, _ distance: Float, _ viewAngle: Float, _ gate: String?) {
        guard progressEvents else { return }
        emit([
            "type": "markerProgress", "rawPayload": payload, "samples": count, "needed": needed,
            "distanceM": Double(distance), "viewAngleDeg": Double(viewAngle), "gate": gate ?? "ok",
        ])
    }

    private func process(session: ARSession, _ d: Detection, now: CFTimeInterval) {
        if (cooldownUntil[d.payload] ?? 0) > now { return }
        if let tag = d.tag, !tagDistrusted.contains(d.payload) {
            processTag(session: session, d, tag, now: now)
            return
        }
        let s = d.snapshot
        guard let centrePx = Self.diagonalCentre(d.corners) else { return }
        let dirCam = SIMD3<Float>((centrePx.x - s.cx) / s.fx, -(centrePx.y - s.cy) / s.fy, -1)
        let origin = SIMD3<Float>(s.cameraTransform.columns.3.x, s.cameraTransform.columns.3.y, s.cameraTransform.columns.3.z)
        let dirWorld = simd_normalize(Self.rotate(s.cameraTransform, dirCam))

        var centre: SIMD3<Float>?
        var normal: SIMD3<Float>?
        var method = "pnp"
        var qrEdgeMm: Float?

        // 1) LiDAR: a plane fitted to the measured depth under the QR
        if let plane = lidarPlane(s, corners: d.corners, dirCam: dirCam) {
            let (cCam, nCam) = plane
            centre = Self.transform(s.cameraTransform, cCam)
            normal = Self.rotate(s.cameraTransform, nCam)
            method = "lidar"
            let e = d.corners.withUnsafeBufferPointer {
                FeArGeometry.squareEdgeCorners($0.baseAddress!, fx: s.fx, fy: s.fy, cx: s.cx, cy: s.cy, planePoint: cCam, planeNormal: nCam)
            }
            if e > 0 { qrEdgeMm = e * 1000 }
        }
        // 2) a tracked vertical plane, 3) ARKit's estimated plane
        if centre == nil {
            for (target, label) in [(ARRaycastQuery.Target.existingPlaneGeometry, "plane"), (.estimatedPlane, "depth")] {
                let q = ARRaycastQuery(origin: origin, direction: dirWorld, allowing: target, alignment: .vertical)
                if let r = session.raycast(q).first {
                    let t = r.worldTransform
                    centre = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                    normal = SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)
                    method = label
                    break
                }
            }
        }
        // 4) the square's own pose
        if centre == nil {
            var cCam = SIMD3<Float>(repeating: 0), nCam = SIMD3<Float>(repeating: 0)
            var dist: Float = 0
            let ok = d.corners.withUnsafeBufferPointer {
                FeArGeometry.squarePoseCorners($0.baseAddress!, fx: s.fx, fy: s.fy, cx: s.cx, cy: s.cy, edgeM: Self.qrEdgeA4M,
                                               centre: &cCam, normal: &nCam, distance: &dist)
            }
            guard ok else { return }
            centre = Self.transform(s.cameraTransform, cCam)
            normal = Self.rotate(s.cameraTransform, nCam)
            method = "pnp"
        }
        guard let c = centre, var n = normal.map({ simd_normalize($0) }) else { return }
        let toCam = origin - c
        if simd_dot(n, toCam) < 0 { n = -n }
        let distance = simd_length(toCam)
        let viewAngle = acos(max(-1, min(1, simd_dot(n, simd_normalize(toCam))))) * 180 / .pi

        let maxDistance: Float = (qrEdgeMm ?? 0) >= 150 ? 3.0 : 2.0
        let gate: String?
        if distance < 0.5 { gate = "tooClose" } else if distance > maxDistance { gate = "tooFar" } else if viewAngle > 35 { gate = "angle" } else { gate = nil }

        var list = samples[d.payload] ?? []
        if gate == nil {
            list.append(Sample(at: now, centre: c, normal: n, method: method, distance: distance, viewAngle: viewAngle, qrEdgeMm: qrEdgeMm))
            if list.count > 30 { list.removeFirst(list.count - 30) }
        }
        samples[d.payload] = list
        progress(d.payload, list.count, Self.samplesNeeded, distance, viewAngle, gate)
        if list.count >= Self.samplesNeeded { finish(session: session, payload: d.payload, list: list, now: now, tag: false) }
    }

    /// `tag`: the list is the payload's tag samples (10 mm gate), else its QR samples (15 mm).
    private func finish(session: ARSession, payload: String, list: [Sample], now: CFTimeInterval, tag: Bool) {
        let centre = SIMD3<Float>(Self.median(list.map { $0.centre.x }), Self.median(list.map { $0.centre.y }), Self.median(list.map { $0.centre.z }))
        let normal = simd_normalize(list.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.normal })
        let sq = list.reduce(Float(0)) { acc, s in acc + simd_length_squared(s.centre - centre) }
        let spreadMm = (sq / Float(list.count)).squareRoot() * 1000
        if spreadMm > (tag ? Self.maxTagSpreadMm : Self.maxSpreadMm) {
            emit(["type": "error", "code": "marker-unstable", "detail": String(format: "%@ spread %.1f mm: hold still", payload, spreadMm)])
            let kept = Array(list.suffix(list.count - list.count / 2))
            if tag { tagSamples[payload] = kept } else { samples[payload] = kept }
            return
        }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(centre.x, centre.y, centre.z, 1)
        let anchor = ARAnchor(name: "fe-marker", transform: t)
        session.add(anchor: anchor)
        tracked[anchor.identifier] = Tracked(anchor: anchor, last: centre)
        // The weakest method seen decides the label; tag samples are never
        // mixed with the others (separate lists), so a tag lock is "tag".
        let method = list.contains { $0.method == "pnp" } ? "pnp"
            : list.contains { $0.method == "depth" } ? "depth"
            : list.allSatisfy { $0.method == "tag" } ? "tag"
            : list.contains { $0.method == "plane" } ? "plane" : "lidar"
        let edges = list.compactMap { $0.qrEdgeMm }
        emit([
            "type": "marker",
            "rawPayload": payload,
            "anchorId": anchor.identifier.uuidString,
            "centreAr": [Double(centre.x), Double(centre.y), Double(centre.z)],
            "normalAr": [Double(normal.x), Double(normal.y), Double(normal.z)],
            "method": method,
            "spreadMm": Double(spreadMm),
            "distanceM": Double(Self.median(list.map { $0.distance })),
            "viewAngleDeg": Double(Self.median(list.map { $0.viewAngle })),
            "qrEdgeMm": edges.count >= list.count / 2 ? Double(Self.median(edges)) as Any : NSNull(),
        ])
        samples[payload] = nil
        tagSamples[payload] = nil
        cooldownUntil[payload] = now + Self.cooldown
    }

    /// Anchor refinements (boards and `anchorAt` corners), at most 2 Hz, only
    /// when an anchor moved over 1 mm. Polled from the frame like Android's
    /// MarkerDetector.updateAnchors: the old `didUpdate anchors` hook dropped
    /// a whole batch when it arrived inside the 0.5 s throttle, and a move that
    /// wasn't followed by another update was then never reported.
    private func updateAnchors(_ frame: ARFrame, now: CFTimeInterval) {
        if tracked.isEmpty || now - lastAnchorCheck < 0.5 { return }
        lastAnchorCheck = now
        for a in frame.anchors {
            guard var t = tracked[a.identifier] else { continue }
            let p = SIMD3<Float>(a.transform.columns.3.x, a.transform.columns.3.y, a.transform.columns.3.z)
            if simd_distance(p, t.last) > 0.001 {
                t.last = p
                tracked[a.identifier] = t
                emit(["type": "anchor", "anchorId": a.identifier.uuidString, "posAr": [Double(p.x), Double(p.y), Double(p.z)]])
            }
        }
    }

    /// A native anchor at `p` (a committed corner snap, CHANNEL.md `anchorAt`),
    /// refined and reported like a board's. ARKit's `add(anchor:)` can't fail
    /// synchronously, so the Android "tracker refused" case is mapped to
    /// "tracking isn't normal right now" (ARCore throws NotTrackingException then).
    func anchorAt(session: ARSession, _ p: SIMD3<Float>) -> String? {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState else {
            emit(["type": "error", "code": "anchor-failed", "detail": "tracking is not normal"])
            return nil
        }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        let anchor = ARAnchor(name: "fe-corner", transform: t)
        session.add(anchor: anchor)
        tracked[anchor.identifier] = Tracked(anchor: anchor, last: p)
        return anchor.identifier.uuidString
    }

    func anchorsRemoved(_ anchors: [ARAnchor]) {
        for a in anchors { tracked[a.identifier] = nil }
    }

    func reset(session: ARSession?) {
        if let s = session { for t in tracked.values { s.remove(anchor: t.anchor) } }
        tracked.removeAll()
        generation += 1
        samples.removeAll()
        tagSamples.removeAll()
        tagDistrusted.removeAll()
        pending.removeAll()
        cooldownUntil.removeAll()
    }

    private func expire(_ now: CFTimeInterval) {
        for (k, v) in samples {
            let kept = v.filter { now - $0.at <= Self.sampleTtl }
            samples[k] = kept.isEmpty ? nil : kept
        }
        for (k, v) in tagSamples {
            let kept = v.filter { now - $0.at <= Self.sampleTtl }
            tagSamples[k] = kept.isEmpty ? nil : kept
        }
    }

    // MARK: LiDAR

    /// Plane under the QR from scene depth, camera space: (centre on the
    /// centre ray, normal). Nil without depth, with too few confident samples,
    /// or when the patch isn't flat (RMS over 1 cm).
    private func lidarPlane(_ s: Snapshot, corners: [Float], dirCam: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard let depth = s.depth else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let conf = s.confidence { CVPixelBufferLockBaseAddress(conf, .readOnly) }
        defer { if let conf = s.confidence { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
        let rowFloats = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let depths = base.assumingMemoryBound(to: Float32.self)
        let confBase = s.confidence.flatMap { CVPixelBufferGetBaseAddress($0) }?.assumingMemoryBound(to: UInt8.self)
        let confRow = s.confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let sx = Float(dw) / s.imageWidth, sy = Float(dh) / s.imageHeight

        // the QR's bounding box in depth pixels, inset 15% to stay on the board
        let xs = stride(from: 0, to: 8, by: 2).map { corners[$0] * sx }
        let ys = stride(from: 1, to: 8, by: 2).map { corners[$0] * sy }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        let ix = (x1 - x0) * 0.15, iy = (y1 - y0) * 0.15
        let u0 = max(0, Int(x0 + ix)), u1 = min(dw - 1, Int(x1 - ix))
        let v0 = max(0, Int(y0 + iy)), v1 = min(dh - 1, Int(y1 - iy))
        guard u1 >= u0, v1 >= v0 else { return nil }
        var pts: [Float] = []
        for v in v0...v1 {
            for u in u0...u1 {
                if let cb = confBase, cb[v * confRow + u] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let z = depths[v * rowFloats + u]
                guard z.isFinite, z > 0.2, z < 5 else { continue }
                let px = (Float(u) + 0.5) / sx, py = (Float(v) + 0.5) / sy // back to image pixels
                pts.append((px - s.cx) / s.fx * z)
                pts.append(-(py - s.cy) / s.fy * z)
                pts.append(-z)
            }
        }
        guard pts.count >= 3 * 8 else { return nil }
        var centroid = SIMD3<Float>(repeating: 0), n = SIMD3<Float>(repeating: 0)
        var rms: Float = 0
        let data = pts.withUnsafeBufferPointer { Data(buffer: $0) }
        guard FeArGeometry.fitPlane(data, centroid: &centroid, normal: &n, rms: &rms), rms < 0.01 else { return nil }
        let den = simd_dot(n, dirCam)
        guard abs(den) > 1e-4 else { return nil }
        let t = simd_dot(n, centroid) / den
        guard t > 0 else { return nil }
        return (dirCam * t, n)
    }

    // MARK: helpers

    static func transform(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    static func rotate(_ m: simd_float4x4, _ d: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(d.x, d.y, d.z, 0)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    static func median(_ v: [Float]) -> Float {
        if v.isEmpty { return 0 }
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Intersection of the diagonals (0-2, 1-3).
    static func diagonalCentre(_ c: [Float]) -> SIMD2<Float>? {
        let x1 = c[0], y1 = c[1], x2 = c[4], y2 = c[5], x3 = c[2], y3 = c[3], x4 = c[6], y4 = c[7]
        let den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if abs(den) < 1e-6 { return nil }
        let t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        return SIMD2<Float>(x1 + t * (x2 - x1), y1 + t * (y2 - y1))
    }
}
