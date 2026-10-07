import ARKit

/// `depthPointAt {x, y}` (CHANNEL.md extension): the measured surface point
/// under a view point, for Dart's wall-taps corner (`wall_fit.dart`) and the
/// long-baseline heading tap. The iOS mirror of android/.../DepthProbe.kt,
/// same constants and the same answer shape:
///
/// 1. **rawDepth**: LiDAR `sceneDepth` (per frame, unsmoothed) with its
///    `confidenceMap` in a 9x9 window around the point; only pixels of
///    medium or high confidence, then only those within 3 % (min 30 mm) of
///    their median depth. The point is the ray through the exact point at
///    that median depth; the normal is the kept pixels' plane (smallest
///    principal axis) when the patch is flat. `confidence` = kept share x
///    mean confidence (ARKit's levels low/medium/high read as 0/0.5/1).
/// 2. **plane**: a tracked ARPlaneAnchor under the point (0.9).
/// 3. **depth**: `smoothedSceneDepth`, same window, at most 0.5 (Android's
///    smoothed image has no per-pixel confidence; kept comparable).
/// 4. **plane** again from ARKit's estimated plane (0.5): no LiDAR and no
///    tracked plane, the only measurement a non-LiDAR iPhone has.
///
/// Nothing here decides anything: Dart gates on `confidence`.
final class FeArDepthProbe {
    static let windowRadius = 4
    static let minSamples = 8
    static let minNormalSamples = 12
    static let maxDepthM: Float = 6
    static let bandMinM: Float = 0.03
    static let bandFraction: Float = 0.03
    static let flatnessMax = 0.25

    func pointAt(session: ARSession, frame: ARFrame, point: CGPoint, viewSize: CGSize,
                 orientation: UIInterfaceOrientation, rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>) -> [String: Any]? {
        guard case .normal = frame.camera.trackingState, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let t = frame.camera.transform
        let camPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // view point -> normalised captured-image point (the depth maps share its framing)
        let ni = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
            .applying(frame.displayTransform(for: orientation, viewportSize: viewSize).inverted())

        if let d = frame.sceneDepth, let r = sample(frame, d, ni, camPos, method: "rawDepth", useConfidence: true) { return r }
        if let hit = session.raycast(ARRaycastQuery(origin: rayOrigin, direction: rayDir, allowing: .existingPlaneGeometry, alignment: .any)).first,
           let plane = hit.anchor as? ARPlaneAnchor {
            let p = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
            let n = SIMD3<Float>(plane.transform.columns.1.x, plane.transform.columns.1.y, plane.transform.columns.1.z)
            return Self.result(p, Self.facing(n, p, camPos), 0.9, "plane", 0, camPos)
        }
        if let d = frame.smoothedSceneDepth, let r = sample(frame, d, ni, camPos, method: "depth", useConfidence: false) { return r }
        if let hit = session.raycast(ARRaycastQuery(origin: rayOrigin, direction: rayDir, allowing: .estimatedPlane, alignment: .any)).first {
            let w = hit.worldTransform
            let p = SIMD3<Float>(w.columns.3.x, w.columns.3.y, w.columns.3.z)
            let n = SIMD3<Float>(w.columns.1.x, w.columns.1.y, w.columns.1.z)
            return Self.result(p, Self.facing(n, p, camPos), 0.5, "plane", 0, camPos)
        }
        return nil
    }

    /// Samples one ARDepthData map around the normalised image point.
    /// Back-projection as FeArCornerDetector.lidarCorner: intrinsics scaled
    /// from the captured image to the depth map, camera looking down -Z.
    private func sample(_ frame: ARFrame, _ data: ARDepthData, _ ni: CGPoint, _ camPos: SIMD3<Float>,
                        method: String, useConfidence: Bool) -> [String: Any]? {
        let depth = data.depthMap
        let conf = data.confidenceMap
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let c = conf { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer { if let c = conf { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        let row = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let z = base.assumingMemoryBound(to: Float32.self)
        let confBase = conf.flatMap { CVPixelBufferGetBaseAddress($0) }?.assumingMemoryBound(to: UInt8.self)
        let confRow = conf.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let uf = Float(ni.x) * Float(w), vf = Float(ni.y) * Float(h)
        let u0 = Int(uf.rounded(.down)), v0 = Int(vf.rounded(.down))
        guard u0 >= 0, v0 >= 0, u0 < w, v0 < h else { return nil }
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let fx = k.columns.0.x * sx, fy = k.columns.1.y * sy, cx = k.columns.2.x * sx, cy = k.columns.2.y * sy
        let camT = frame.camera.transform

        var us: [Int] = [], vs: [Int] = [], ds: [Float] = [], cs: [Float] = []
        var total = 0
        let r = Self.windowRadius
        for v in max(0, v0 - r)...min(h - 1, v0 + r) {
            for u in max(0, u0 - r)...min(w - 1, u0 + r) {
                total += 1
                let d = z[v * row + u]
                guard d.isFinite, d > 0, d <= Self.maxDepthM else { continue }
                var c: Float = 1
                if let cb = confBase {
                    let level = cb[v * confRow + u]
                    if level < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                    c = Float(level) / Float(ARConfidenceLevel.high.rawValue)
                }
                us.append(u)
                vs.append(v)
                ds.append(d)
                cs.append(c)
            }
        }
        guard ds.count >= Self.minSamples, total > 0 else { return nil }
        let median = ds.sorted()[ds.count / 2]
        let band = max(Self.bandMinM, median * Self.bandFraction)
        var pts: [SIMD3<Float>] = []
        var confSum: Float = 0
        for i in ds.indices where abs(ds[i] - median) <= band {
            let d = ds[i]
            let p = camT * SIMD4<Float>((Float(us[i]) + 0.5 - cx) / fx * d, -(Float(vs[i]) + 0.5 - cy) / fy * d, -d, 1)
            pts.append(SIMD3<Float>(p.x, p.y, p.z))
            confSum += cs[i]
        }
        guard pts.count >= Self.minSamples else { return nil }
        let pw = camT * SIMD4<Float>((uf - cx) / fx * median, -(vf - cy) / fy * median, -median, 1)
        let pos = SIMD3<Float>(pw.x, pw.y, pw.z)
        let normal = Self.planeNormal(pts).map { Self.facing($0, pos, camPos) }
        let coverage = Float(pts.count) / Float(total)
        var confidence = useConfidence && confBase != nil ? coverage * (confSum / Float(pts.count)) : coverage * 0.5
        if !useConfidence { confidence = min(confidence, 0.5) }
        return Self.result(pos, normal, min(max(confidence, 0), 1), method, pts.count, camPos)
    }

    // MARK: LiDAR verification

    /// How far the real surface is from `world` along the camera's line of
    /// sight, in metres, as this frame's LiDAR depth measures it: positive =
    /// the surface is behind the point, negative = in front of it. Nil
    /// without scene depth (no LiDAR, or depth switched off), when the point
    /// is behind the camera, off the image, outside 0.2-5 m, or has fewer
    /// than 5 medium/high-confidence pixels in the 5x5 window around it.
    ///
    /// `nearest` reads the window's nearest confident pixel instead of its
    /// median: for an outside corner or a column edge the window straddles
    /// the edge and the far wall behind it, and the edge is the near side.
    ///
    /// The check the setup uses to say a board or a corner snap "sits on a
    /// real surface" (CHANNEL.md `surfaceResidualMm`); it reads the same
    /// depth the snap came from only in the lidar cases, and then from a
    /// later frame, so it is an independent second look.
    static func surfaceResidual(frame: ARFrame, world: SIMD3<Float>, nearest: Bool = false) -> Float? {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let cam = frame.camera
        let c4 = cam.transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        let expected = -c4.z
        guard expected > 0.2, expected < 5 else { return nil }
        let k = cam.intrinsics
        let res = cam.imageResolution
        // camera space -> captured-image pixels (sensor orientation, as the
        // intrinsics), then to the depth map's pixels
        let u = k.columns.2.x + k.columns.0.x * c4.x / expected
        let v = k.columns.2.y - k.columns.1.y * c4.y / expected
        let depth = data.depthMap
        let conf = data.confidenceMap
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let c = conf { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer { if let c = conf { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        let row = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let z = base.assumingMemoryBound(to: Float32.self)
        let confBase = conf.flatMap { CVPixelBufferGetBaseAddress($0) }?.assumingMemoryBound(to: UInt8.self)
        let confRow = conf.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let du = Int(u * Float(w) / Float(res.width)), dv = Int(v * Float(h) / Float(res.height))
        guard du >= 0, dv >= 0, du < w, dv < h else { return nil }
        var ds: [Float] = []
        for y in max(0, dv - 2)...min(h - 1, dv + 2) {
            for x in max(0, du - 2)...min(w - 1, du + 2) {
                if let cb = confBase, cb[y * confRow + x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let d = z[y * row + x]
                if d.isFinite, d > 0.1, d < 6 { ds.append(d) }
            }
        }
        guard ds.count >= 5 else { return nil }
        ds.sort()
        let measured = nearest ? ds[0] : ds[ds.count / 2]
        return measured - expected
    }

    static func result(_ pos: SIMD3<Float>, _ normal: SIMD3<Float>?, _ confidence: Float, _ method: String,
                       _ samples: Int, _ camPos: SIMD3<Float>) -> [String: Any] {
        [
            "posAr": [Double(pos.x), Double(pos.y), Double(pos.z)],
            "normalAr": normal.map { [Double($0.x), Double($0.y), Double($0.z)] as Any } ?? NSNull(),
            "confidence": Double(confidence),
            "method": method,
            // extras (Dart ignores them)
            "samples": samples,
            "distanceM": Double(simd_distance(pos, camPos)),
        ]
    }

    /// Flips `n` to face the camera.
    static func facing(_ n: SIMD3<Float>, _ at: SIMD3<Float>, _ camPos: SIMD3<Float>) -> SIMD3<Float> {
        let u = simd_normalize(n)
        return simd_dot(u, camPos - at) < 0 ? -u : u
    }

    /// The normal of the best plane through the points (smallest principal
    /// axis of their scatter, Jacobi on the 3x3 covariance), or nil when the
    /// patch isn't flat (the smallest spread is not clearly below the middle
    /// one: an edge, a corner, noise). DepthProbe.kt planeNormal, line for line.
    static func planeNormal(_ pts: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard pts.count >= minNormalSamples else { return nil }
        var m = SIMD3<Double>(repeating: 0)
        for p in pts { m += SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) }
        m /= Double(pts.count)
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in pts {
            let d = [Double(p.x) - m.x, Double(p.y) - m.y, Double(p.z) - m.z]
            for r in 0..<3 { for c in 0..<3 { a[r][c] += d[r] * d[c] } }
        }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        jacobi(&a, &v)
        let order = (0..<3).sorted { a[$0][$0] < a[$1][$1] }
        let l0 = a[order[0]][order[0]], l1 = a[order[1]][order[1]]
        if l1 <= 1e-12 || l0 / l1 > flatnessMax { return nil }
        let k = order[0]
        let n = SIMD3<Double>(v[0][k], v[1][k], v[2][k]) // eigenvectors are the columns
        let len = simd_length(n)
        if len < 1e-9 { return nil }
        return SIMD3<Float>(Float(n.x / len), Float(n.y / len), Float(n.z / len))
    }

    /// Cyclic Jacobi for a symmetric 3x3: `a` becomes diagonal, `v` collects
    /// the eigenvectors (columns).
    static func jacobi(_ a: inout [[Double]], _ v: inout [[Double]]) {
        for _ in 0..<24 {
            var off = 0.0
            for p in 0..<3 { for q in (p + 1)..<3 { off += a[p][q] * a[p][q] } }
            if off < 1e-18 { return }
            for p in 0..<3 {
                for q in (p + 1)..<3 {
                    if abs(a[p][q]) < 1e-15 { continue }
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for k in 0..<3 {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<3 {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<3 {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
    }
}
