import 'dart:math' as math;

import '../network/envelope.dart' show asDouble;

/// Small immutable vector and matrix types for the AR core (docs/ar-bim-overlay.md
/// §3–4). Deliberately not `vector_math`: that package's types are mutable
/// (every `+` allocates, but `add` mutates in place), and one accidental
/// in-place edit of a shared marker position is exactly the kind of frame bug
/// §3 warns about. These are values: every operation returns a new instance.
///
/// Conventions (CONTRACT C2):
/// - The tile frame and AR world are **Y-up**, metres.
/// - [Mat4] is **column-major**, 16 doubles, the same order as glTF,
///   Filament, three.js and web-ifc's `GetCoordinationMatrix()`. Element
///   (row r, column c) lives at index `c * 4 + r`; the translation is at
///   indices 12, 13, 14.
class Vec2 {
  const Vec2(this.x, this.y);

  static const zero = Vec2(0, 0);

  final double x;

  /// On the floor plane this is the tile frame's **z**: a `Vec2` built from a
  /// [Vec3] via [Vec3.xz] carries (x, z), matching the server's `[x, z]`
  /// arrays (corner faces, grid lines, plan polylines).
  final double y;

  /// Tolerant parse of `[x, y]`, `{x, y}` or `{x, z}` (numbers may arrive as
  /// strings). Null when the shape is wrong.
  static Vec2? tryParse(dynamic raw) {
    if (raw is List && raw.length >= 2) {
      final x = asDouble(raw[0]);
      final y = asDouble(raw[1]);
      return x == null || y == null ? null : Vec2(x, y);
    }
    if (raw is Map) {
      final x = asDouble(raw['x']);
      final y = asDouble(raw['y'] ?? raw['z']);
      return x == null || y == null ? null : Vec2(x, y);
    }
    return null;
  }

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);
  Vec2 operator -() => Vec2(-x, -y);

  double dot(Vec2 o) => x * o.x + y * o.y;

  /// The z component of the 3D cross product: positive when [o] is
  /// counter-clockwise from this in a right-handed (x, y) plane.
  double cross(Vec2 o) => x * o.y - y * o.x;

  double get length => math.sqrt(x * x + y * y);

  Vec2 get normalized {
    final l = length;
    return l < 1e-12 ? Vec2.zero : Vec2(x / l, y / l);
  }

  double distanceTo(Vec2 o) => (this - o).length;

  List<double> toList() => [x, y];

  @override
  bool operator ==(Object other) => other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2(${x.toStringAsFixed(4)}, ${y.toStringAsFixed(4)})';
}

class Vec3 {
  const Vec3(this.x, this.y, this.z);

  static const zero = Vec3(0, 0, 0);
  static const up = Vec3(0, 1, 0);

  final double x;
  final double y;
  final double z;

  /// Tolerant parse of `[x, y, z]` or `{x, y, z}`; numbers may arrive as
  /// strings (Sequelize DECIMAL). Null when the shape is wrong, so a bad row
  /// is skipped rather than drawn at the origin.
  static Vec3? tryParse(dynamic raw) {
    if (raw is List && raw.length >= 3) {
      final x = asDouble(raw[0]);
      final y = asDouble(raw[1]);
      final z = asDouble(raw[2]);
      return x == null || y == null || z == null ? null : Vec3(x, y, z);
    }
    if (raw is Map) {
      final x = asDouble(raw['x']);
      final y = asDouble(raw['y']);
      final z = asDouble(raw['z']);
      return x == null || y == null || z == null ? null : Vec3(x, y, z);
    }
    return null;
  }

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  Vec3 operator -() => Vec3(-x, -y, -z);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get length => math.sqrt(x * x + y * y + z * z);

  Vec3 get normalized {
    final l = length;
    return l < 1e-12 ? Vec3.zero : Vec3(x / l, y / l, z / l);
  }

  double distanceTo(Vec3 o) => (this - o).length;

  /// Horizontal (floor-plane) projection as a [Vec2] of (x, z).
  Vec2 get xz => Vec2(x, z);

  /// Horizontal distance, ignoring height. Most AR decisions (tile radius,
  /// corner matching, marker spread) are about where on the floor something
  /// is, not how high.
  double distanceXzTo(Vec3 o) {
    final dx = x - o.x;
    final dz = z - o.z;
    return math.sqrt(dx * dx + dz * dz);
  }

  Vec3 withY(double newY) => Vec3(x, newY, z);

  List<double> toList() => [x, y, z];

  @override
  bool operator ==(Object other) =>
      other is Vec3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(4)}, ${y.toStringAsFixed(4)}, ${z.toStringAsFixed(4)})';
}

/// A 4×4 affine transform, column-major. Immutable: [values] is unmodifiable.
class Mat4 {
  Mat4(List<double> values)
      : assert(values.length == 16, 'Mat4 needs 16 values'),
        values = List<double>.unmodifiable(values);

  factory Mat4.identity() => Mat4(const [
        1, 0, 0, 0, //
        0, 1, 0, 0, //
        0, 0, 1, 0, //
        0, 0, 0, 1, //
      ]);

  /// Rotation about +Y by [yawRad] followed by translation [t] (CONTRACT C2):
  /// `x' = x·cos + z·sin`, `z' = −x·sin + z·cos`. This is the only shape of
  /// transform the 4-DoF alignment ever produces.
  factory Mat4.fromYawTranslation(double yawRad, Vec3 t) {
    final c = math.cos(yawRad);
    final s = math.sin(yawRad);
    return Mat4([
      c, 0, -s, 0, // column 0
      0, 1, 0, 0, // column 1
      s, 0, c, 0, // column 2
      t.x, t.y, t.z, 1, // column 3
    ]);
  }

  /// Tolerant parse of a 16-number JSON list (numbers may be strings). Null
  /// for any other shape — a build without a coordination matrix must be
  /// visible as "missing", never silently treated as identity.
  static Mat4? tryParse(dynamic raw) {
    if (raw is! List || raw.length != 16) return null;
    final out = <double>[];
    for (final v in raw) {
      final d = asDouble(v);
      if (d == null) return null;
      out.add(d);
    }
    return Mat4(out);
  }

  final List<double> values;

  double operator [](int i) => values[i];

  /// Element at (row, column).
  double at(int row, int col) => values[col * 4 + row];

  Vec3 get translation => Vec3(values[12], values[13], values[14]);

  /// `this · other` — applying the result to a point applies [other] first.
  Mat4 multiply(Mat4 other) {
    final a = values;
    final b = other.values;
    final out = List<double>.filled(16, 0);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += a[k * 4 + r] * b[c * 4 + k];
        }
        out[c * 4 + r] = sum;
      }
    }
    return Mat4(out);
  }

  Mat4 operator *(Mat4 other) => multiply(other);

  /// Inverse of a rigid transform `[R | t]` as `[Rᵀ | −Rᵀt]`. Only valid for
  /// rotation + translation (no scale or shear), which is every matrix in
  /// this feature: web-ifc's coordination matrix is in metres after unit
  /// scaling (CONTRACT C2), and the alignment fit is yaw + translation. Cheap
  /// and exact, unlike a general 4×4 inverse.
  Mat4 invertRigid() {
    final m = values;
    // Rᵀ: row r of the inverse's rotation = column r of R.
    final r00 = m[0], r10 = m[1], r20 = m[2];
    final r01 = m[4], r11 = m[5], r21 = m[6];
    final r02 = m[8], r12 = m[9], r22 = m[10];
    final tx = m[12], ty = m[13], tz = m[14];
    final ix = -(r00 * tx + r10 * ty + r20 * tz);
    final iy = -(r01 * tx + r11 * ty + r21 * tz);
    final iz = -(r02 * tx + r12 * ty + r22 * tz);
    return Mat4([
      r00, r01, r02, 0, // column 0 of Rᵀ = row 0 of R
      r10, r11, r12, 0,
      r20, r21, r22, 0,
      ix, iy, iz, 1,
    ]);
  }

  /// True when the upper 3×3 is a rotation (orthonormal columns) and the
  /// bottom row is (0, 0, 0, 1): [invertRigid] is then exact. A "Place by
  /// hand" transform with a scale other than 100 % is not
  /// (`manual_place_math.dart`).
  bool get isRigid {
    final m = values;
    const eps = 1e-6;
    double dot(int a, int b) => m[a] * m[b] + m[a + 1] * m[b + 1] + m[a + 2] * m[b + 2];
    return (dot(0, 0) - 1).abs() < eps &&
        (dot(4, 4) - 1).abs() < eps &&
        (dot(8, 8) - 1).abs() < eps &&
        dot(0, 4).abs() < eps &&
        dot(0, 8).abs() < eps &&
        dot(4, 8).abs() < eps &&
        m[3].abs() < eps &&
        m[7].abs() < eps &&
        m[11].abs() < eps &&
        (m[15] - 1).abs() < eps;
  }

  /// Inverse of an affine transform `[A | t]` (any invertible 3×3, so scale
  /// and stretch too), or null when singular. [invertRigid] stays the fast
  /// path for the rigid matrices everything else produces.
  Mat4? invertAffine() {
    final m = values;
    final a = m[0], b = m[4], c = m[8];
    final d = m[1], e = m[5], f = m[9];
    final g = m[2], h = m[6], i = m[10];
    final co00 = e * i - f * h, co01 = -(d * i - f * g), co02 = d * h - e * g;
    final det = a * co00 + b * co01 + c * co02;
    if (det.abs() < 1e-12) return null;
    final k = 1 / det;
    // Inverse = adjugate / det; adjugate = transposed cofactors.
    final i00 = co00 * k, i01 = -(b * i - c * h) * k, i02 = (b * f - c * e) * k;
    final i10 = co01 * k, i11 = (a * i - c * g) * k, i12 = -(a * f - c * d) * k;
    final i20 = co02 * k, i21 = -(a * h - b * g) * k, i22 = (a * e - b * d) * k;
    final tx = m[12], ty = m[13], tz = m[14];
    return Mat4([
      i00, i10, i20, 0, // column 0
      i01, i11, i21, 0,
      i02, i12, i22, 0,
      -(i00 * tx + i01 * ty + i02 * tz), -(i10 * tx + i11 * ty + i12 * tz), -(i20 * tx + i21 * ty + i22 * tz), 1,
    ]);
  }

  /// [invertRigid] when this is rigid, else [invertAffine] (falling back to
  /// the rigid inverse for a singular matrix, which never comes out of the
  /// placement code: scale is clamped to 50–200 %).
  Mat4 inverse() => isRigid ? invertRigid() : (invertAffine() ?? invertRigid());

  Vec3 transformPoint(Vec3 p) {
    final m = values;
    return Vec3(
      m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
      m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
      m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
    );
  }

  /// Rotation only — for normals and face directions.
  Vec3 transformDir(Vec3 d) {
    final m = values;
    return Vec3(
      m[0] * d.x + m[4] * d.y + m[8] * d.z,
      m[1] * d.x + m[5] * d.y + m[9] * d.z,
      m[2] * d.x + m[6] * d.y + m[10] * d.z,
    );
  }

  List<double> toList() => List<double>.of(values);

  /// Element-wise comparison within [eps], for tests and change detection
  /// (skip a `setModelTransform` that would not move anything).
  bool closeTo(Mat4 other, {double eps = 1e-9}) {
    for (var i = 0; i < 16; i++) {
      if ((values[i] - other.values[i]).abs() > eps) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (other is! Mat4) return false;
    for (var i = 0; i < 16; i++) {
      if (values[i] != other.values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(values);

  @override
  String toString() => 'Mat4(${values.map((v) => v.toStringAsFixed(4)).join(', ')})';
}

/// Wraps an angle into (−π, π].
double wrapAngle(double a) {
  var r = a % (2 * math.pi);
  if (r > math.pi) r -= 2 * math.pi;
  if (r <= -math.pi) r += 2 * math.pi;
  return r;
}

/// Heading of a floor-plane direction (x, z) in the convention of
/// [Mat4.fromYawTranslation]: rotating a direction by yaw θ adds θ to its
/// heading. `headingOf(R(θ)·v) == headingOf(v) + θ` (mod 2π).
double headingOf(Vec2 xz) => math.atan2(-xz.y, xz.x);

/// Rotates a floor-plane direction (x, z) by [yawRad] about +Y.
Vec2 rotateXz(Vec2 xz, double yawRad) {
  final c = math.cos(yawRad);
  final s = math.sin(yawRad);
  return Vec2(xz.x * c + xz.y * s, -xz.x * s + xz.y * c);
}

double degToRad(double deg) => deg * math.pi / 180;
double radToDeg(double rad) => rad * 180 / math.pi;
