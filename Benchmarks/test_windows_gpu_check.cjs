// SPDX-License-Identifier: Apache-2.0
// Deterministic benchmark-control tests. No GPU or FPS qualification is implied.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../examples/windows-gpu-check.html'), 'utf8');
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function fixture(options = {}) {
  const handlers = new Map(), callbacks = new Map();
  const element = id => ({ value: id === 'mode' ? 'queued' : '', textContent: '',
    addEventListener(type, callback) { handlers.set(id + ':' + type, callback); } });
  const elements = Object.fromEntries(['c', 'renderer', 'geometry', 'result', 'pacing', 'mode', 'restart'].map(id => [id, element(id)]));
  let finishes = 0, serial = 0;
  const gl = {
    get drawingBufferWidth() { return options.badAllocation ? 1 : elements.c.width; },
    get drawingBufferHeight() { return elements.c.height; },
    getExtension() { return null; }, getParameter() { return options.renderer || 'hardware test fixture'; },
    createShader() { return {}; }, shaderSource() {}, compileShader() {}, getShaderParameter() { return true; },
    createProgram() { return {}; }, attachShader() {}, linkProgram() {}, getProgramParameter() { return true; },
    useProgram() {}, viewport() {}, uniform2f() {}, getUniformLocation() { return {}; },
    uniform1f() {}, drawArrays() {}, finish() { finishes++; },
  };
  elements.c.getContext = () => gl;
  const document = { hidden: false, getElementById(id) { return elements[id]; },
    addEventListener(type, callback) { handlers.set('document:' + type, callback); } };
  const context = { document, innerWidth: 952, innerHeight: 555, devicePixelRatio: 1,
    requestAnimationFrame(callback) { callbacks.set(++serial, callback); return serial; },
    cancelAnimationFrame(id) { callbacks.delete(id); },
    addEventListener(type, callback) { handlers.set('window:' + type, callback); } };
  context.window = context;
  vm.runInNewContext(source, context, { timeout: 1000 });
  return { context, elements, gl,
    tick(now) { const batch = [...callbacks.values()]; callbacks.clear(); for (const callback of batch) callback(now); },
    event(target, type) { handlers.get(target + ':' + type)(); },
    finishTrial(start = 0, step = 1000 / 120) { for (let now = start; now <= start + 22000 + step; now += step) this.tick(now); return context.macOpenVMGpuResult; },
    get finishes() { return finishes; }, get pending() { return callbacks.size; } };
}

let passed = 0;
function test(name, run) { run(); passed++; console.log('PASS ' + name); }
test('120 Hz samples report percentiles and declared drawing-buffer size', () => {
  const f = fixture(), result = f.finishTrial();
  assert.equal(result.geometry.width, 952); assert.equal(result.geometry.height, 555);
  assert.ok(Math.abs(result.framesPerSecond - 120) < .001);
  assert.ok(Math.abs(result.p95Milliseconds - 1000 / 120) < .001);
  assert.equal(result.over120HzBudgetWith10PercentTolerance, 0);
  assert.equal(result.hostPresentationMeasured, false); assert.equal(f.finishes, 0);
});
test('resizing a completed small-buffer trial invalidates and reruns at 4K', () => {
  const f = fixture(); f.finishTrial();
  f.context.innerWidth = 3840; f.context.innerHeight = 2160; f.event('window', 'resize');
  assert.equal(f.context.macOpenVMGpuResult, null);
  assert.equal(f.elements.c.width, 3840); assert.equal(f.elements.c.height, 2160);
  const result = f.finishTrial(30000);
  assert.equal(result.geometry.width, 3840); assert.ok(result.measuredMilliseconds > 19900);
});
test('DPI change without a resize event discards the previous measurement', () => {
  const f = fixture(); for (let now = 0; now < 10000; now += 10) f.tick(now);
  f.context.devicePixelRatio = 2; f.tick(10000);
  assert.equal(f.elements.c.width, 1904); assert.equal(f.context.macOpenVMGpuResult, null);
  const result = f.finishTrial(10010, 10);
  assert.equal(result.geometry.ratio, 2); assert.ok(result.longestMilliseconds < 11);
});
test('hidden-page pause cannot become a measured long frame', () => {
  const f = fixture(); for (let now = 0; now < 5000; now += 10) f.tick(now);
  f.context.document.hidden = true; f.event('document', 'visibilitychange'); f.tick(30000);
  f.context.document.hidden = false; f.event('document', 'visibilitychange');
  const result = f.finishTrial(40000, 10);
  assert.equal(result.longestMilliseconds, 10); assert.equal(result.framesPerSecond, 100);
});
test('original synchronous workload remains separately identified', () => {
  const f = fixture(); f.context.innerWidth = 1920; f.elements.mode.value = 'finish'; f.event('mode', 'change');
  const result = f.finishTrial(0, 20);
  assert.equal(result.workload, 'single-shader-finish-v2'); assert.ok(f.finishes > 1000);
  assert.equal(result.framesPerSecond, 50); assert.equal(result.over120HzBudgetWith10PercentTolerance, result.measuredIntervals);
});
test('software renderers are rejected before measurements', () => {
  const f = fixture({ renderer: 'Google SwiftShader' });
  assert.match(f.elements.result.textContent, /Software renderer detected/); assert.equal(f.pending, 0);
});
test('oversized viewport stops instead of silently reducing pixel workload', () => {
  const f = fixture(); f.context.innerWidth = 8192; f.context.innerHeight = 8192; f.event('window', 'resize');
  assert.match(f.elements.result.textContent, /bounded test size/); assert.equal(f.pending, 0);
});
test('allocation mismatch stops instead of labelling a smaller buffer native', () => {
  const f = fixture({ badAllocation: true });
  assert.match(f.elements.result.textContent, /did not allocate/); assert.equal(f.pending, 0);
});
test('context loss invalidates an active measurement', () => {
  const f = fixture(); f.tick(0); f.event('c', 'webglcontextlost');
  assert.match(f.elements.result.textContent, /context lost/); assert.equal(f.pending, 0);
});
test('context loss also invalidates a completed result', () => {
  const f = fixture(); assert.ok(f.finishTrial()); f.event('c', 'webglcontextlost');
  assert.equal(f.context.macOpenVMGpuResult, null);
});
console.log(passed + ' benchmark-control checks passed; no hardware claim.');
