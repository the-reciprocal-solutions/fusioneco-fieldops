import ARKit
import Metal

/// Corner snapping under a screen point (docs/ar-setup-and-gamma-parity.md
/// §2.3), iPhone and iPad. Same order as android/.../CornerDetector.kt:
///
/// 1. LiDAR (iPad Pro, iPhone Pro), two sources, both method "lidar":
///    a. the reconstructed scene mesh (`sceneReconstruction =
///       .meshWithClassification`): vertices of faces ARKit classified as
///       wall (and unclassified near-vertical faces) around the pin go to the
///       C core, which fits two vertical planes with RANSAC + least squares
///       and intersects them; the floor height comes from a least-squares
///       plane through the floor-classified faces under the pin. The mesh
///       remembers walls the camera no longer sees, so it works from further
///       back than a single depth frame;
///    b. scene depth in a window around the pin, same core fit.
///    Both find the corner line even when its base is hidden behind a bin or
///    a pipe (GAMMA's "vertical snapping").
/// 2. Two tracked vertical ARPlaneAnchors whose intersection is within 0.6 m
///    of the pin. Method "planes".
/// 3. Floor tap: the pin is on the floor at the corner, heading from the one
///    wall found nearby. Method "floorTap".
///
/// y is always the floor plane's height. Coaching hints go out as throttled
/// `error` events (`corner-no-floor`, `corner-no-walls`, ...).
final class FeArCornerDetector {
    private let emit: ([String: Any]) -> Void
    private var lastHint: [String: CFTimeInterval] = [:]

    init(emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
    }

    /// point: view points (= Flutter logical pixels). ray: the world ray
    /// through it (origin on the near plane, unit direction).
    func detect(session: ARSession, frame: ARFrame, point: CGPoint, viewSize: CGSize,
                orientation: UIInterfaceOrientation, rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>) -> [String: Any]? {
        guard case .normal = frame.camera.trackingState else {
            hint("corner-not-tracking", "tracking is not ready")
            return nil
        }
        let camT = frame.camera.transform
        let camPos = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
        let floorY = Self.findFloor(planes, cameraY: camPos.y)

        // What the pin is on.
        let anyHit = session.raycast(ARRaycastQuery(origin: rayOrigin, direction: rayDir, allowing: .estimatedPlane, alignment: .any)).first
        let wallHit = session.raycast(ARRaycastQuery(origin: rayOrigin, direction: rayDir, allowing: .existingPlaneGeometry, alignment: .vertical)).first
        let floorHit = session.raycast(ARRaycastQuery(origin: rayOrigin, direction: rayDir, allowing: .existingPlaneGeometry, alignment: .horizontal)).first
        guard let aimT = (wallHit ?? anyHit ?? floorHit)?.worldTransform else {
            hint("corner-no-surface", "nothing measured under the pin yet: sweep slowly across both walls")
            return nil
        }
        let aim = SIMD3<Float>(aimT.columns.3.x, aimT.columns.3.y, aimT.columns.3.z)
        let meshes = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let meshFloorY = meshes.isEmpty ? nil : Self.meshFloor(meshes, near: aim, cameraY: camPos.y)
        guard let floor = floorY ?? meshFloorY else {
            hint("corner-no-floor", "no floor yet: point at the floor for a moment")
            return nil
        }

        if !meshes.isEmpty, let c = meshCorner(meshes, aim: aim, camPos: camPos, floorY: meshFloorY ?? floor) {
            return c
        }
        if let c = lidarCorner(frame: frame, point: point, viewSize: viewSize, orientation: orientation, aim: aim, camPos: camPos, floorY: floor) {
            return c
        }
        let walls = planes.filter { $0.alignment == .vertical }
        if let c = planesCorner(walls: walls, aimPlane: wallHit?.anchor as? ARPlaneAnchor, aim: aim, camPos: camPos, floorY: floor) {
            return c
        }
        if let f = floorHit, wallHit == nil, abs(f.worldTransform.columns.3.y - floor) < 0.1 {
            let p = SIMD3<Float>(f.worldTransform.columns.3.x, floor, f.worldTransform.columns.3.z)
            if let c = floorTap(walls: walls, at: p, camPos: camPos) { return c }
        }
        // Fewer than two tracked walls, and depth / the mesh (tried first)
        // found no corner either: plain painted walls. Dart offers wall taps
        // (depthPointAt + wall_fit.dart) on this code. Sent with or without
        // depth since 2026-09-27, as Android (CHANNEL.md).
        if walls.count < 2 {
            hint("corner-no-walls", "found \(walls.count) wall(s): tap each wall near the corner instead")
        } else {
            hint("corner-not-found", "no corner under the pin")
        }
        return nil
    }

    // MARK: LiDAR

    private func lidarCorner(frame: ARFrame, point: CGPoint, viewSize: CGSize, orientation: UIInterfaceOrientation,
                             aim: SIMD3<Float>, camPos: SIMD3<Float>, floorY: Float) -> [String: Any]? {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let depth = data.depthMap
        let conf = data.confidenceMap
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let c = conf { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer { if let c = conf { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
        let row = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let z = base.assumingMemoryBound(to: Float32.self)
        let confBase = conf.flatMap { CVPixelBufferGetBaseAddress($0) }?.assumingMemoryBound(to: UInt8.self)
        let confRow = conf.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        // view point -> normalised image point (the inverse of the display transform)
        let toImage = frame.displayTransform(for: orientation, viewportSize: viewSize).inverted()
        let ni = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height).applying(toImage)
        let u0 = Int(ni.x * CGFloat(dw)), v0 = Int(ni.y * CGFloat(dh))
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let sx = Float(dw) / Float(res.width), sy = Float(dh) / Float(res.height)
        let fx = k.columns.0.x * sx, fy = k.columns.1.y * sy, cx = k.columns.2.x * sx, cy = k.columns.2.y * sy
        let camT = frame.camera.transform
        let half = max(dw, dh) / 5
        var pts: [Float] = []
        pts.reserveCapacity((2 * half + 1) * (2 * half + 1) * 3)
        for v in max(0, v0 - half)...min(dh - 1, v0 + half) {
            for u in max(0, u0 - half)...min(dw - 1, u0 + half) {
                if let cb = confBase, cb[v * confRow + u] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let d = z[v * row + u]
                guard d.isFinite, d > 0.2, d < 6 else { continue }
                let p = camT * SIMD4<Float>((Float(u) + 0.5 - cx) / fx * d, -(Float(v) + 0.5 - cy) / fy * d, -d, 1)
                pts.append(p.x)
                pts.append(p.y)
                pts.append(p.z)
            }
        }
        guard pts.count >= 60 * 3 else { return nil }
        let blob = pts.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let c = FeArGeometry.corner(fromPoints: blob, hint: aim, camera: camPos, floorY: floorY, floorKnown: true, noiseM: 0.01) else { return nil }
        return Self.event(c, method: "lidar")
    }

    // MARK: LiDAR scene mesh

    /// Wall points from the classified scene mesh within 1.5 m (horizontally)
    /// of the aim point, fitted by the C core exactly like the depth-window
    /// points (fe_corner_from_points: RANSAC on the floor plane, then least
    /// squares, then the intersection, which must be within 0.6 m of the aim).
    private func meshCorner(_ meshes: [ARMeshAnchor], aim: SIMD3<Float>, camPos: SIMD3<Float>, floorY: Float) -> [String: Any]? {
        var pts: [Float] = []
        pts.reserveCapacity(4096 * 3)
        Self.forEachFace(meshes, near: aim, radius: 1.5) { a, b, c, cls in
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            guard len > 1e-9 else { return }
            let ny = abs(n.y / len)
            // walls, plus unclassified faces that are clearly vertical (ARKit
            // leaves fresh or cluttered wall patches as .none); never floor,
            // ceiling, table, seat, door or window faces
            let wall = cls == ARMeshClassification.wall.rawValue
            let unclassified = cls == ARMeshClassification.none.rawValue
            guard (wall && ny < 0.35) || (unclassified && ny < 0.15) else { return }
            let centroid = (a + b + c) / 3
            for p in [a, b, c, centroid] {
                pts.append(p.x)
                pts.append(p.y)
                pts.append(p.z)
            }
        }
        guard pts.count >= 60 * 3 else { return nil }
        let blob = pts.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let c = FeArGeometry.corner(fromPoints: blob, hint: aim, camera: camPos, floorY: floorY, floorKnown: true, noiseM: 0.015) else { return nil }
        return Self.event(c, method: "lidar")
    }

    /// Floor height under the aim point from the floor-classified mesh faces
    /// (least-squares plane, must be level), a standing phone's height below
    /// the camera. Nil when there aren't enough floor faces yet.
    static func meshFloor(_ meshes: [ARMeshAnchor], near aim: SIMD3<Float>, cameraY: Float) -> Float? {
        var pts: [Float] = []
        forEachFace(meshes, near: aim, radius: 1.5) { a, b, c, cls in
            guard cls == ARMeshClassification.floor.rawValue else { return }
            let centroid = (a + b + c) / 3
            let drop = cameraY - centroid.y
            guard drop > 0.5, drop < 2.5 else { return }
            pts.append(centroid.x)
            pts.append(centroid.y)
            pts.append(centroid.z)
        }
        guard pts.count >= 20 * 3 else { return nil }
        var centroid = SIMD3<Float>(repeating: 0), n = SIMD3<Float>(repeating: 0)
        var rms: Float = 0
        let data = pts.withUnsafeBufferPointer { Data(buffer: $0) }
        guard FeArGeometry.fitPlane(data, centroid: &centroid, normal: &n, rms: &rms), abs(n.y) > 0.97, rms < 0.03 else { return nil }
        // the plane's height under the aim point
        return centroid.y - (n.x * (aim.x - centroid.x) + n.z * (aim.z - centroid.z)) / n.y
    }

    /// Calls `body` with every mesh face (world-space corners and the face's
    /// ARMeshClassification raw value, 0 when the mesh carries none) whose
    /// first vertex lies within `radius` metres of `near`, horizontally.
    /// Reads ARKit's shared-storage Metal buffers directly (Apple's
    /// "Visualizing and interacting with a reconstructed scene" pattern).
    static func forEachFace(_ meshes: [ARMeshAnchor], near: SIMD3<Float>, radius: Float,
                            _ body: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Int) -> Void) {
        let r2 = radius * radius
        for anchor in meshes {
            let g = anchor.geometry
            let vertices = g.vertices
            let faces = g.faces
            guard vertices.format.rawValue == MTLVertexFormat.float3.rawValue, faces.indexCountPerPrimitive == 3,
                  faces.bytesPerIndex == 4 || faces.bytesPerIndex == 2 else { continue }
            let vBase = vertices.buffer.contents().advanced(by: vertices.offset)
            let fBase = faces.buffer.contents()
            let classes = g.classification
            let cBase = classes.map { $0.buffer.contents().advanced(by: $0.offset) }
            let t = anchor.transform
            func vertex(_ i: Int) -> SIMD3<Float> {
                let p = vBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let w = t * SIMD4<Float>(p[0], p[1], p[2], 1)
                return SIMD3<Float>(w.x, w.y, w.z)
            }
            func index(_ f: Int, _ k: Int) -> Int {
                let at = (f * 3 + k) * faces.bytesPerIndex
                return faces.bytesPerIndex == 4
                    ? Int(fBase.advanced(by: at).assumingMemoryBound(to: UInt32.self).pointee)
                    : Int(fBase.advanced(by: at).assumingMemoryBound(to: UInt16.self).pointee)
            }
            for f in 0..<faces.count {
                let i0 = index(f, 0), i1 = index(f, 1), i2 = index(f, 2)
                guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
                let a = vertex(i0)
                let dx = a.x - near.x, dz = a.z - near.z
                if dx * dx + dz * dz > r2 { continue }
                var cls = 0
                if let cb = cBase, let cs = classes, f < cs.count {
                    cls = Int(cb.advanced(by: f * cs.stride).assumingMemoryBound(to: UInt8.self).pointee)
                }
                body(a, vertex(i1), vertex(i2), cls)
            }
        }
    }

    // MARK: planes

    private func planesCorner(walls: [ARPlaneAnchor], aimPlane: ARPlaneAnchor?, aim: SIMD3<Float>, camPos: SIMD3<Float>, floorY: Float) -> [String: Any]? {
        guard walls.count >= 2 else { return nil }
        var firsts: [ARPlaneAnchor] = []
        if let a = aimPlane { firsts.append(a) }
        firsts += walls.filter { $0.identifier != aimPlane?.identifier && Self.lineDistance($0, aim) < 0.8 }
        var best: FeArCorner?
        var bestDist = Float.greatestFiniteMagnitude
        for a in firsts {
            for b in walls where b.identifier != a.identifier {
                guard let c = FeArGeometry.corner(
                    fromPlaneCentre: Self.centre(a), normal: Self.normal(a), halfExtent: Self.halfExtent(a),
                    otherCentre: Self.centre(b), otherNormal: Self.normal(b), otherHalfExtent: Self.halfExtent(b),
                    hint: aim, camera: camPos, floorY: floorY, floorKnown: true) else { continue }
                let d = simd_distance(SIMD2<Float>(c.position.x, c.position.z), SIMD2<Float>(aim.x, aim.z))
                if d < bestDist {
                    bestDist = d
                    best = c
                }
            }
        }
        return best.map { Self.event($0, method: "planes") }
    }

    // MARK: floor tap

    private func floorTap(walls: [ARPlaneAnchor], at p: SIMD3<Float>, camPos: SIMD3<Float>) -> [String: Any]? {
        guard let wall = walls.filter({ Self.lineDistance($0, p) < 0.3 }).min(by: { Self.lineDistance($0, p) < Self.lineDistance($1, p) }) else { return nil }
        let n3 = Self.normal(wall)
        var a = SIMD2<Float>(n3.x, n3.z)
        guard simd_length(a) > 1e-6 else { return nil }
        a = simd_normalize(a)
        let toCam = SIMD2<Float>(camPos.x - p.x, camPos.z - p.z)
        if simd_dot(a, toCam) < 0 { a = -a }
        var b = SIMD2<Float>(-a.y, a.x)
        if simd_dot(b, toCam) < 0 { b = -b }
        // order so cross(faceA, faceB) >= 0, as the C core does
        let (fa, fb) = a.x * b.y - a.y * b.x < 0 ? (b, a) : (a, b)
        return [
            "type": "corner",
            "posAr": [Double(p.x), Double(p.y), Double(p.z)],
            "faceAAr": [Double(fa.x), Double(fa.y)],
            "faceBAr": [Double(fb.x), Double(fb.y)],
            "angleDeg": 90.0,
            "kind": "inside",
            "method": "floorTap",
        ]
    }

    // MARK: helpers

    /// The floor: ARKit's classified floor if it has one, else the lowest
    /// horizontal plane at least 0.5 m below the camera.
    static func findFloor(_ planes: [ARPlaneAnchor], cameraY: Float) -> Float? {
        let horizontal = planes.filter { $0.alignment == .horizontal && $0.transform.columns.3.y < cameraY - 0.5 }
        if ARPlaneAnchor.isClassificationSupported {
            // pattern match, not `==`: Classification's Equatable conformance
            // is iOS 16+ and the deployment target is lower
            let floors = horizontal.filter { if case .floor = $0.classification { return true } else { return false } }
            if let f = floors.min(by: { $0.transform.columns.3.y < $1.transform.columns.3.y }) { return f.transform.columns.3.y }
        }
        return horizontal.min(by: { $0.transform.columns.3.y < $1.transform.columns.3.y })?.transform.columns.3.y
    }

    static func centre(_ a: ARPlaneAnchor) -> SIMD3<Float> {
        let c = a.transform * SIMD4<Float>(a.center.x, a.center.y, a.center.z, 1)
        return SIMD3<Float>(c.x, c.y, c.z)
    }

    static func normal(_ a: ARPlaneAnchor) -> SIMD3<Float> {
        SIMD3<Float>(a.transform.columns.1.x, a.transform.columns.1.y, a.transform.columns.1.z)
    }

    /// Half the plane's horizontal extent, from its boundary polygon.
    static func halfExtent(_ a: ARPlaneAnchor) -> Float {
        let n = normal(a)
        var u = SIMD2<Float>(-n.z, n.x)
        guard simd_length(u) > 1e-6 else { return 0.5 }
        u = simd_normalize(u)
        let c = centre(a)
        var m: Float = 0
        for v in a.geometry.boundaryVertices {
            let w = a.transform * SIMD4<Float>(v.x, v.y, v.z, 1)
            m = max(m, abs((w.x - c.x) * u.x + (w.z - c.z) * u.y))
        }
        return m > 0 ? m : 0.5
    }

    /// Horizontal distance from a point to the wall plane's infinite line.
    static func lineDistance(_ a: ARPlaneAnchor, _ p: SIMD3<Float>) -> Float {
        let c = centre(a), n = normal(a)
        let l = simd_length(SIMD2<Float>(n.x, n.z))
        if l < 1e-6 { return .greatestFiniteMagnitude }
        return abs(((p.x - c.x) * n.x + (p.z - c.z) * n.z) / l)
    }

    static func event(_ c: FeArCorner, method: String) -> [String: Any] {
        [
            "type": "corner",
            "posAr": [Double(c.position.x), Double(c.position.y), Double(c.position.z)],
            "faceAAr": [Double(c.faceA.x), Double(c.faceA.y)],
            "faceBAr": [Double(c.faceB.x), Double(c.faceB.y)],
            "angleDeg": Double(c.angleDeg),
            "kind": c.kind == 1 ? "outside" : c.kind == 2 ? "column" : "inside",
            "method": method,
            // extras (not in CornerSeenEvent; Dart ignores them)
            "spanA": Double(c.spanA),
            "spanB": Double(c.spanB),
            "rmsM": Double(c.rms),
        ]
    }

    /// The LiDAR check of a snapped corner (extension `surfaceResidualMm`):
    /// the corner line, 0.4, 0.9 and 1.4 m above the floor, against this
    /// frame's scene depth; the median residual in mm. Its base is often
    /// behind a bin or a pipe, the line above it rarely is. Outside corners
    /// and columns read the nearest depth (the edge, not the wall behind it).
    /// The event is returned unchanged without LiDAR depth.
    static func verified(_ event: [String: Any], frame: ARFrame) -> [String: Any] {
        guard let p = event["posAr"] as? [Double], p.count == 3 else { return event }
        let nearest = (event["kind"] as? String ?? "inside") != "inside"
        var rs: [Float] = []
        for h: Float in [0.4, 0.9, 1.4] {
            let w = SIMD3<Float>(Float(p[0]), Float(p[1]) + h, Float(p[2]))
            if let r = FeArDepthProbe.surfaceResidual(frame: frame, world: w, nearest: nearest) { rs.append(r) }
        }
        guard !rs.isEmpty else { return event }
        rs.sort()
        var out = event
        out["surfaceResidualMm"] = Double(rs[rs.count / 2] * 1000)
        return out
    }

    private func hint(_ code: String, _ detail: String) {
        let now = CACurrentMediaTime()
        if now - (lastHint[code] ?? 0) < 1.5 { return }
        lastHint[code] = now
        emit(["type": "error", "code": code, "detail": detail])
    }
}
