// Unit tests for assets/bim_viewer/viewer_math.js — zero dependencies:
//   node --test tool/bim_viewer/viewer_math.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import * as VM from '../../assets/bim_viewer/viewer_math.js';

const close = (a, b, eps = 1e-9) => assert.ok(Math.abs(a - b) <= eps, `${a} ≉ ${b}`);
const closeV = (a, b, eps = 1e-9) => a.forEach((v, i) => close(v, b[i], eps));

test('yaw 0 looks toward −Z (plan "up"); positive yaw turns left', () => {
  closeV(VM.dirFromYawPitch(0, 0), [0, 0, -1]);
  closeV(VM.dirFromYawPitch(Math.PI / 2, 0), [-1, 0, 0]);
  closeV(VM.dirFromYawPitch(0, Math.PI / 2), [0, 1, 0]);
});

test('yawPitchFromDir inverts dirFromYawPitch', () => {
  for (const yaw of [-2.5, -1, 0, 0.7, 3]) {
    for (const pitch of [-1.2, 0, 0.4]) {
      const r = VM.yawPitchFromDir(VM.dirFromYawPitch(yaw, pitch));
      close(Math.cos(r.yaw), Math.cos(yaw), 1e-9);
      close(Math.sin(r.yaw), Math.sin(yaw), 1e-9);
      close(r.pitch, pitch, 1e-9);
    }
  }
  assert.equal(VM.yawPitchFromDir([0, -1, 0]).yaw, 0); // straight down keeps yaw 0
});

test('planHeading is the unit XZ direction, null when looking straight down', () => {
  closeV(VM.planHeading([3, -5, 4]), [0.6, 0.8]);
  assert.equal(VM.planHeading([0, -1, 0]), null);
});

test('walkStep: stick up walks forward along the view, right strafes, height fixed', () => {
  const p0 = [1, 1.6, 2];
  closeV(VM.walkStep(p0, 0, { x: 0, y: -1 }, 1, 2), [1, 1.6, 0]); // yaw 0 → −Z
  closeV(VM.walkStep(p0, 0, { x: 1, y: 0 }, 1, 2), [3, 1.6, 2]); // right → +X
  closeV(VM.walkStep(p0, Math.PI / 2, { x: 0, y: -1 }, 0.5, 2), [0, 1.6, 2]); // facing −X
  assert.deepEqual(VM.walkStep(p0, 0, { x: 0.05, y: 0.03 }, 1), p0); // dead zone
  assert.deepEqual(VM.walkStep(p0, 0, { x: 0, y: -1 }, 0), p0);
});

test('lookDrag clamps pitch so the walker never flips over', () => {
  const r = VM.lookDrag(0, 0, 0, -100000);
  close(r.pitch, VM.MAX_PITCH);
  const s = VM.lookDrag(0, 0, 100, 0);
  close(s.yaw, -0.5);
});

test('isTap: short and still is a tap; a drag or a long press is not', () => {
  assert.equal(VM.isTap({ x: 0, y: 0, t: 0 }, { x: 5, y: 5, t: 200 }), true);
  assert.equal(VM.isTap({ x: 0, y: 0, t: 0 }, { x: 30, y: 0, t: 100 }), false);
  assert.equal(VM.isTap({ x: 0, y: 0, t: 0 }, { x: 0, y: 0, t: 900 }), false);
  assert.equal(VM.isTap(null, { x: 0, y: 0, t: 0 }), false);
});

test('frameFloor targets the plan centre on the datum and backs off to fit', () => {
  const f = VM.frameFloor([0, 0, 20, 10], 3, 60, 0.5);
  closeV(f.target, [10, 3, 5]);
  assert.ok(f.position[1] > 3 + 10, 'above the floor');
  const narrow = VM.frameFloor([0, 0, 20, 10], 3, 60, 0.5).distance;
  const wide = VM.frameFloor([0, 0, 20, 10], 3, 60, 2).distance;
  assert.ok(narrow > wide, 'a portrait (narrow) view backs off further');
});

test('standOffFor stands back along the heading at eye height, looking at the box', () => {
  const s = VM.standOffFor([4, 0, -1], [6, 2, 1], 0, [0, -1]);
  close(s.position[1], VM.EYE_HEIGHT_M);
  close(s.position[0], 5);
  assert.ok(s.position[2] > 1, 'behind the box, relative to a −Z heading');
  close(Math.sin(s.yaw), 0, 1e-9); // still facing −Z
});

test('wallSegments: one box per segment, rotated onto it; zero-length dropped', () => {
  const segs = VM.wallSegments([[0, 0], [4, 0], [4, 0], [4, 3]]);
  assert.equal(segs.length, 2);
  assert.deepEqual([segs[0].cx, segs[0].cz, segs[0].length], [2, 0, 4]);
  close(segs[0].angle, -0);
  // Segment along +Z: a box lying along +X rotated by −90° about Y ends up along +Z.
  close(segs[1].angle, -Math.PI / 2);
  // rotation.y θ maps +X to (cos θ, 0, −sin θ) → (0, 0, 1) = +Z
  close(Math.cos(segs[1].angle), 0, 1e-12);
  close(-Math.sin(segs[1].angle), 1, 1e-12);
});

test('featureOfVertex maps TEXCOORD_1.x through fe.featureIds', () => {
  assert.equal(VM.featureOfVertex(1, [41, 7, 9]), 7);
  assert.equal(VM.featureOfVertex(3, [41, 7, 9]), null);
  assert.equal(VM.featureOfVertex(-1, [41]), null);
  assert.equal(VM.featureOfVertex(0.5, [41]), null);
});

test('poseChanged ignores sub-centimetre jitter', () => {
  const a = { pos: [0, 0, 0], dir: [0, 0, -1], mode: 'walk' };
  assert.equal(VM.poseChanged(a, { ...a, pos: [0.004, 0, 0] }), false);
  assert.equal(VM.poseChanged(a, { ...a, pos: [0.02, 0, 0] }), true);
  assert.equal(VM.poseChanged(a, { ...a, mode: 'orbit' }), true);
  assert.equal(VM.poseChanged(a, null), true);
});

test('measureOf: fewer than two points is all nulls', () => {
  assert.deepEqual(VM.measureOf(undefined), { distanceM: null, horizontalM: null, verticalM: null });
  assert.deepEqual(VM.measureOf([]), { distanceM: null, horizontalM: null, verticalM: null });
  assert.deepEqual(VM.measureOf([[1, 2, 3]]), { distanceM: null, horizontalM: null, verticalM: null });
});

test('measureOf: straight-line, horizontal and vertical distances, rounded to mm', () => {
  // 3-4 on the floor plus 12 up: a 3-4-5 triangle in the horizontal plane,
  // then a 5-12-13 triangle straight-line vs. vertical.
  const m = VM.measureOf([[0, 0, 0], [3, 12, 4]]);
  assert.equal(m.horizontalM, 5);
  assert.equal(m.verticalM, 12);
  assert.equal(m.distanceM, 13);
});

test('measureOf: rounds to the millimetre and uses only the first two points', () => {
  // dx=1.2 mm, dy=0.9 mm, dz=0 → distance 1.5 mm exactly (12-9-15 triangle).
  const m = VM.measureOf([[0, 0, 0], [0.0012, 0.0009, 0], [99, 99, 99]]);
  assert.equal(m.horizontalM, 0.001);
  assert.equal(m.verticalM, 0.001);
  assert.equal(m.distanceM, 0.002);
});
