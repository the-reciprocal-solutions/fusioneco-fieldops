// Pure maths for the model viewer (docs/bim-viewer.md). No three.js, no DOM,
// so `node --test test/bim_viewer_js/` checks it on any machine.
//
// Frames: everything is the tile frame of contract C2 — building-local,
// metres, Y up. The 2D plan is the tile frame's XZ plane drawn with x to the
// right and z DOWN, so a camera looking toward −Z looks "up" the plan.
//
// Camera yaw/pitch convention (radians): yaw 0 looks toward −Z; positive yaw
// turns left (counter-clockwise seen from above, like three.js' Y rotation);
// pitch 0 is level, positive looks up.

export const EYE_HEIGHT_M = 1.6;
/** Orbit section cut above the floor datum: below a typical 2.4–2.7 m ceiling, above door heads. */
export const CUT_HEIGHT_M = 2.2;
export const WALK_SPEED_MPS = 2.2;
export const MAX_PITCH = (80 * Math.PI) / 180;
export const TAP_MAX_MOVE_PX = 8;
export const TAP_MAX_MS = 350;

export function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

/** Unit view direction [x, y, z] for a yaw/pitch. */
export function dirFromYawPitch(yaw, pitch) {
  const c = Math.cos(pitch);
  return [-Math.sin(yaw) * c, Math.sin(pitch), -Math.cos(yaw) * c];
}

/** Inverse of dirFromYawPitch. A straight-down/up direction keeps yaw 0. */
export function yawPitchFromDir(dir) {
  const [x, y, z] = dir;
  const len = Math.hypot(x, y, z) || 1;
  const pitch = Math.asin(clamp(y / len, -1, 1));
  const flat = Math.hypot(x, z);
  const yaw = flat < 1e-9 ? 0 : Math.atan2(-x, -z);
  return { yaw, pitch };
}

/** The plan heading [dx, dz] (unit, XZ) of a 3D direction; null when looking straight down/up. */
export function planHeading(dir) {
  const flat = Math.hypot(dir[0], dir[2]);
  if (flat < 1e-6) return null;
  return [dir[0] / flat, dir[2] / flat];
}

/**
 * One walk step on the floor plane. `joy` is the joystick deflection
 * {x: right +, y: down +} in [-1, 1]; up on the stick walks forward.
 * Returns the new [x, y, z]; y (eye height) never changes.
 */
export function walkStep(pos, yaw, joy, dtS, speed = WALK_SPEED_MPS) {
  const mag = Math.min(1, Math.hypot(joy.x, joy.y));
  if (mag < 0.08 || dtS <= 0) return pos.slice();
  const forward = -joy.y;
  const strafe = joy.x;
  const fx = -Math.sin(yaw), fz = -Math.cos(yaw); // forward on the floor
  const rx = Math.cos(yaw), rz = -Math.sin(yaw); // right on the floor
  const k = speed * dtS;
  return [pos[0] + (fx * forward + rx * strafe) * k, pos[1], pos[2] + (fz * forward + rz * strafe) * k];
}

/** Drag-to-look: pixels → new yaw/pitch (pitch clamped). */
export function lookDrag(yaw, pitch, dxPx, dyPx, radPerPx = 0.005) {
  return { yaw: yaw - dxPx * radPerPx, pitch: clamp(pitch - dyPx * radPerPx, -MAX_PITCH, MAX_PITCH) };
}

/** A pointer down → up that didn't travel and was quick: a tap (pick), not a drag. */
export function isTap(down, up) {
  if (!down || !up) return false;
  return Math.hypot(up.x - down.x, up.y - down.y) <= TAP_MAX_MOVE_PX && up.t - down.t <= TAP_MAX_MS;
}

/**
 * Orbit framing for a floor: target at the plan centre on the floor datum,
 * camera up and back (south-east, 45° down) far enough that the whole plan
 * fits a `fovDeg` vertical field of view at `aspect`.
 * `bounds` = [minX, minZ, maxX, maxZ].
 */
export function frameFloor(bounds, datumY, fovDeg, aspect) {
  const [minX, minZ, maxX, maxZ] = bounds;
  const cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2;
  const radius = Math.max(2, Math.hypot(maxX - minX, maxZ - minZ) / 2);
  const vFov = (fovDeg * Math.PI) / 180;
  const hFov = 2 * Math.atan(Math.tan(vFov / 2) * Math.max(0.2, aspect));
  const fit = Math.min(vFov, hFov);
  const dist = (radius / Math.sin(fit / 2)) * 1.05;
  const elev = Math.PI / 4, az = Math.PI / 4;
  const target = [cx, datumY, cz];
  const position = [
    cx + dist * Math.cos(elev) * Math.sin(az),
    datumY + dist * Math.sin(elev),
    cz + dist * Math.cos(elev) * Math.cos(az),
  ];
  return { target, position, distance: dist };
}

/** Where to stand to look at a box: `back` metres from its centre along the current heading, at eye height. */
export function standOffFor(bboxMin, bboxMax, datumY, heading, eyeHeight = EYE_HEIGHT_M) {
  const c = [(bboxMin[0] + bboxMax[0]) / 2, (bboxMin[1] + bboxMax[1]) / 2, (bboxMin[2] + bboxMax[2]) / 2];
  const size = Math.max(bboxMax[0] - bboxMin[0], bboxMax[2] - bboxMin[2], 0.5);
  const back = clamp(size * 1.5 + 1.5, 2.5, 12);
  const h = heading ?? [0, -1];
  const pos = [c[0] - h[0] * back, datumY + eyeHeight, c[2] - h[1] * back];
  const dir = [c[0] - pos[0], c[1] - pos[1], c[2] - pos[2]];
  return { position: pos, ...yawPitchFromDir(dir), centre: c };
}

/**
 * The boxes of a wall polyline for the plan-massing fallback: one per
 * segment, {cx, cz, length, angle} where `angle` rotates a box lying along
 * +X onto the segment (three.js rotation.y). Zero-length segments are dropped.
 */
export function wallSegments(points) {
  const out = [];
  for (let i = 0; i + 1 < points.length; i++) {
    const [ax, az] = points[i];
    const [bx, bz] = points[i + 1];
    const dx = bx - ax, dz = bz - az;
    const length = Math.hypot(dx, dz);
    if (length < 1e-3) continue;
    out.push({ cx: (ax + bx) / 2, cz: (az + bz) / 2, length, angle: -Math.atan2(dz, dx) });
  }
  return out;
}

/**
 * The feature of a picked vertex: TEXCOORD_1.x is the tile-local index into
 * the tile's `fe.featureIds` (contract C7). Null when out of range.
 */
export function featureOfVertex(localIndexOfVertex, featureIds) {
  if (!Number.isInteger(localIndexOfVertex) || localIndexOfVertex < 0) return null;
  const id = featureIds[localIndexOfVertex];
  return Number.isInteger(id) ? id : null;
}

/** True when the pose moved enough to be worth telling Dart about (1 cm or ~0.5°). */
export function poseChanged(a, b) {
  if (!a || !b) return true;
  const dp = Math.hypot(a.pos[0] - b.pos[0], a.pos[1] - b.pos[1], a.pos[2] - b.pos[2]);
  const dd = Math.hypot(a.dir[0] - b.dir[0], a.dir[1] - b.dir[1], a.dir[2] - b.dir[2]);
  return dp > 0.01 || dd > 0.009 || a.mode !== b.mode;
}

/**
 * A two-point measurement: straight-line, horizontal (on the plan) and
 * vertical distances in metres. Fewer than two points → nulls.
 */
export function measureOf(points) {
  if (!points || points.length < 2) return { distanceM: null, horizontalM: null, verticalM: null };
  const [a, b] = points;
  const dx = b[0] - a[0], dy = b[1] - a[1], dz = b[2] - a[2];
  const r = (v) => Math.round(v * 1000) / 1000;
  return { distanceM: r(Math.hypot(dx, dy, dz)), horizontalM: r(Math.hypot(dx, dz)), verticalM: r(Math.abs(dy)) };
}
