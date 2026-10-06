// FusionEco model viewer — the 3D half of the FieldOps 2D/3D viewer
// (docs/bim-viewer.md). Runs in a WebView that the app points at its own
// loopback server (lib/core/bim_viewer/viewer_asset_server.dart), which
// serves this folder and the floor's GLB tiles from the offline tile store.
//
// Why three.js in a WebView and not Filament in packages/fe_ar: fe_ar's
// Android renderer is SceneView's ARSceneView, owned by an ARCore session,
// and the plugin isn't wired into the app yet. This path runs on every
// phone today, is licence-free (three.js and meshoptimizer are MIT), and
// sits behind the Dart `BimViewEngine` interface so a native engine can
// replace it without touching the screens.
//
// Wire (docs/bim-viewer.md §4): Dart calls `window.feViewer.run({cmd, args})`;
// the viewer answers through the `FeViewer` JavaScript channel with one
// JSON object per message: ready | tiles | pose | pick | error.
//
// Tiles are the AR tiles of contract C7 (int16 positions, meshopt, feature
// index in TEXCOORD_1, scene extras fe.{featureIds, layer, buildId}), plus
// the viewer-only `architecture_solid` layer.

import * as THREE from './vendor/three.module.min.js';
import { GLTFLoader } from './vendor/GLTFLoader.js';
import { OrbitControls } from './vendor/OrbitControls.js';
import { MeshoptDecoder } from './vendor/meshopt_decoder.module.js';
import { mergeGeometries } from './vendor/BufferGeometryUtils.js';
import * as VM from './viewer_math.js';

const LAYERS = ['mep', 'structure', 'architecture', 'architecture_solid', 'massing'];

// ── outbound messages ─────────────────────────────────────────────────────
// The Dart channel. Android injects `window.FeViewer`; on iOS the plugin
// defines it with a document-start user script (`window.FeViewer =
// webkit.messageHandlers.FeViewer`) that can miss the first page load when
// the app adds the channel late (2026-10-06, the iPhone's "broken" viewer:
// every message, `ready` included, went nowhere). So fall back to the
// WebKit message handler itself, which exists as soon as it is registered.
function channel() {
  if (window.FeViewer && typeof window.FeViewer.postMessage === 'function') return window.FeViewer;
  const wk = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.FeViewer;
  return wk && typeof wk.postMessage === 'function' ? wk : null;
}

function post(msg) {
  const text = JSON.stringify(msg);
  try {
    const ch = channel();
    if (ch) ch.postMessage(text);
  } catch (_) {
    /* the channel can vanish while the page is torn down */
  }
  (window.__feEvents = window.__feEvents || []).push(msg); // browser tests read this
}

// The last `ready` sent, so `hello` can repeat it (see feViewer.hello below).
let readyMsg = null;

window.addEventListener('error', (e) => post({ type: 'error', code: 'SCRIPT', message: String(e.message || e) }));
window.addEventListener('unhandledrejection', (e) =>
  post({ type: 'error', code: 'SCRIPT', message: String((e.reason && e.reason.message) || e.reason) }),
);

// ── renderer, scene, camera ───────────────────────────────────────────────
const canvas = document.createElement('canvas');
document.body.prepend(canvas);
let renderer;
try {
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
} catch (err) {
  post({ type: 'error', code: 'NO_WEBGL', message: String(err && err.message) });
  throw err;
}
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.75));
renderer.localClippingEnabled = true;
canvas.addEventListener('webglcontextlost', (e) => {
  e.preventDefault();
  post({ type: 'error', code: 'CONTEXT_LOST', message: 'WebGL context lost' });
});

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(60, 1, 0.05, 3000);
camera.rotation.order = 'YXZ';
scene.add(new THREE.HemisphereLight(0xffffff, 0x8a8f96, 2.4));
const sun = new THREE.DirectionalLight(0xffffff, 1.5);
sun.position.set(0.6, 1, 0.4);
scene.add(sun);

const groups = {};
for (const l of LAYERS) {
  groups[l] = new THREE.Group();
  groups[l].name = l;
  scene.add(groups[l]);
}
const overlay = new THREE.Group(); // selection highlight
scene.add(overlay);

// Section cut ("dollhouse"): in orbit, walls, slabs and massing above
// datum + cutM are clipped away so rooms read from above — the storey's own
// roof slab would otherwise hide everything. MEP is never cut (ducts above a
// ceiling are what a technician looks for), nor is the highlight. A far
// constant disables it without recompiling a shader.
const CUT_OFF = 1e9;
const cutPlane = new THREE.Plane(new THREE.Vector3(0, -1, 0), CUT_OFF);
const CUT_LAYERS = new Set(['architecture', 'architecture_solid', 'structure', 'massing']);

const THEME = {
  light: { bg: 0xf1f3f5, wall: 0xdcd9d2, edge: 0x3b4148, floor: 0xe6e3dc, accent: 0xf07d1a },
  dark: { bg: 0x16191d, wall: 0x9aa0a8, edge: 0xd6dbe1, floor: 0x2a2e33, accent: 0xff9a3d },
};
let theme = THEME.light;
scene.background = new THREE.Color(theme.bg);

const controls = new OrbitControls(camera, canvas);
controls.enableDamping = true;
controls.dampingFactor = 0.12;
controls.maxPolarAngle = Math.PI * 0.495;
controls.minDistance = 0.8;
controls.maxDistance = 600;
controls.screenSpacePanning = false;
controls.touches = { ONE: THREE.TOUCH.ROTATE, TWO: THREE.TOUCH.DOLLY_PAN };
controls.addEventListener('change', () => markDirty());

// ── state ─────────────────────────────────────────────────────────────────
const state = {
  mode: 'orbit',
  floor: { datumY: 0, bounds: [-10, -10, 10, 10], eye: VM.EYE_HEIGHT_M, cutM: VM.CUT_HEIGHT_M },
  walk: { yaw: 0, pitch: 0 },
  joy: { x: 0, y: 0, active: false },
  layers: { mep: true, structure: true, architecture: true, architecture_solid: true, massing: true, xray: false, cut: true },
  tiles: new Map(), // hash → { root, layer, buildId, featureIds }
  tileBase: '',
  loadSeq: 0,
  selection: null, // { buildId, featureId }
  lastPose: null,
  lastPoseAt: 0,
  dirtyUntil: 0,
  anim: null,
};

function markDirty(ms = 400) {
  state.dirtyUntil = Math.max(state.dirtyUntil, performance.now() + ms);
}

function resize() {
  const w = Math.max(1, window.innerWidth);
  const h = Math.max(1, window.innerHeight);
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  markDirty();
}
window.addEventListener('resize', resize);
resize();

// ── materials ─────────────────────────────────────────────────────────────
// Tile materials arrive as glTF PBR (metallic by default); shaded matte
// Lambert is cheaper on a phone and reads better for a model. Unstyled
// architecture comes out of the pipeline in a dark "on camera" grey that is
// right for AR and too heavy here, so solid walls take the theme's wall tone.
const ARCH_UNSTYLED = [0.3, 0.33, 0.36];
function isArchUnstyled(c) {
  return Math.abs(c.r - ARCH_UNSTYLED[0]) < 0.02 && Math.abs(c.g - ARCH_UNSTYLED[1]) < 0.02 && Math.abs(c.b - ARCH_UNSTYLED[2]) < 0.02;
}

function solidMaterial(orig, layer) {
  const color = orig && orig.color ? orig.color.clone() : new THREE.Color(0xcccccc);
  const archWall = layer === 'architecture_solid' && isArchUnstyled(color);
  if (archWall) color.setHex(theme.wall);
  const opacity = orig && typeof orig.opacity === 'number' ? orig.opacity : 1;
  const m = new THREE.MeshLambertMaterial({
    color,
    side: THREE.DoubleSide, // IFC winding is not reliable
    transparent: opacity < 1,
    opacity,
  });
  m.userData = { baseOpacity: opacity, archWall, layer };
  if (CUT_LAYERS.has(layer)) m.clippingPlanes = [cutPlane];
  return m;
}

function edgeMaterial(layer) {
  const m = new THREE.LineBasicMaterial({ color: theme.edge, transparent: true, opacity: 0.85 });
  m.userData = { baseOpacity: 0.85, edge: true, layer };
  if (CUT_LAYERS.has(layer)) m.clippingPlanes = [cutPlane];
  return m;
}

function updateCut() {
  cutPlane.constant = state.mode === 'orbit' && state.layers.cut ? state.floor.datumY + state.floor.cutM : CUT_OFF;
  markDirty();
}

function applyXray(root) {
  const xray = state.layers.xray;
  root.traverse((o) => {
    const m = o.material;
    if (!m || !m.userData) return;
    const see = xray && !m.userData.edge && (m.userData.layer === 'architecture_solid' || m.userData.layer === 'massing' || m.userData.layer === 'structure');
    const opacity = see ? Math.min(m.userData.baseOpacity, 0.22) : m.userData.baseOpacity;
    m.opacity = opacity;
    m.transparent = opacity < 1;
    m.depthWrite = opacity >= 1;
    m.needsUpdate = true;
  });
}

// ── tiles ─────────────────────────────────────────────────────────────────
const loader = new GLTFLoader();
loader.setMeshoptDecoder(MeshoptDecoder);

function disposeTree(root) {
  root.traverse((o) => {
    if (o.geometry) o.geometry.dispose();
    if (o.material) (Array.isArray(o.material) ? o.material : [o.material]).forEach((m) => m.dispose());
  });
}

function prepareTile(gltf, t) {
  const root = gltf.scene;
  const fe = (root.userData && root.userData.fe) || {};
  const layer = t.layer || fe.layer || 'mep';
  root.traverse((o) => {
    if (o.isMesh) {
      const orig = o.material;
      o.material = solidMaterial(orig, layer);
      if (orig && orig.dispose) orig.dispose();
    } else if (o.isLine || o.isLineSegments) {
      const orig = o.material;
      o.material = edgeMaterial(layer);
      if (orig && orig.dispose) orig.dispose();
    }
    o.userData.tileHash = t.hash;
    o.matrixAutoUpdate = false;
    o.updateMatrix();
  });
  root.updateMatrixWorld(true);
  const info = {
    root,
    layer,
    buildId: t.buildId || fe.buildId || null,
    featureIds: Array.isArray(fe.featureIds) ? fe.featureIds : [],
    triangles: 0,
  };
  root.traverse((o) => {
    if (o.isMesh && o.geometry) {
      const g = o.geometry;
      info.triangles += (g.index ? g.index.count : g.attributes.position.count) / 3;
    }
  });
  root.userData.fe = { ...fe, layer, hash: t.hash };
  return info;
}

async function loadOne(base, t, seq) {
  const gltf = await loader.loadAsync(base + t.hash + '.glb');
  if (seq !== state.loadSeq) {
    disposeTree(gltf.scene); // a newer setTiles superseded this one
    return null;
  }
  return prepareTile(gltf, t);
}

async function setTiles({ base, tiles }) {
  const seq = ++state.loadSeq;
  state.tileBase = base || state.tileBase;
  const wanted = new Map((tiles || []).map((t) => [t.hash, t]));
  for (const [hash, info] of state.tiles) {
    if (!wanted.has(hash)) {
      groups[info.layer]?.remove(info.root);
      disposeTree(info.root);
      state.tiles.delete(hash);
    }
  }
  const todo = [...wanted.values()].filter((t) => !state.tiles.has(t.hash));
  let loaded = 0;
  const failed = [];
  const total = todo.length;
  const report = (done) =>
    post({
      type: 'tiles',
      loaded,
      failed: failed.length,
      failedHashes: done ? failed : undefined,
      total,
      resident: state.tiles.size,
      triangles: Math.round([...state.tiles.values()].reduce((n, i) => n + i.triangles, 0)),
      done,
    });
  await MeshoptDecoder.ready;
  let next = 0;
  const worker = async () => {
    while (next < todo.length) {
      const t = todo[next++];
      try {
        const info = await loadOne(state.tileBase, t, seq);
        if (!info) return;
        state.tiles.set(t.hash, info);
        groups[info.layer] ? groups[info.layer].add(info.root) : scene.add(info.root);
        applyXray(info.root);
        loaded++;
      } catch (err) {
        failed.push(t.hash);
      }
      if (seq !== state.loadSeq) return;
      markDirty();
      if ((loaded + failed.length) % 4 === 0) report(false);
    }
  };
  await Promise.all([worker(), worker(), worker(), worker()]);
  if (seq !== state.loadSeq) return;
  if (state.selection) highlight(state.selection.buildId, state.selection.featureId);
  report(true);
  markDirty();
}

// ── plan massing (no solid tiles yet, or Demo mode) ───────────────────────
function setPlan({ datumY = 0, heightM = 3, walls = [], columns = [], bounds }) {
  groups.massing.children.slice().forEach((c) => {
    groups.massing.remove(c);
    disposeTree(c);
  });
  const parts = [];
  for (const w of walls) {
    const t = Math.max(0.08, Math.min(1, w.t || 0.2));
    for (const s of VM.wallSegments(w.pts || [])) {
      const g = new THREE.BoxGeometry(s.length + t * 0.5, heightM, t);
      g.rotateY(s.angle);
      g.translate(s.cx, datumY + heightM / 2, s.cz);
      parts.push(g);
    }
  }
  for (const poly of columns) {
    if (!poly || poly.length < 3) continue;
    const shape = new THREE.Shape(poly.map(([x, z]) => new THREE.Vector2(x, z)));
    const g = new THREE.ExtrudeGeometry(shape, { depth: heightM, bevelEnabled: false });
    g.rotateX(Math.PI / 2); // shape XY → plan XZ, extruded downward…
    g.translate(0, datumY + heightM, 0); // …from the ceiling to the floor
    parts.push(g);
  }
  const mat = solidMaterial({ color: new THREE.Color(theme.wall), opacity: 1 }, 'massing');
  mat.userData.layer = 'massing';
  if (parts.length) {
    const merged = mergeGeometries(parts.map((p) => p.toNonIndexed()), false);
    parts.forEach((p) => p.dispose());
    if (merged) {
      merged.computeVertexNormals();
      const mesh = new THREE.Mesh(merged, mat);
      mesh.name = 'massing-walls';
      groups.massing.add(mesh);
    }
  }
  const b = bounds || state.floor.bounds;
  if (b) {
    const w = Math.max(1, b[2] - b[0] + 2), d = Math.max(1, b[3] - b[1] + 2);
    const g = new THREE.PlaneGeometry(w, d);
    g.rotateX(-Math.PI / 2);
    g.translate((b[0] + b[2]) / 2, datumY - 0.01, (b[1] + b[3]) / 2);
    const fm = new THREE.MeshLambertMaterial({ color: theme.floor, side: THREE.DoubleSide });
    fm.userData = { baseOpacity: 1, layer: 'floor' };
    const floor = new THREE.Mesh(g, fm);
    floor.name = 'massing-floor';
    groups.massing.add(floor);
  }
  applyXray(groups.massing);
  markDirty();
}

// ── layers ────────────────────────────────────────────────────────────────
function setLayers(next) {
  Object.assign(state.layers, next || {});
  for (const l of LAYERS) groups[l].visible = !!state.layers[l];
  for (const l of LAYERS) applyXray(groups[l]);
  updateCut();
}

// ── camera modes ──────────────────────────────────────────────────────────
function setFloor({ datumY = 0, bounds, eyeHeightM, cutHeightM }) {
  state.floor.datumY = datumY;
  if (Array.isArray(bounds) && bounds.length === 4) state.floor.bounds = bounds;
  if (typeof eyeHeightM === 'number') state.floor.eye = eyeHeightM;
  if (typeof cutHeightM === 'number' && cutHeightM > 0.3) state.floor.cutM = cutHeightM;
  updateCut();
  resetView();
}

function resetView() {
  const f = VM.frameFloor(state.floor.bounds, state.floor.datumY, camera.fov, camera.aspect);
  if (state.mode === 'orbit') {
    camera.position.set(...f.position);
    controls.target.set(...f.target);
    controls.update();
  } else {
    const b = state.floor.bounds;
    camera.position.set((b[0] + b[2]) / 2, state.floor.datumY + state.floor.eye, (b[1] + b[3]) / 2);
    state.walk = { yaw: 0, pitch: 0 };
    applyWalkCamera();
  }
  markDirty();
}

function applyWalkCamera() {
  camera.rotation.set(state.walk.pitch, state.walk.yaw, 0, 'YXZ');
  camera.updateMatrixWorld();
}

function currentDir() {
  const d = new THREE.Vector3();
  camera.getWorldDirection(d);
  return [d.x, d.y, d.z];
}

function setMode({ mode }) {
  if (mode !== 'walk' && mode !== 'orbit') return;
  if (mode === state.mode) return;
  if (mode === 'walk') {
    // Stand where the orbit was looking, facing the same way.
    const t = controls.target;
    const { yaw } = VM.yawPitchFromDir(currentDir());
    camera.position.set(t.x, state.floor.datumY + state.floor.eye, t.z);
    state.walk = { yaw, pitch: 0 };
    controls.enabled = false;
    applyWalkCamera();
  } else {
    const d = VM.dirFromYawPitch(state.walk.yaw, -0.5);
    const p = camera.position;
    const ahead = 6;
    controls.target.set(p.x + d[0] * ahead, state.floor.datumY, p.z + d[2] * ahead);
    camera.position.set(p.x - d[0] * ahead, p.y + 8, p.z - d[2] * ahead);
    controls.enabled = true;
    controls.update();
  }
  state.mode = mode;
  document.body.classList.toggle('walk', mode === 'walk');
  state.lastPose = null;
  updateCut();
}

/** Move the camera to a plan point (split view tap). Walk keeps its heading; orbit re-targets. */
function flyTo({ x, z, headingX, headingZ }) {
  if (!Number.isFinite(x) || !Number.isFinite(z)) return;
  const from = camera.position.clone();
  let to, fromTarget, toTarget;
  if (state.mode === 'walk') {
    to = new THREE.Vector3(x, state.floor.datumY + state.floor.eye, z);
    if (Number.isFinite(headingX) && Number.isFinite(headingZ)) {
      state.walk.yaw = VM.yawPitchFromDir([headingX, 0, headingZ]).yaw;
      applyWalkCamera();
    }
  } else {
    fromTarget = controls.target.clone();
    toTarget = new THREE.Vector3(x, state.floor.datumY, z);
    to = from.clone().add(toTarget.clone().sub(fromTarget));
  }
  state.anim = { t0: performance.now(), ms: 380, from, to, fromTarget, toTarget };
  markDirty(500);
}

function stepAnim(now) {
  const a = state.anim;
  if (!a) return;
  const k = Math.min(1, (now - a.t0) / a.ms);
  const e = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
  camera.position.lerpVectors(a.from, a.to, e);
  if (a.fromTarget) {
    controls.target.lerpVectors(a.fromTarget, a.toTarget, e);
    controls.update();
  }
  if (k >= 1) state.anim = null;
  markDirty();
}

// ── walk input: drag to look, joystick to move ────────────────────────────
const joyEl = document.getElementById('joy');
const knobEl = document.getElementById('knob');
let joyPointer = null;
function joySet(ev) {
  const r = joyEl.getBoundingClientRect();
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  const rad = r.width / 2;
  let x = (ev.clientX - cx) / rad, y = (ev.clientY - cy) / rad;
  const m = Math.hypot(x, y);
  if (m > 1) {
    x /= m;
    y /= m;
  }
  state.joy = { x, y, active: true };
  knobEl.style.transform = `translate(${x * rad * 0.6}px, ${y * rad * 0.6}px)`;
  markDirty();
}
function joyEnd() {
  joyPointer = null;
  state.joy = { x: 0, y: 0, active: false };
  knobEl.style.transform = 'translate(0px, 0px)';
}
if (joyEl) {
  joyEl.addEventListener('pointerdown', (ev) => {
    ev.stopPropagation();
    joyPointer = ev.pointerId;
    joyEl.setPointerCapture(ev.pointerId);
    joySet(ev);
  });
  joyEl.addEventListener('pointermove', (ev) => {
    if (ev.pointerId === joyPointer) joySet(ev);
  });
  joyEl.addEventListener('pointerup', joyEnd);
  joyEl.addEventListener('pointercancel', joyEnd);
}

const pointers = new Map();
let downInfo = null;
let multi = false;
canvas.addEventListener('pointerdown', (ev) => {
  pointers.set(ev.pointerId, { x: ev.clientX, y: ev.clientY });
  if (pointers.size > 1) multi = true;
  if (pointers.size === 1) {
    multi = false;
    downInfo = { x: ev.clientX, y: ev.clientY, t: performance.now(), id: ev.pointerId };
  }
});
canvas.addEventListener('pointermove', (ev) => {
  const prev = pointers.get(ev.pointerId);
  if (!prev) return;
  if (state.mode === 'walk' && pointers.size === 1) {
    const look = VM.lookDrag(state.walk.yaw, state.walk.pitch, ev.clientX - prev.x, ev.clientY - prev.y);
    state.walk = look;
    applyWalkCamera();
    markDirty();
  }
  pointers.set(ev.pointerId, { x: ev.clientX, y: ev.clientY });
});
function pointerEnd(ev) {
  const wasTap =
    !multi && downInfo && downInfo.id === ev.pointerId && VM.isTap(downInfo, { x: ev.clientX, y: ev.clientY, t: performance.now() });
  pointers.delete(ev.pointerId);
  if (pointers.size === 0) downInfo = null;
  if (wasTap) pick(ev.clientX, ev.clientY);
}
canvas.addEventListener('pointerup', pointerEnd);
canvas.addEventListener('pointercancel', (ev) => {
  pointers.delete(ev.pointerId);
  downInfo = null;
});

// ── pick + highlight ──────────────────────────────────────────────────────
const raycaster = new THREE.Raycaster();
raycaster.params.Line.threshold = 0.06;

function vertexOf(hit) {
  if (hit.face) return hit.face.a;
  const g = hit.object.geometry;
  if (typeof hit.index === 'number') return g.index ? g.index.getX(hit.index) : hit.index;
  return null;
}

function tileInfoOf(object) {
  let o = object;
  while (o && !o.userData.tileHash) o = o.parent;
  return o ? state.tiles.get(o.userData.tileHash) : null;
}

/** The first visible surface under a screen point (section cut and x-ray respected), or null. */
function surfaceHit(clientX, clientY) {
  const r = canvas.getBoundingClientRect();
  const ndc = new THREE.Vector2(((clientX - r.left) / r.width) * 2 - 1, -((clientY - r.top) / r.height) * 2 + 1);
  raycaster.setFromCamera(ndc, camera);
  const targets = LAYERS.filter((l) => groups[l].visible).map((l) => groups[l]);
  const cutY = cutPlane.constant;
  const hits = raycaster
    .intersectObjects(targets, true)
    .filter((h) => !(h.object.material && h.object.material.clippingPlanes && h.object.material.clippingPlanes.length && h.point.y > cutY + 1e-3));
  const solid = hits.filter((h) => h.face && !(state.layers.xray && h.object.material && h.object.material.opacity < 0.5));
  return solid[0] || hits.find((h) => h.face) || null;
}

// ── measure tool: tap two surfaces, get the distance ─────────────────────
// Points snap to the first visible surface (a wall face, a pipe, the floor).
// The line and dots draw through walls, like the selection highlight; the
// number itself is shown by Flutter (i18n, units), from the `measure` event.
const measureGroup = new THREE.Group();
scene.add(measureGroup);
state.measure = [];

function drawMeasure() {
  measureGroup.children.slice().forEach((c) => {
    measureGroup.remove(c);
    disposeTree(c);
  });
  const pts = state.measure;
  const dotGeo = new THREE.SphereGeometry(0.06, 12, 8);
  for (const p of pts) {
    const dot = new THREE.Mesh(dotGeo.clone(), new THREE.MeshBasicMaterial({ color: theme.accent, depthTest: false }));
    dot.position.set(p[0], p[1], p[2]);
    dot.renderOrder = 1001;
    measureGroup.add(dot);
  }
  dotGeo.dispose();
  if (pts.length === 2) {
    const g = new THREE.BufferGeometry().setFromPoints(pts.map((p) => new THREE.Vector3(p[0], p[1], p[2])));
    const line = new THREE.Line(g, new THREE.LineBasicMaterial({ color: theme.accent, depthTest: false, transparent: true }));
    line.renderOrder = 1001;
    measureGroup.add(line);
  }
  markDirty();
}

function measureAt(clientX, clientY) {
  const hit = surfaceHit(clientX, clientY);
  if (!hit) return;
  const p = [hit.point.x, hit.point.y, hit.point.z].map((v) => Math.round(v * 1000) / 1000);
  state.measure = state.measure.length >= 2 ? [p] : [...state.measure, p];
  drawMeasure();
  const m = VM.measureOf(state.measure);
  post({ type: 'measure', points: state.measure, ...m });
}

function clearMeasure() {
  state.measure = [];
  drawMeasure();
  post({ type: 'measure', points: [], distanceM: null, horizontalM: null, verticalM: null });
}

function setTool({ tool }) {
  state.tool = tool === 'measure' ? 'measure' : 'none';
  if (state.tool !== 'measure') clearMeasure();
}

function setCut({ heightM }) {
  if (typeof heightM === 'number' && heightM > 0.3) state.floor.cutM = heightM;
  updateCut();
}

function pick(clientX, clientY) {
  if (state.tool === 'measure') return measureAt(clientX, clientY);
  const r = canvas.getBoundingClientRect();
  const ndc = new THREE.Vector2(((clientX - r.left) / r.width) * 2 - 1, -((clientY - r.top) / r.height) * 2 + 1);
  raycaster.setFromCamera(ndc, camera);
  const targets = LAYERS.filter((l) => groups[l].visible).map((l) => groups[l]);
  // A raycast ignores clipping: drop hits on the part of a wall or slab the
  // section cut has removed from view.
  const cutY = cutPlane.constant;
  const hits = raycaster
    .intersectObjects(targets, true)
    .filter((h) => !(h.object.material && h.object.material.clippingPlanes && h.object.material.clippingPlanes.length && h.point.y > cutY + 1e-3));
  // In x-ray, see-through walls and slabs must not swallow the tap meant for
  // what's behind them — unless there is nothing behind them.
  const solidHits = hits.filter((h) => {
    const m = h.object.material;
    return !(state.layers.xray && m && m.userData && m.opacity < 0.5);
  });
  const usable = solidHits.length ? solidHits : hits;
  // Prefer a surface over an edge line lying on that surface.
  const hit = usable.find((h) => h.face) || usable[0];
  if (!hit) {
    post({ type: 'pick', none: true });
    clearSelection();
    return;
  }
  const info = tileInfoOf(hit.object);
  const p = [hit.point.x, hit.point.y, hit.point.z];
  if (!info) {
    post({ type: 'pick', point: p, featureId: null, buildId: null, layer: hit.object.material?.userData?.layer ?? null });
    clearSelection();
    return;
  }
  const uv1 = hit.object.geometry.attributes.uv1;
  const v = vertexOf(hit);
  const local = uv1 && v !== null ? Math.round(uv1.getX(v)) : null;
  const featureId = VM.featureOfVertex(local, info.featureIds);
  post({ type: 'pick', point: p, featureId, buildId: info.buildId, layer: info.layer, tileHash: hit.object.userData.tileHash });
  if (featureId !== null) select({ buildId: info.buildId, featureId, frame: false });
}

function clearSelection() {
  state.selection = null;
  overlay.children.slice().forEach((c) => {
    overlay.remove(c);
    disposeTree(c);
  });
  markDirty();
}

/** Copies the triangles / segments of one feature into a bright overlay drawn through walls. Returns its world bbox. */
function highlight(buildId, featureId) {
  overlay.children.slice().forEach((c) => {
    overlay.remove(c);
    disposeTree(c);
  });
  const box = new THREE.Box3();
  const tri = [];
  const seg = [];
  const v = new THREE.Vector3();
  for (const info of state.tiles.values()) {
    if (buildId && info.buildId && info.buildId !== buildId) continue;
    const local = info.featureIds.indexOf(featureId);
    if (local < 0) continue;
    info.root.traverse((o) => {
      const g = o.geometry;
      if (!g || !g.attributes.uv1) return;
      const uv1 = g.attributes.uv1;
      const pos = g.attributes.position;
      const idx = g.index;
      const n = idx ? idx.count : pos.count;
      const at = (i) => (idx ? idx.getX(i) : i);
      const push = (arr, vi) => {
        v.fromBufferAttribute(pos, vi).applyMatrix4(o.matrixWorld);
        arr.push(v.x, v.y, v.z);
        box.expandByPoint(v);
      };
      if (o.isMesh) {
        for (let i = 0; i + 2 < n; i += 3) {
          const a = at(i);
          if (Math.round(uv1.getX(a)) !== local) continue;
          push(tri, a);
          push(tri, at(i + 1));
          push(tri, at(i + 2));
        }
      } else if (o.isLineSegments) {
        for (let i = 0; i + 1 < n; i += 2) {
          const a = at(i);
          if (Math.round(uv1.getX(a)) !== local) continue;
          push(seg, a);
          push(seg, at(i + 1));
        }
      }
    });
  }
  if (tri.length) {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(tri, 3));
    const m = new THREE.MeshBasicMaterial({ color: theme.accent, transparent: true, opacity: 0.55, depthTest: false, depthWrite: false, side: THREE.DoubleSide });
    const mesh = new THREE.Mesh(g, m);
    mesh.renderOrder = 999;
    overlay.add(mesh);
  }
  if (seg.length) {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(seg, 3));
    const m = new THREE.LineBasicMaterial({ color: theme.accent, depthTest: false, transparent: true });
    const lines = new THREE.LineSegments(g, m);
    lines.renderOrder = 1000;
    overlay.add(lines);
  }
  markDirty();
  return box.isEmpty() ? null : box;
}

/** Select a feature (from a pick, or from Dart: "show this asset"). `frame` moves the camera to it. */
function select({ buildId, featureId, frame = true, bboxMin, bboxMax }) {
  if (!Number.isInteger(featureId)) return clearSelection();
  state.selection = { buildId: buildId || null, featureId };
  let box = highlight(state.selection.buildId, featureId);
  if (!box && Array.isArray(bboxMin) && Array.isArray(bboxMax)) {
    box = new THREE.Box3(new THREE.Vector3(...bboxMin), new THREE.Vector3(...bboxMax));
  }
  if (!frame || !box) return;
  const min = box.min.toArray(), max = box.max.toArray();
  if (state.mode === 'walk') {
    const s = VM.standOffFor(min, max, state.floor.datumY, VM.planHeading(currentDir()), state.floor.eye);
    state.walk = { yaw: s.yaw, pitch: VM.clamp(s.pitch, -VM.MAX_PITCH, VM.MAX_PITCH) };
    applyWalkCamera();
    state.anim = { t0: performance.now(), ms: 420, from: camera.position.clone(), to: new THREE.Vector3(...s.position) };
  } else {
    const c = box.getCenter(new THREE.Vector3());
    const size = Math.max(2, box.getSize(new THREE.Vector3()).length());
    const dir = camera.position.clone().sub(controls.target).normalize();
    const to = c.clone().add(dir.multiplyScalar(size * 1.6 + 3));
    state.anim = { t0: performance.now(), ms: 420, from: camera.position.clone(), to, fromTarget: controls.target.clone(), toTarget: c };
  }
  markDirty(600);
}

// ── theme ─────────────────────────────────────────────────────────────────
function setTheme({ dark }) {
  theme = dark ? THEME.dark : THEME.light;
  scene.background = new THREE.Color(theme.bg);
  document.documentElement.classList.toggle('dark', !!dark);
  scene.traverse((o) => {
    const m = o.material;
    if (!m || !m.userData) return;
    if (m.userData.edge) m.color.setHex(theme.edge);
    if (m.userData.archWall || m.userData.layer === 'massing') m.color.setHex(theme.wall);
    if (m.userData.layer === 'floor') m.color.setHex(theme.floor);
  });
  markDirty();
}

// ── loop: render only while something changes (battery) ─────────────────
let lastT = performance.now();
function frame(now) {
  requestAnimationFrame(frame);
  const dt = Math.min(0.1, (now - lastT) / 1000);
  lastT = now;
  stepAnim(now);
  if (state.mode === 'walk' && state.joy.active) {
    const p = VM.walkStep(camera.position.toArray(), state.walk.yaw, state.joy, dt);
    camera.position.set(p[0], p[1], p[2]);
    markDirty();
  }
  if (state.mode === 'orbit' && controls.enabled && controls.update()) markDirty();
  if (now < state.dirtyUntil) {
    renderer.render(scene, camera);
    emitPose(now);
  }
}

function emitPose(now) {
  if (now - state.lastPoseAt < 100) return;
  const pose = {
    pos: camera.position.toArray().map((v) => Math.round(v * 1000) / 1000),
    dir: currentDir().map((v) => Math.round(v * 10000) / 10000),
    mode: state.mode,
  };
  if (!VM.poseChanged(pose, state.lastPose)) return;
  state.lastPose = pose;
  state.lastPoseAt = now;
  const t = controls.target;
  post({ type: 'pose', ...pose, fovDeg: camera.fov, target: state.mode === 'orbit' ? [t.x, t.y, t.z] : null });
}

// ── command entry point ───────────────────────────────────────────────────
const COMMANDS = {
  setTheme,
  setFloor,
  setTiles,
  setPlan,
  setLayers,
  setMode,
  flyTo,
  select,
  clearSelection,
  resetView,
  setTool,
  setCut,
  clearMeasure,
};

function run(command) {
  const c = typeof command === 'string' ? JSON.parse(command) : command;
  const fn = c && COMMANDS[c.cmd];
  if (!fn) {
    post({ type: 'error', code: 'UNKNOWN_COMMAND', message: String(c && c.cmd) });
    return;
  }
  try {
    const out = fn(c.args || {});
    if (out && typeof out.catch === 'function') {
      out.catch((err) => post({ type: 'error', code: 'COMMAND_FAILED', cmd: c.cmd, message: String(err && err.message) }));
    }
  } catch (err) {
    post({ type: 'error', code: 'COMMAND_FAILED', cmd: c.cmd, message: String(err && err.message) });
  }
}

const queued = (window.feViewer && window.feViewer.q) || [];
window.feViewer = {
  run,
  version: 1,
  // Handshake: the app calls this when the page has finished loading. If
  // `ready` already went out (possibly before the app's channel existed),
  // say it again; if not, it goes out by itself once the decoder is up.
  // Ready twice is harmless: the app pushes a floor once per page.
  hello: () => {
    if (readyMsg) post(readyMsg);
  },
  // Read-only snapshot for the browser tests (test/bim_viewer_js/); the app never calls it.
  debug: () => ({
    mode: state.mode,
    tiles: state.tiles.size,
    overlay: overlay.children.length,
    massing: groups.massing.children.length,
    visible: Object.fromEntries(LAYERS.map((l) => [l, groups[l].visible])),
    cutY: cutPlane.constant,
    layerTiles: Object.fromEntries(LAYERS.map((l) => [l, groups[l].children.length])),
    selection: state.selection,
    tool: state.tool || 'none',
    measure: state.measure,
    camera: camera.position.toArray(),
  }),
};
setLayers({});
resetView();
requestAnimationFrame(frame);
MeshoptDecoder.ready.then(
  () => {
    readyMsg = { type: 'ready', version: 1, webgl2: renderer.capabilities.isWebGL2 };
    post(readyMsg);
    queued.forEach(run);
  },
  (err) => post({ type: 'error', code: 'NO_WASM', message: String(err && err.message) }),
);
