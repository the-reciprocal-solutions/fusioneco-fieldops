import ARKit

/// The room-scan overlay feed (fe_ar extension `setScanOverlay`, event
/// `scan`; CHANNEL.md). Main thread only, driven from the session's frames.
///
/// - LiDAR iPhones and iPads (scene reconstruction on): every ARMeshAnchor
///   goes to the renderer as unshared triangles tinted by ARKit's face
///   classification (wall, floor, ceiling, door, window, furniture), drawn
///   as a glowing wireframe that paints in when ARKit first reports it.
/// - Without LiDAR: the tracked ARPlaneAnchors, drawn as a world-space grid.
///
/// Uploads are throttled: at most 5 Hz, at most a few changed anchors per
/// tick (new ones first), and a face budget for the whole room, so the
/// overlay never starves the camera feed or the model. Nothing is uploaded
/// while the overlay is hidden; what is on the GPU then just stops updating.
///
/// Stats (the `scan` event, at most 1 Hz, only when they changed) report the
/// measured floor and wall area and how many floors and walls ARKit tracks;
/// Dart turns them into the setup screen's scan coverage
/// (lib/core/ar/scan_overlay.dart).
final class FeArScanner {
    static let uploadInterval: CFTimeInterval = 0.2
    static let statsInterval: CFTimeInterval = 1.0
    static let maxUploadsPerTick = 6
    static let maxFaces = 120_000
    static let vertexStride = 24 // FeArRenderer kScanStride

    /// What a surface's GPU copy was built from; a change means re-upload.
    private struct Signature: Equatable {
        let buffer: ObjectIdentifier?
        let vertices: Int
        let faces: Int
        let probe: SIMD4<Float>
    }

    private struct Uploaded {
        var signature: Signature
        var transform: simd_float4x4
        var faces: Int
    }

    private let emit: ([String: Any]) -> Void
    private var uploaded: [UUID: Uploaded] = [:]
    private var bornAt: [UUID: Double] = [:]
    private var meshAreas: [UUID: (Signature, SIMD4<Float>)] = [:] // floor, wall, ceiling, other m²
    private var lastUpload: CFTimeInterval = 0
    private var lastStats: CFTimeInterval = 0
    private var lastSent: [String: Double] = [:]
    private var lastSource: String?

    init(emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
    }

    /// The renderer was replaced or torn down: nothing of ours is on the GPU.
    func rendererChanged() {
        uploaded.removeAll()
    }

    /// stop(): forget everything (the next session is a clean slate).
    func reset(renderer: FeArRenderer?) {
        renderer?.clearScanSurfaces()
        uploaded.removeAll()
        bornAt.removeAll()
        meshAreas.removeAll()
        lastSent.removeAll()
        lastSource = nil
        lastUpload = 0
        lastStats = 0
    }

    /// One session frame. `drawing`: the overlay is showing (or fading), so
    /// keep the GPU copy current. `stats`: Dart wants `scan` events.
    func onFrame(_ frame: ARFrame, now: CFTimeInterval, seconds: Double, renderer: FeArRenderer?, drawing: Bool, stats: Bool) {
        let meshes = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
        for id in meshes.map(\.identifier) + planes.map(\.identifier) where bornAt[id] == nil {
            bornAt[id] = seconds
        }
        if drawing, let r = renderer, r.hasScanMaterial, now - lastUpload >= Self.uploadInterval {
            lastUpload = now
            upload(meshes: meshes, planes: planes, renderer: r)
        }
        if stats, now - lastStats >= Self.statsInterval {
            lastStats = now
            report(meshes: meshes, planes: planes)
        }
    }

    // MARK: upload

    private func upload(meshes: [ARMeshAnchor], planes: [ARPlaneAnchor], renderer r: FeArRenderer) {
        // The mesh supersedes the planes once ARKit has any (LiDAR); the plane
        // grid is the overlay of devices without it.
        let useMesh = !meshes.isEmpty
        var current: [(ARAnchor, Signature, Int)] = []
        if useMesh {
            for m in meshes { current.append((m, Self.signature(m), m.geometry.faces.count)) }
        } else {
            for p in planes { current.append((p, Self.signature(p), p.geometry.triangleCount)) }
        }
        let ids = Set(current.map { $0.0.identifier })
        for id in uploaded.keys where !ids.contains(id) {
            r.removeScanSurface(id.uuidString)
            uploaded[id] = nil
        }

        var budget = Self.maxFaces - uploaded.values.reduce(0) { $0 + $1.faces }
        var stale: [(ARAnchor, Signature, Int)] = []
        for item in current {
            let (anchor, sig, _) = item
            if let u = uploaded[anchor.identifier], u.signature == sig {
                if u.transform != anchor.transform {
                    r.setScanSurfaceTransform(anchor.identifier.uuidString, transform: anchor.transform)
                    uploaded[anchor.identifier]?.transform = anchor.transform
                }
            } else {
                stale.append(item)
            }
        }
        // New surfaces first (they are what "painting the room" shows), then
        // the ones ARKit refined; a handful a tick, the rest next tick.
        stale.sort { (uploaded[$0.0.identifier] == nil ? 0 : 1) < (uploaded[$1.0.identifier] == nil ? 0 : 1) }
        for (anchor, sig, faces) in stale.prefix(Self.maxUploadsPerTick) {
            let previous = uploaded[anchor.identifier]?.faces ?? 0
            if faces - previous > budget { continue }
            let data: Data?
            if let m = anchor as? ARMeshAnchor {
                data = Self.meshVertices(m)
            } else if let p = anchor as? ARPlaneAnchor {
                data = Self.planeVertices(p)
            } else {
                data = nil
            }
            guard let d = data else { continue }
            r.setScanSurface(anchor.identifier.uuidString, vertices: d, transform: anchor.transform,
                             bornTime: bornAt[anchor.identifier] ?? 0, grid: !(anchor is ARMeshAnchor))
            budget -= faces - previous
            uploaded[anchor.identifier] = Uploaded(signature: sig, transform: anchor.transform, faces: faces)
        }
    }

    private static func signature(_ m: ARMeshAnchor) -> Signature {
        let g = m.geometry
        return Signature(buffer: ObjectIdentifier(g.vertices.buffer as AnyObject), vertices: g.vertices.count, faces: g.faces.count,
                         probe: SIMD4<Float>(repeating: 0))
    }

    private static func signature(_ p: ARPlaneAnchor) -> Signature {
        let v = p.geometry.vertices
        var probe = SIMD4<Float>(repeating: 0)
        if let a = v.first, let b = v.last { probe = SIMD4<Float>(a.x + b.x, a.z + b.z, a.x * b.z, Float(v.count)) }
        return Signature(buffer: nil, vertices: v.count, faces: p.geometry.triangleCount, probe: probe)
    }

    // MARK: geometry

    /// ARMeshClassification raw value -> linear RGBA8 tint (design palette,
    /// decoded from sRGB): none slate, wall cyan, floor emerald, ceiling
    /// violet, table and seat pink, window blue, door amber.
    static let tints: [SIMD4<UInt8>] = ([0x94A3B8, 0x22D3EE, 0x34D399, 0xA78BFA, 0xF472B6, 0xF472B6, 0x60A5FA, 0xFBBF24] as [UInt32])
        .map { FeArScanner.linearTint($0) }

    static func linearTint(_ hex: UInt32) -> SIMD4<UInt8> {
        func ch(_ shift: UInt32) -> UInt8 {
            let c = Double((hex >> shift) & 0xFF) / 255
            let l = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            return UInt8(max(0, min(255, (l * 255).rounded())))
        }
        return SIMD4<UInt8>(ch(16), ch(8), ch(0), 255)
    }

    /// Unshared triangles in the anchor's frame, with the barycentric corner
    /// in uv (the wireframe) and the face's class tint. Nil for a geometry
    /// in a layout this code doesn't read.
    static func meshVertices(_ m: ARMeshAnchor) -> Data? {
        let g = m.geometry
        let vertices = g.vertices, faces = g.faces
        guard vertices.format == .float3, faces.indexCountPerPrimitive == 3,
              faces.bytesPerIndex == 4 || faces.bytesPerIndex == 2, faces.count > 0 else { return nil }
        let vBase = vertices.buffer.contents().advanced(by: vertices.offset)
        let fBase = faces.buffer.contents()
        let classes = g.classification
        let cBase = classes.map { $0.buffer.contents().advanced(by: $0.offset) }
        let count = min(faces.count, maxFaces)
        var out = Data(count: count * 3 * vertexStride)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let o = raw.baseAddress else { return }
            for f in 0..<count {
                var cls = 0
                if let cb = cBase, let cs = classes, f < cs.count {
                    cls = Int(cb.advanced(by: f * cs.stride).load(as: UInt8.self))
                }
                let tint = tints[cls < tints.count ? cls : 0]
                for k in 0..<3 {
                    let at = (f * 3 + k) * faces.bytesPerIndex
                    let i = faces.bytesPerIndex == 4
                        ? Int(fBase.load(fromByteOffset: at, as: UInt32.self))
                        : Int(fBase.load(fromByteOffset: at, as: UInt16.self))
                    let dst = o.advanced(by: (f * 3 + k) * vertexStride)
                    if i < vertices.count {
                        let src = vBase.advanced(by: i * vertices.stride)
                        dst.storeBytes(of: src.load(as: Float.self), as: Float.self)
                        dst.storeBytes(of: src.load(fromByteOffset: 4, as: Float.self), toByteOffset: 4, as: Float.self)
                        dst.storeBytes(of: src.load(fromByteOffset: 8, as: Float.self), toByteOffset: 8, as: Float.self)
                    } // else: zeros, a degenerate (invisible) triangle
                    dst.storeBytes(of: tint, toByteOffset: 12, as: SIMD4<UInt8>.self)
                    dst.storeBytes(of: k == 0 ? Float(1) : 0, toByteOffset: 16, as: Float.self)
                    dst.storeBytes(of: k == 1 ? Float(1) : 0, toByteOffset: 20, as: Float.self)
                }
            }
        }
        return out
    }

    /// The plane's triangulated boundary in its anchor's frame (grid mode:
    /// uv unused), tinted as a floor, ceiling or wall.
    static func planeVertices(_ p: ARPlaneAnchor) -> Data? {
        let g = p.geometry
        let verts = g.vertices
        let tri = g.triangleIndices
        let count = tri.count - tri.count % 3
        guard count >= 3 else { return nil }
        let tint = tints[planeClass(p)]
        var out = Data(count: count * vertexStride)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let o = raw.baseAddress else { return }
            for n in 0..<count {
                let i = Int(tri[n])
                let dst = o.advanced(by: n * vertexStride)
                if i >= 0 && i < verts.count {
                    let v = verts[i]
                    dst.storeBytes(of: v.x, as: Float.self)
                    dst.storeBytes(of: v.y, toByteOffset: 4, as: Float.self)
                    dst.storeBytes(of: v.z, toByteOffset: 8, as: Float.self)
                }
                dst.storeBytes(of: tint, toByteOffset: 12, as: SIMD4<UInt8>.self)
                dst.storeBytes(of: Float(0), toByteOffset: 16, as: Float.self)
                dst.storeBytes(of: Float(0), toByteOffset: 20, as: Float.self)
            }
        }
        return out
    }

    /// A plane as an ARMeshClassification raw value (the tint index).
    static func planeClass(_ p: ARPlaneAnchor) -> Int {
        if ARPlaneAnchor.isClassificationSupported {
            switch p.classification {
            case .wall: return 1
            case .floor: return 2
            case .ceiling: return 3
            case .table, .seat: return 4
            case .window: return 6
            case .door: return 7
            default: break
            }
        }
        return p.alignment == .vertical ? 1 : 2
    }

    // MARK: stats

    private func report(meshes: [ARMeshAnchor], planes: [ARPlaneAnchor]) {
        var walls = 0, floors = 0
        var area = SIMD4<Float>(repeating: 0) // floor, wall, ceiling, other
        for p in planes {
            let a = FeArController.planeArea(p)
            switch Self.planeClass(p) {
            case 1:
                walls += 1
                if meshes.isEmpty { area[1] += a }
            case 2:
                floors += 1
                if meshes.isEmpty { area[0] += a }
            case 3:
                if meshes.isEmpty { area[2] += a }
            default:
                if meshes.isEmpty { area[3] += a }
            }
        }
        if !meshes.isEmpty {
            let live = Set(meshes.map(\.identifier))
            for id in meshAreas.keys where !live.contains(id) { meshAreas[id] = nil }
            for m in meshes {
                let sig = Self.signature(m)
                if let cached = meshAreas[m.identifier], cached.0 == sig {
                    area += cached.1
                } else {
                    let a = Self.meshAreas(m)
                    meshAreas[m.identifier] = (sig, a)
                    area += a
                }
            }
        }
        let source = meshes.isEmpty ? "planes" : "mesh"
        let now: [String: Double] = [
            "walls": Double(walls), "floors": Double(floors),
            "floorM2": Double(area[0]), "wallM2": Double(area[1]), "ceilingM2": Double(area[2]), "otherM2": Double(area[3]),
        ]
        let changed = source != lastSource || now.contains { k, v in abs(v - (lastSent[k] ?? -1)) >= (k.hasSuffix("M2") ? 0.1 : 0.5) }
        guard changed else { return }
        lastSent = now
        lastSource = source
        var event: [String: Any] = ["type": "scan", "source": source, "surfaces": walls + floors]
        for (k, v) in now { event[k] = k.hasSuffix("M2") ? (v * 100).rounded() / 100 : v }
        emit(event)
    }

    /// Face area by class: floor, wall, ceiling, everything else (m²).
    static func meshAreas(_ m: ARMeshAnchor) -> SIMD4<Float> {
        var out = SIMD4<Float>(repeating: 0)
        let g = m.geometry
        let vertices = g.vertices, faces = g.faces
        guard vertices.format == .float3, faces.indexCountPerPrimitive == 3,
              faces.bytesPerIndex == 4 || faces.bytesPerIndex == 2 else { return out }
        let vBase = vertices.buffer.contents().advanced(by: vertices.offset)
        let fBase = faces.buffer.contents()
        let classes = g.classification
        let cBase = classes.map { $0.buffer.contents().advanced(by: $0.offset) }
        func vertex(_ i: Int) -> SIMD3<Float> {
            let p = vBase.advanced(by: i * vertices.stride)
            return SIMD3<Float>(p.load(as: Float.self), p.load(fromByteOffset: 4, as: Float.self), p.load(fromByteOffset: 8, as: Float.self))
        }
        for f in 0..<faces.count {
            var idx = [0, 0, 0]
            for k in 0..<3 {
                let at = (f * 3 + k) * faces.bytesPerIndex
                idx[k] = faces.bytesPerIndex == 4
                    ? Int(fBase.load(fromByteOffset: at, as: UInt32.self))
                    : Int(fBase.load(fromByteOffset: at, as: UInt16.self))
            }
            guard idx.allSatisfy({ $0 < vertices.count }) else { continue }
            let a = vertex(idx[0]), b = vertex(idx[1]), c = vertex(idx[2])
            let area = simd_length(simd_cross(b - a, c - a)) / 2
            var cls = 0
            if let cb = cBase, let cs = classes, f < cs.count {
                cls = Int(cb.advanced(by: f * cs.stride).load(as: UInt8.self))
            }
            switch cls {
            case 2: out[0] += area
            case 1: out[1] += area
            case 3: out[2] += area
            default: out[3] += area
            }
        }
        return out
    }
}
