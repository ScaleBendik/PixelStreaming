const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const filename = path.resolve(__dirname, '../src/runtimeRecovery.ts');
const loaded = new Module(filename, module);
loaded.filename = filename; loaded.paths = module.paths;
loaded._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, filename);
const { installRuntimeRecovery, recoveryMessage } = loaded.exports;

test('copy separates unconfirmed interruptions, detected exits and attempted recovery', () => {
    assert.doesNotMatch(recoveryMessage(null, null), /crash|Automatic recovery/);
    assert.match(recoveryMessage('unexpected_exit', 'restart_requested'), /stopped unexpectedly.*Automatic recovery/);
    assert.match(recoveryMessage('unresponsive', 'detected'), /stopped responding/);
    assert.doesNotMatch(recoveryMessage('unresponsive', 'detected'), /Automatic recovery/);
    assert.match(recoveryMessage('unexpected_exit', 'restart_failed'), /could not start/);
});

test('frozen/opening streams get guidance, replacement frames clear it, and old frames cannot hide it', async t => {
    t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 0 });
    const oldDocument = global.document, oldFetch = global.fetch;
    const nodes = [], frames = new Map(), events = new Map(), transportEvents = new Map();
    let id = 0, reply = null;
    const element = () => ({ style: {}, dataset: {}, children: [], listeners: {},
        setAttribute() {}, appendChild(n) { this.children.push(n); },
        addEventListener(n, fn) { this.listeners[n] = fn; },
        remove() { const i = nodes.indexOf(this); if (i >= 0) nodes.splice(i, 1); } });
    global.document = { hidden: false, createElement: element, addEventListener() {}, removeEventListener() {} };
    global.fetch = async () => Response.json({ recovery: reply });
    const video = { srcObject: {}, paused: false,
        requestVideoFrameCallback(fn) { frames.set(++id, fn); return id; },
        cancelVideoFrameCallback(i) { frames.delete(i); } };
    const stream = { webRtcController: { videoPlayer: { getVideoElement: () => video } },
        videoElementParent: { appendChild(n) { nodes.push(n); } }, reconnect() {},
        addEventListener(n, fn) { events.set(n, fn); }, removeEventListener(n) { events.delete(n); },
        signallingProtocol: { transport: {
            addListener(n, fn) { transportEvents.set(n, fn); }, removeListener(n) { transportEvents.delete(n); }
        } } };
    const recovery = installRuntimeRecovery(stream, 'https://manager.test/servers/');
    t.after(() => { recovery.dispose(); global.document = oldDocument; global.fetch = oldFetch; });
    const tick = async ms => { t.mock.timers.tick(ms); for (let n = 0; n < 10; n++) await Promise.resolve(); };
    const present = () => { const callbacks = [...frames.values()]; frames.clear(); callbacks.forEach(fn => fn()); };
    await tick(21_000);
    assert.equal(nodes.length, 1); assert.match(nodes[0].dataset.message, /taking longer/);
    present(); assert.equal(nodes.length, 0);
    await tick(21_000); assert.match(nodes[0].dataset.message, /Video has stopped arriving/);
    reply = { kind: 'unresponsive', phase: 'restart_requested' };
    await tick(3_000); assert.match(nodes[0].dataset.message, /Automatic recovery/);
    const oldCallback = [...frames.values()][0];
    transportEvents.get('open')(); video.srcObject = {}; events.get('videoInitialized')();
    await tick(3_000); assert.equal(nodes.length, 1);
    oldCallback(); assert.equal(nodes.length, 1, 'retired generation cannot dismiss notice');
    present(); assert.equal(nodes.length, 0);
    reply = null;
    events.get('loadFreezeFrame')({ data: { isValid: true, shouldShowPlayOverlay: false } });
    await tick(30_000); assert.equal(nodes.length, 0, 'intentional Unreal freeze is not a video failure');
    events.get('hideFreezeFrame')();
    await tick(18_000); assert.equal(nodes.length, 0, 'unfreeze gets time to resume video');
    await tick(3_000); assert.equal(nodes.length, 1, 'an actual stall after unfreeze is still detected');
    video.paused = true;
    await tick(3_000); assert.equal(nodes.length, 0, 'pausing clears an unconfirmed warning');
    transportEvents.get('open')();
    await tick(30_000); assert.equal(nodes.length, 0, 'waiting for initial click-to-play is not a failure');
    video.paused = false;
    events.get('loadFreezeFrame')({ data: { isValid: true, shouldShowPlayOverlay: false } });
    reply = { kind: 'unexpected_exit', phase: 'restart_requested' };
    await tick(3_000); assert.match(nodes[0].dataset.message, /stopped unexpectedly/, 'host faults override intentional freeze');
    recovery.cancel(); await tick(30_000); assert.equal(nodes.length, 0, 'ended/idle sessions stay cancelled');
});
