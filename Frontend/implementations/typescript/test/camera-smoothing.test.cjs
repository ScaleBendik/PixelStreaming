const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const source = ts.transpileModule(fs.readFileSync(require.resolve('../src/cameraSmoothing.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function fixture(t, { open = true, send, publish, registrationFails = false } = {}) {
    const events = new Map(), responses = new Map(), timers = new Map(), sent = [], states = [];
    let timerId = 0;
    const stream = {
        webRtcController: { isDataChannelOpen: () => open },
        emitUIInteraction(message) { sent.push(JSON.parse(JSON.stringify(message))); return send ? send(message) : true; },
        addEventListener(name, listener) { if (registrationFails) throw new Error('registration'); events.set(name, listener); },
        removeEventListener(name) { events.delete(name); },
        addResponseEventListener(name, listener) { responses.set(name, listener); },
        removeResponseEventListener(name) { responses.delete(name); }
    };
    const exports = {};
    vm.runInNewContext(source, { exports, crypto: { randomUUID: () => 'viewer' }, window: {
        setTimeout(fn, ms) { const id = ++timerId; timers.set(id, { fn, ms }); return id; },
        clearTimeout(id) { timers.delete(id); }
    } });
    const sync = exports.createCameraSmoothingSync(stream, state => { states.push(state); publish?.(state); });
    t.after(() => sync.dispose());
    return {
        sync, stream, events, responses, timers, sent, states,
        setOpen(value) { open = value; },
        event(name) { events.get(name)?.(); },
        raw(value) { for (const listener of responses.values()) listener(value); },
        reply(enabled, requestId = sent.at(-1)?.requestId) {
            this.raw(JSON.stringify({ type: 'CameraSmoothing.State', enabled, requestId }));
        },
        broadcast(enabled) { this.raw(JSON.stringify({ type: 'CameraSmoothing.State', enabled })); },
        tick() { const [id, entry] = timers.entries().next().value; timers.delete(id); entry.fn(); }
    };
}

test('initialization waits for the data channel and a correlated Unreal snapshot, never sending a default Set', t => {
    const f = fixture(t, { open: false });
    assert.equal(f.sync.snapshot.enabled, null);
    assert.equal(f.sync.snapshot.phase, 'disconnected');
    assert.deepEqual(f.sent, []);
    f.broadcast(true);
    assert.equal(f.sync.snapshot.enabled, null);
    f.setOpen(true); f.event('dataChannelOpen'); f.event('dataChannelOpen');
    assert.equal(f.sent.length, 1, 'duplicate/split-channel opens do not create duplicate queries');
    assert.equal(f.sent[0].type, 'CameraSmoothing.Get');
    f.broadcast(true);
    assert.equal(f.sync.snapshot.phase, 'syncing', 'a broadcast cannot initialize a connection');
    f.reply(true);
    assert.equal(f.sync.snapshot.enabled, true);
    assert.equal(f.sync.snapshot.phase, 'ready');
    assert.equal(f.timers.size, 0);
});

test('Get retries are bounded and explicit Retry can recover an older or late-starting Blueprint', t => {
    const f = fixture(t);
    f.tick(); f.tick(); f.tick();
    assert.equal(f.sent.length, 3);
    assert.equal(new Set(f.sent.map(m => m.requestId)).size, 1);
    assert.equal(f.sync.snapshot.phase, 'unavailable');
    assert.equal(f.sync.snapshot.enabled, null);
    assert.equal(f.timers.size, 0);
    f.sync.retry();
    assert.notEqual(f.sent[3].requestId, f.sent[0].requestId);
    f.reply(false);
    assert.equal(f.sync.snapshot.phase, 'ready');
    assert.equal(f.sync.snapshot.enabled, false);
});

test('Set preserves confirmed state until acknowledgement and widget broadcasts keep both menus synchronized', t => {
    const f = fixture(t); f.reply(false);
    f.sync.setEnabled(true); f.sync.setEnabled(true);
    assert.equal(f.sent.length, 2, 'only one Set while awaiting confirmation');
    assert.equal(f.sent[1].type, 'CameraSmoothing.Set');
    assert.equal(f.sent[1].enabled, true);
    assert.equal(f.sync.snapshot.phase, 'setting');
    assert.equal(f.sync.snapshot.enabled, false, 'no optimistic success');
    f.broadcast(true);
    assert.equal(f.sync.snapshot.enabled, true);
    assert.equal(f.sync.snapshot.phase, 'setting', 'broadcast does not acknowledge our request');
    f.reply(true);
    assert.equal(f.sync.snapshot.phase, 'ready');
    f.broadcast(false);
    assert.equal(f.sync.snapshot.enabled, false);
    assert.equal(f.sent.length, 2, 'state notifications never echo Set commands');
});

test('Unreal can reject Set by acknowledging the actual unchanged value', t => {
    const f = fixture(t); f.reply(false); f.sync.setEnabled(true); f.reply(false);
    assert.equal(f.sync.snapshot.phase, 'ready');
    assert.equal(f.sync.snapshot.enabled, false);
    assert.match(f.sync.snapshot.message, /not applied/);
    f.broadcast(true);
    assert.equal(f.sync.snapshot.enabled, true);
    assert.equal(f.sync.snapshot.message, '', 'a later authoritative update clears the old refusal');
});

test('Set timeout queries actual state without retrying the mutation, and ignores late acknowledgements', t => {
    const f = fixture(t); f.reply(false); f.sync.setEnabled(true);
    const oldSet = f.sent.at(-1).requestId;
    f.tick();
    assert.equal(f.sent.at(-1).type, 'CameraSmoothing.Get');
    assert.equal(f.sync.snapshot.enabled, null);
    f.reply(true, oldSet);
    assert.equal(f.sync.snapshot.phase, 'syncing');
    f.reply(false);
    assert.equal(f.sync.snapshot.enabled, false);
    assert.match(f.sync.snapshot.message, /not applied/);
    assert.equal(f.sent.filter(m => m.type === 'CameraSmoothing.Set').length, 1);
});

for (const mode of ['false', 'throw']) {
    test(`failed ${mode} send is contained and a Set failure resynchronizes`, t => {
        const f = fixture(t, { send: message => {
            if (message.type === 'CameraSmoothing.Get') return true;
            if (mode === 'throw') throw new Error('channel unavailable');
            return false;
        } });
        f.reply(true);
        assert.doesNotThrow(() => f.sync.setEnabled(false));
        assert.equal(f.sent.at(-1).type, 'CameraSmoothing.Get');
        assert.equal(f.sync.snapshot.phase, 'syncing');
        f.reply(true);
        assert.equal(f.sync.snapshot.enabled, true);
        assert.match(f.sync.snapshot.message, /not applied/);
    });
}

test('query send exceptions and missing Blueprint support exhaust safely', t => {
    const f = fixture(t, { send: () => { throw new Error('closed'); } });
    assert.doesNotThrow(() => { f.tick(); f.tick(); f.tick(); });
    assert.equal(f.sync.snapshot.phase, 'unavailable');
    assert.equal(f.timers.size, 0);
});

test('disconnect clears confirmed state and old responses cannot initialize a new connection', t => {
    const f = fixture(t); f.reply(true); f.sync.setEnabled(false);
    const oldId = f.sent.at(-1).requestId;
    f.setOpen(false); f.event('webRtcDisconnected');
    assert.equal(f.sync.snapshot.enabled, null);
    assert.equal(f.timers.size, 0);
    f.setOpen(true); f.event('dataChannelOpen');
    f.reply(false, oldId); f.broadcast(true);
    assert.equal(f.sync.snapshot.enabled, null);
    f.reply(false);
    assert.equal(f.sync.snapshot.enabled, false);
    f.event('webRtcFailed');
    assert.equal(f.sync.snapshot.phase, 'disconnected');
});

test('malformed, unrelated and other viewers replies never escape shared dispatch or alter the checkbox', t => {
    const f = fixture(t);
    for (const response of ['Navigation.Free', '{', 'null', '[]', JSON.stringify({ type: 'CameraSmoothing.State', enabled: 'false' }),
        JSON.stringify({ type: 'CameraSmoothing.State', enabled: true, requestId: 'other-viewer' }), 'x'.repeat(5000)]) {
        assert.doesNotThrow(() => f.raw(response));
        assert.equal(f.sync.snapshot.enabled, null);
    }
    f.reply(true); assert.equal(f.sync.snapshot.enabled, true);
});

test('presentation failures and listener-registration failures remain isolated', t => {
    const f = fixture(t, { publish: () => { throw new Error('render'); } });
    assert.doesNotThrow(() => f.reply(true));
    assert.equal(f.sync.snapshot.phase, 'ready');
    const broken = fixture(t, { registrationFails: true });
    assert.equal(broken.sync.snapshot.phase, 'unavailable');
    assert.equal(broken.events.size, 0);
    assert.equal(broken.responses.size, 0);
    assert.equal(broken.timers.size, 0);
});

test('disposal removes listeners and prevents late replies or timers mutating UI', t => {
    const f = fixture(t);
    const response = [...f.responses.values()][0], timer = [...f.timers.values()][0].fn;
    const count = f.states.length;
    f.sync.dispose();
    response(JSON.stringify({ type: 'CameraSmoothing.State', enabled: true, requestId: f.sent[0].requestId }));
    timer(); f.sync.retry(); f.sync.setEnabled(true);
    assert.equal(f.states.length, count);
    assert.equal(f.sent.length, 1);
    assert.equal(f.events.size, 0);
    assert.equal(f.responses.size, 0);
    assert.equal(f.timers.size, 0);
});
