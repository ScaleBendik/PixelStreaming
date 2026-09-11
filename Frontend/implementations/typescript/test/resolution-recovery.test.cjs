const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const filename = path.resolve(__dirname, '../src/resolutionRecovery.ts');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const loaded = new Module(filename, module);
loaded.filename = filename;
loaded.paths = module.paths;
loaded._compile(compiled, filename);
const { parseResolutionApplied, installResolutionRecovery } = loaded.exports;
const response = (width = 2560, height = 1440) => JSON.stringify({ type: 'resolutionApplied', width, height });

function fixture(t) {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const previousDocument = global.document;
    const nodes = [];
    const element = () => ({
        style: {}, children: [], textContent: '', listeners: {},
        setAttribute() {}, appendChild(child) { this.children.push(child); },
        addEventListener(name, handler) { this.listeners[name] = handler; },
        remove() { const index = nodes.indexOf(this); if (index >= 0) nodes.splice(index, 1); }
    });
    global.document = { createElement: element, body: { appendChild(node) { nodes.push(node); } } };
    t.after(() => { recovery.dispose(); global.document = previousDocument; });
    let callbackId = 0;
    const callbacks = new Map();
    const video = {
        srcObject: {}, videoWidth: 2240, videoHeight: 1260,
        requestVideoFrameCallback(callback) { callbacks.set(++callbackId, callback); return callbackId; },
        cancelVideoFrameCallback(id) { callbacks.delete(id); }
    };
    const events = new Map();
    let listener;
    const stream = {
        config: { scaleWorldCodecPolicy: { selectedCodec: 'H264' } },
        reconnects: 0,
        webRtcController: { videoPlayer: { getVideoElement: () => video } },
        reconnect() { this.reconnects++; },
        addResponseEventListener(_name, callback) { listener = callback; },
        removeResponseEventListener() { listener = undefined; },
        addEventListener(name, callback) { events.set(name, callback); },
        removeEventListener(name) { events.delete(name); }
    };
    let explicitSizes = 0;
    const recovery = installResolutionRecovery(stream, () => explicitSizes++);
    const emit = (name, event) => events.get(name)?.(event);
    return {
        stream, video, nodes, callbacks, recovery, emit,
        send: (message = response()) => listener?.(message),
        get explicitSizes() { return explicitSizes; },
        replace() { emit('webRtcDisconnected'); video.srcObject = {}; emit('videoInitialized'); emit('webRtcConnected'); },
        present(width, height) {
            video.videoWidth = width; video.videoHeight = height;
            const pending = [...callbacks.values()]; callbacks.clear();
            pending.forEach(callback => callback(0, { width, height }));
        }
    };
}

test('accepts the four Blueprint payloads and ignores unrelated/malformed/unbounded responses', () => {
    for (const [w, h] of [[1920,1080],[2240,1260],[2560,1440],[3840,2160]]) {
        assert.deepEqual(parseResolutionApplied(response(w,h)), { width: w, height: h });
    }
    for (const value of ['null','[]','bad JSON', '{}', response('2560',1440), response(0,1440),
        response(8193,1440), response(2560.5,1440), 'x'.repeat(513)]) {
        assert.equal(parseResolutionApplied(value), null);
    }
});

test('one reconnect completes only on a replacement-source frame with requested dimensions', t => {
    const f = fixture(t); f.send(); f.send();
    assert.equal(f.stream.reconnects, 1);
    f.emit('videoInitialized'); f.emit('webRtcConnected'); // Old stream is not proof.
    assert.equal(f.callbacks.size, 0);
    f.replace(); f.present(2240,1260);
    assert.equal(f.nodes.length, 1);
    f.present(2560,1440);
    assert.equal(f.nodes.length, 0);
    t.mock.timers.tick(30000);
    assert.equal(f.nodes.length, 0);
    f.send(); assert.equal(f.stream.reconnects, 1); // Late duplicate after success.
});

test('rapid size changes coalesce, then a later deliberate size starts another recovery', t => {
    const f = fixture(t); f.send(); f.send(response(3840,2160));
    assert.equal(f.stream.reconnects, 1);
    f.replace(); f.present(2560,1440); assert.equal(f.nodes.length, 1);
    f.present(3840,2160); assert.equal(f.nodes.length, 0);
    f.send(response(1920,1080)); assert.equal(f.stream.reconnects, 2);
});

test('connected-before-track ordering also arms replacement-frame verification', t => {
    const f = fixture(t); f.send(); f.emit('webRtcDisconnected'); f.emit('webRtcConnected');
    f.video.srcObject = {}; f.emit('videoInitialized'); f.present(2560,1440);
    assert.equal(f.nodes.length, 0);
});

test('stale frame callbacks cannot complete a later reconnect generation', t => {
    const f = fixture(t); f.send(); f.replace();
    const stale = [...f.callbacks.values()][0];
    f.replace(); stale(0, { width:2560, height:1440 });
    assert.equal(f.nodes.length, 1);
    f.present(2560,1440); assert.equal(f.nodes.length, 0);
});

test('timeout offers one manual retry and does not loop on duplicate messages or late frames', t => {
    const f = fixture(t); f.send(); f.replace();
    const stale = [...f.callbacks.values()][0];
    t.mock.timers.tick(30000);
    assert.match(f.nodes[0].children[0].textContent, /did not return/);
    stale(0, { width:2560, height:1440 });
    f.send(); t.mock.timers.tick(60000); assert.equal(f.stream.reconnects, 1);
    f.nodes[0].children[1].listeners.click(); assert.equal(f.stream.reconnects, 2);
    f.replace(); f.present(2560,1440); assert.equal(f.nodes.length, 0);
});

test('no frame-callback support cannot falsely confirm recovery', t => {
    const f = fixture(t); f.video.requestVideoFrameCallback = undefined;
    f.send(); f.replace(); f.present(2560,1440);
    assert.equal(f.nodes.length, 1);
    t.mock.timers.tick(30000); assert.match(f.nodes[0].children[0].textContent, /did not return/);
});

test('session cancellation and page disposal remove pending UI/timers/listeners', t => {
    const f = fixture(t); f.send(); f.replace(); f.recovery.cancel();
    t.mock.timers.tick(30000); assert.equal(f.nodes.length, 0);
    f.send(); f.recovery.dispose(); f.send();
    t.mock.timers.tick(30000);
    assert.equal(f.nodes.length, 0); assert.equal(f.stream.reconnects, 2);
});

test('unrelated responses do not change viewport policy or start recovery; reconnect errors offer retry', t => {
    const f = fixture(t); f.send('{"type":"other"}'); assert.equal(f.explicitSizes, 0);
    f.stream.reconnect = () => { throw new Error('closed'); };
    f.send(); assert.equal(f.explicitSizes, 1);
    assert.match(f.nodes[0].children[0].textContent, /did not return/);
});


test('AV1 and VP9 resolution requests and Blueprint notifications never reconnect', t => {
    const f = fixture(t);
    for (const codec of ['AV1', 'VP9']) {
        f.stream.config.scaleWorldCodecPolicy.selectedCodec = codec;
        f.send();
        f.emit('resolutionRequested', { data: { width: 3840, height: 2160 } });
        f.present(3840, 2160);
    }
    assert.equal(f.stream.reconnects, 0);
    assert.equal(f.nodes.length, 0);
});

test('H264 GUI request waits for resized frames, then verifies replacement frames', t => {
    const f = fixture(t);
    f.emit('resolutionRequested', { data: { width: 3840, height: 2160 } });
    f.present(2240,1260);
    assert.equal(f.stream.reconnects, 0);
    f.present(3840,2160);
    assert.equal(f.stream.reconnects, 1);
    f.replace(); f.present(3840,2160);
    assert.equal(f.nodes.length, 0);
});
