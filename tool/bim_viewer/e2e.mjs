// Browser end-to-end check of assets/bim_viewer against REAL server-built tiles
// (docs/bim-viewer.md §8). Not part of `flutter test`: it needs Node and a
// Playwright install (the web client has one).
//
//   PLAYWRIGHT=../fusion-eco-client/node_modules/playwright \
//   TILES_DIR=<dir with manifest.json, plan.json, features.json, tiles/*.glb> \
//   OUT_DIR=<where screenshots go> \
//   node tool/bim_viewer/e2e.mjs
//
// A TILES_DIR comes from the server pipeline (buildTilesFromIfc) on any IFC:
// manifest.json = { datumY, tiles: [{hash, layer, buildId, bboxMin, bboxMax}] },
// plan.json = the storey's FloorPlanPart, features.json = [{featureId, layer}].
// It serves the page the way the app does (token path, /app and /tiles), then
// drives the same commands the Dart engine sends.

import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFileSync, existsSync, mkdirSync, statSync } from 'node:fs';
import { join, extname, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const APP = resolve(here, '../../assets/bim_viewer');
const TILES_DIR = process.env.TILES_DIR;
const OUT_DIR = process.env.OUT_DIR || join(here, '.e2e-out');
const require = createRequire(import.meta.url);
const { chromium } = require(resolve(process.env.PLAYWRIGHT || 'playwright'));
if (!TILES_DIR) throw new Error('Set TILES_DIR');
mkdirSync(OUT_DIR, { recursive: true });

const TOKEN = 'e2e0token0e2e0token0e2e0token00';
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.glb': 'model/gltf-binary', '.txt': 'text/plain' };
const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const parts = url.pathname.split('/').filter(Boolean);
  if (parts[0] !== TOKEN) return res.writeHead(404).end();
  let file = null;
  if (parts[1] === 'app') file = join(APP, ...parts.slice(2));
  if (parts[1] === 'tiles' && /^[0-9a-f]{64}\.glb$/.test(parts[2] || '')) file = join(TILES_DIR, 'tiles', parts[2]);
  if (!file || !existsSync(file) || !statSync(file).isFile()) return res.writeHead(404).end();
  res.writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream' });
  res.end(readFileSync(file));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}/${TOKEN}`;

const manifest = JSON.parse(readFileSync(join(TILES_DIR, 'manifest.json'), 'utf8'));
const plan = JSON.parse(readFileSync(join(TILES_DIR, 'plan.json'), 'utf8'));
const features = JSON.parse(readFileSync(join(TILES_DIR, 'features.json'), 'utf8'));
const featureIds = new Set(features.map((f) => f.featureId));
const tileBox = manifest.tiles.reduce(
  (b, t) => [Math.min(b[0], t.bboxMin[0]), Math.min(b[1], t.bboxMin[2]), Math.max(b[2], t.bboxMax[0]), Math.max(b[3], t.bboxMax[2])],
  [Infinity, Infinity, -Infinity, -Infinity],
);
const bounds = plan && plan.bbox ? plan.bbox : tileBox;

const failures = [];
const check = (ok, what) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}`);
  if (!ok) failures.push(what);
};

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: 412, height: 780 }, deviceScaleFactor: 2, hasTouch: false });
const consoleErrors = [];
page.on('console', (m) => m.type() === 'error' && consoleErrors.push(m.text()));
page.on('pageerror', (e) => consoleErrors.push(String(e)));

const events = () => page.evaluate(() => window.__feEvents || []);
const run = (cmd, args) => page.evaluate(([c, a]) => window.feViewer.run({ cmd: c, args: a }), [cmd, args]);
const debug = () => page.evaluate(() => window.feViewer.debug());
async function waitFor(pred, what, ms = 60000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const ev = await events();
    const hit = ev.find(pred);
    if (hit) return hit;
    await page.waitForTimeout(100);
  }
  throw new Error(`timeout waiting for ${what}`);
}
const clearEvents = () => page.evaluate(() => (window.__feEvents = []));
const lastPose = async () => (await events()).filter((e) => e.type === 'pose').pop();

await page.goto(`${origin}/app/index.html`);
const ready = await waitFor((e) => e.type === 'ready' || e.type === 'error', 'ready');
check(ready.type === 'ready', `viewer ready (webgl2=${ready.webgl2})`);

// Floor + tiles, exactly as the Dart engine sends them.
await run('setTheme', { dark: false });
await run('setFloor', { datumY: manifest.datumY, bounds, eyeHeightM: 1.6 });
await run('setLayers', { mep: true, structure: true, architecture: true, architecture_solid: true, massing: false, xray: false });
await run('setTiles', {
  base: `${origin}/tiles/`,
  tiles: manifest.tiles.map((t) => ({ hash: t.hash, layer: t.layer, buildId: t.buildId })),
});
const done = await waitFor((e) => e.type === 'tiles' && e.done, 'tiles done');
check(done.loaded === manifest.tiles.length && done.failed === 0, `all ${manifest.tiles.length} tiles loaded (loaded=${done.loaded}, failed=${done.failed}, triangles=${done.triangles})`);
const d0 = await debug();
check(d0.layerTiles.architecture_solid === (manifest.byLayer.architecture_solid || 0), `solid architecture tiles resident: ${d0.layerTiles.architecture_solid}`);
check(Math.abs(d0.cutY - (manifest.datumY + 2.2)) < 1e-6, `orbit section cut at datum + 2.2 m (${d0.cutY})`);
await page.waitForTimeout(400);
await page.screenshot({ path: join(OUT_DIR, '1-orbit.png') });
const orbitPose = await lastPose();
check(!!orbitPose && orbitPose.mode === 'orbit' && Array.isArray(orbitPose.target), 'orbit pose event with a target');

// Tap to pick: sweep a few screen points until something with a feature is hit.
let picked = null;
let pickedAt = null;
for (const [fx, fy] of [[0.5, 0.5], [0.45, 0.55], [0.55, 0.45], [0.4, 0.4], [0.6, 0.6], [0.5, 0.35], [0.5, 0.65]]) {
  await clearEvents();
  await page.mouse.click(412 * fx, 780 * fy);
  const p = await waitFor((e) => e.type === 'pick', 'pick', 5000);
  if (p.featureId !== null && p.featureId !== undefined) {
    picked = p;
    pickedAt = [fx, fy];
    break;
  }
}
check(!!picked, `tap picks an element (featureId=${picked && picked.featureId}, layer=${picked && picked.layer})`);
if (picked) {
  check(featureIds.has(picked.featureId), 'picked featureId is one of the storey\'s features (TEXCOORD_1 → fe.featureIds)');
  const d = await debug();
  check(d.overlay > 0 && d.selection && d.selection.featureId === picked.featureId, 'picked element is highlighted');
  await page.screenshot({ path: join(OUT_DIR, '2-picked.png') });
}

// Select from Dart ("show this asset"): frames the camera on it.
const mep = features.find((f) => f.layer === 'mep');
if (mep) {
  await clearEvents();
  const before = (await debug()).camera;
  await run('select', { buildId: manifest.tiles[0].buildId, featureId: mep.featureId, frame: true });
  await page.waitForTimeout(700);
  const after = (await debug()).camera;
  check(Math.hypot(after[0] - before[0], after[1] - before[1], after[2] - before[2]) > 0.1, `select(${mep.featureId}) moves the camera to the element`);
  await page.screenshot({ path: join(OUT_DIR, '3-selected-mep.png') });
}

// Measure tool: two taps on the model give a straight-line distance;
// clearMeasure empties it, and setTool('none') turns tapping-to-measure off.
if (picked) {
  const [pfx, pfy] = pickedAt;
  await run('setTool', { tool: 'measure' });
  check((await debug()).tool === 'measure', 'setTool measure switches the tap tool');
  await clearEvents();
  await page.mouse.click(412 * pfx, 780 * pfy);
  const first = await waitFor((e) => e.type === 'measure', 'first measure point', 5000);
  check(first.points.length === 1 && first.distanceM === null, 'one tap: a single point, no distance yet');

  // The second tap must land on a different surface point than the first
  // (same pixel twice would measure zero); sweep small offsets around it.
  let second = null;
  for (const [ox, oy] of [[12, 12], [-12, -12], [16, 0], [0, 16], [-16, 0], [12, -12]]) {
    await page.mouse.click(412 * pfx + ox, 780 * pfy + oy);
    let ev = null;
    try {
      ev = await waitFor((e) => e.type === 'measure', 'second measure point', 3000);
    } catch (_) {
      /* the offset missed the model; try the next one */
    }
    if (ev && ev.points.length === 2 && ev.distanceM > 0) {
      second = ev;
      break;
    }
    if (!ev || ev.points.length !== 1) {
      // re-arm the first point before the next offset attempt
      await page.mouse.click(412 * pfx, 780 * pfy);
      try {
        await waitFor((e) => e.type === 'measure', 're-arm first point', 3000);
      } catch (_) {
        /* keep trying the remaining offsets */
      }
    }
  }
  check(!!second, `measure: two taps give a distance > 0 (${second && second.distanceM} m, along floor ${second && second.horizontalM} m, height ${second && second.verticalM} m)`);
  if (second) {
    const d = await debug();
    check(Array.isArray(d.measure) && d.measure.length === 2, 'debug().measure holds both tapped points');
  }

  await run('clearMeasure', {});
  const cleared = await waitFor((e) => e.type === 'measure', 'measure cleared', 5000);
  check(Array.isArray(cleared.points) && cleared.points.length === 0 && cleared.distanceM === null, 'clearMeasure empties the measurement');
  check((await debug()).measure.length === 0, 'debug().measure is empty after clearMeasure');

  await run('setTool', { tool: 'none' });
  check((await debug()).tool === 'none', 'setTool none turns the measure tool off');
}

// Section-cut height: setCut moves the orbit clip plane above the datum.
await run('setCut', { heightM: 1.5 });
const cutDbg = await debug();
check(Math.abs(cutDbg.cutY - (manifest.datumY + 1.5)) < 1e-6, `setCut moves the orbit section cut to datum + 1.5 m (${cutDbg.cutY})`);

// Layers and x-ray.
await run('setLayers', { architecture_solid: false });
check((await debug()).visible.architecture_solid === false, 'solid walls can be hidden');
await run('setLayers', { architecture_solid: true, xray: true });
await page.waitForTimeout(300);
await page.screenshot({ path: join(OUT_DIR, '4-xray.png') });
await run('setLayers', { xray: false });

// Walk mode, joystick forward, then a split-view flyTo.
await clearEvents();
await run('setMode', { mode: 'walk' });
await page.waitForTimeout(300);
const w0 = await lastPose();
check(!!w0 && w0.mode === 'walk' && Math.abs(w0.pos[1] - (manifest.datumY + 1.6)) < 0.01, `walk mode at eye height (y=${w0 && w0.pos[1]})`);
const joy = await page.locator('#joy').boundingBox();
check(!!joy, 'joystick shown in walk mode');
check((await debug()).cutY > 1e6, 'no section cut while walking');
if (joy) {
  const cx = joy.x + joy.width / 2, cy = joy.y + joy.height / 2;
  await page.mouse.move(cx, cy);
  await page.mouse.down();
  await page.mouse.move(cx, cy - joy.height * 0.45, { steps: 4 });
  await page.waitForTimeout(700);
  await page.mouse.up();
  await page.waitForTimeout(250);
  const w1 = await lastPose();
  const moved = Math.hypot(w1.pos[0] - w0.pos[0], w1.pos[2] - w0.pos[2]);
  const along = ((w1.pos[0] - w0.pos[0]) * w0.dir[0] + (w1.pos[2] - w0.pos[2]) * w0.dir[2]) / (Math.hypot(w0.dir[0], w0.dir[2]) || 1);
  check(moved > 0.3 && along > 0.25, `joystick up walks forward (${moved.toFixed(2)} m, ${along.toFixed(2)} m along the view)`);
  check(Math.abs(w1.pos[1] - w0.pos[1]) < 1e-6, 'walking keeps eye height');
}
await page.screenshot({ path: join(OUT_DIR, '5-walk.png') });
await clearEvents();
const fx = (bounds[0] + bounds[2]) / 2 + 1.5, fz = (bounds[1] + bounds[3]) / 2 - 1.5;
await run('flyTo', { x: fx, z: fz });
await page.waitForTimeout(700);
const w2 = await lastPose();
check(!!w2 && Math.hypot(w2.pos[0] - fx, w2.pos[2] - fz) < 0.05, `flyTo puts the walker on the plan point (${w2 && w2.pos.join(', ')})`);
await run('setMode', { mode: 'orbit' });
check((await debug()).mode === 'orbit', 'back to orbit');

// Plan massing fallback (no solid tiles yet / Demo).
await run('setTiles', { base: `${origin}/tiles/`, tiles: [] });
await waitFor((e) => e.type === 'tiles' && e.done && e.resident === 0, 'unload');
check((await debug()).tiles === 0, 'setTiles([]) unloads every tile');
if (plan && Array.isArray(plan.walls) && plan.walls.length) {
  await run('setPlan', {
    datumY: manifest.datumY,
    heightM: 3,
    walls: plan.walls.map((w) => ({ pts: w.polyline, t: w.thickness })),
    columns: (plan.columns || []).map((c) => c.polygon),
    bounds,
  });
  await run('setLayers', { massing: true });
  await run('resetView', {});
  await page.waitForTimeout(400);
  const d = await debug();
  check(d.massing >= 2, `plan massing built (${plan.walls.length} walls → ${d.massing} meshes)`);
  await page.screenshot({ path: join(OUT_DIR, '6-massing.png') });
}

await run('noSuchCommand', {});
check((await events()).some((e) => e.type === 'error' && e.code === 'UNKNOWN_COMMAND'), 'unknown command answers an error event, not an exception');

const errs = (await events()).filter((e) => e.type === 'error' && e.code !== 'UNKNOWN_COMMAND');
check(errs.length === 0, `no error events (${JSON.stringify(errs).slice(0, 300)})`);
check(consoleErrors.length === 0, `no console errors (${consoleErrors.slice(0, 3).join(' | ')})`);

await browser.close();
server.close();
console.log(`\n${failures.length ? 'FAILED' : 'OK'}: ${failures.length} failure(s). Screenshots in ${OUT_DIR}`);
process.exit(failures.length ? 1 : 0);
