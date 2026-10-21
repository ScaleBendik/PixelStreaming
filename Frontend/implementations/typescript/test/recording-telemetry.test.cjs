const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const filename = path.resolve(__dirname, '../src/recordingTelemetry.ts');
const loaded = new Module(filename, module);
loaded.filename = filename;
loaded.paths = module.paths;
loaded._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, filename);
const { RecordingTelemetry, consumeRecordingContext } = loaded.exports;
const tick = () => new Promise(resolve => setImmediate(resolve));
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const clip = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const context = { sessionRequestId: id, capability: 'recording-only-token' };
const event = (eventType = 'recording_saved') => ({ eventType, occurredAtUtc: '2026-10-21T12:00:00.000Z',
    codec: 'AV1', container: 'webm', bytesWritten: eventType === 'recording_saved' ? 512 : 0, durationMs: 1000 });
function storage() {
    const data = new Map();
    return { getItem: k => data.get(k) || null, setItem: (k,v) => data.set(k,v), removeItem: k => data.delete(k) };
}
function fixture(t, overrides = {}) {
    const calls = [], disk = overrides.storage || storage();
    let now = Date.parse('2026-10-21T12:00:01.000Z');
    const ack = (body, session = id) => ({ ok: true, json: async () => ({ accepted: true, sessionRequestId: session,
        recordingId: body.recordingId, eventType: body.eventType }) });
    const reporter = new RecordingTelemetry({ context, storage: disk, storageKey: 'queue', uuid: () => clip,
        now: () => now, ...overrides, send: async (url, init) => {
            const body = JSON.parse(init.body); calls.push({ url, init, body });
            return overrides.send ? overrides.send(body, init) : ack(body);
        } });
    t.after(() => reporter.dispose());
    return { reporter, calls, disk, ack, advance: ms => { now += ms; },
        queue: () => JSON.parse(disk.getItem('queue') || '[]') };
}

test('capability is scrubbed, scoped to the exact request, retained for reload and discarded for fresh launches', () => {
    const disk = storage();
    const hash = new URLSearchParams({ sw_recording: context.capability, other: 'keep' });
    assert.deepEqual(consumeRecordingContext(hash, id, true, disk, 'context'), context);
    assert.equal(hash.toString(), 'other=keep');
    assert.deepEqual(consumeRecordingContext(new URLSearchParams(), id, false, disk, 'context'), context);
    assert.equal(consumeRecordingContext(new URLSearchParams(), clip, false, disk, 'context'), undefined);
    assert.equal(disk.getItem('context'), null);
    consumeRecordingContext(new URLSearchParams({ sw_recording: context.capability }), id, true, disk, 'context');
    assert.equal(consumeRecordingContext(new URLSearchParams(), id, true, disk, 'context'), undefined);
    assert.equal(consumeRecordingContext(new URLSearchParams({ sw_recording: context.capability }), undefined, true, disk, 'context'), undefined);
});

test('malformed/empty incoming tokens clear stale context; denied storage is harmless', () => {
    const disk = storage();
    disk.setItem('context', JSON.stringify(context));
    const hash = new URLSearchParams('sw_recording=');
    assert.equal(consumeRecordingContext(hash, id, false, disk, 'context'), undefined);
    assert.equal(disk.getItem('context'), null);
    const denied = { getItem() { throw Error(); }, setItem() { throw Error(); }, removeItem() { throw Error(); } };
    assert.deepEqual(consumeRecordingContext(new URLSearchParams({ sw_recording: context.capability }), id, true, denied, 'context'), context);
});

test('without a capability or secure UUID no requests are made', async t => {
    for (const options of [{ context: undefined }, { uuid: () => { throw Error(); } }, { uuid: () => 'bad' }]) {
        const f = fixture(t, options);
        assert.equal(f.reporter.createObserver(), undefined);
        await tick(); assert.equal(f.calls.length, 0);
    }
});

test('the default transport preserves the browser fetch receiver', async t => {
    let calls = 0;
    t.mock.method(globalThis, 'fetch', async function (_url, init) {
        assert.equal(this, globalThis, 'Window.fetch must not be bound to the reporter');
        calls++;
        const body = JSON.parse(init.body);
        return { ok: true, json: async () => ({ accepted: true, sessionRequestId: id,
            recordingId: body.recordingId, eventType: body.eventType }) };
    });
    const disk = storage();
    const reporter = new RecordingTelemetry({ context, storage: disk, storageKey: 'queue', uuid: () => clip });
    t.after(() => reporter.dispose());
    reporter.createObserver()(event());
    await tick();
    assert.equal(calls, 1);
    assert.equal(disk.getItem('queue'), null);
});

test('metadata-only reports use a fixed route, recording-only auth, durable matching ack and one terminal per clip', async t => {
    const f = fixture(t);
    const observe = f.reporter.createObserver();
    observe(event('recording_started'));
    observe(event('recording_started'));
    observe(event());
    observe({ ...event('recording_failed'), failureCode: 'write_failed' });
    await tick();
    assert.equal(f.calls.length, 2);
    assert.deepEqual(f.calls[1].body, { ...event(), schemaVersion: 1, recordingId: clip });
    assert.equal(f.calls[1].url, '/api/recording-events');
    assert.deepEqual(f.calls[1].init.headers, { 'Content-Type': 'application/json', 'X-SW-Recording': context.capability, 'X-SW-Session-Request': id });
    assert.equal(f.calls[1].init.credentials, 'omit');
    assert.equal(f.calls[1].init.redirect, 'error');
    assert.equal(f.calls[1].init.keepalive, true);
    assert.deepEqual(f.queue(), []);
});

test('a stalled start does not prevent a saved report from being submitted', async t => {
    const f = fixture(t, { send: () => new Promise(() => {}) });
    const observe = f.reporter.createObserver();
    observe(event('recording_started'));
    observe(event());
    assert.deepEqual(f.calls.map(c => c.body.eventType), ['recording_started', 'recording_saved']);
    assert.equal(f.queue().length, 2);
});

test('transient errors and wrong acknowledgements retry the exact identity and payload after backoff', async t => {
    for (const send of [async () => { throw Error('offline'); }, async () => ({ ok: false, status: 429 }),
        async () => ({ ok: false, status: 503 }), async () => ({ ok: true, json: async () => ({ accepted: true, sessionRequestId: clip, recordingId: clip, eventType: 'recording_saved' }) }),
        async () => ({ ok: true, json: async () => null })]) {
        const f = fixture(t, { send });
        f.reporter.createObserver()(event());
        await tick();
        f.reporter.flush();
        assert.equal(f.calls.length, 1);
        f.advance(2001); f.reporter.flush(); await tick();
        assert.equal(f.calls.length, 2);
        assert.deepEqual(f.calls[0].body, f.calls[1].body);
        assert.equal(f.queue().length, 1);
    }
});

test('missing API, denied/expired capability, conflict and invalid payload are not retried', async t => {
    for (const status of [400, 401, 403, 404, 405, 409, 410, 413, 415, 422, 501]) {
        const f = fixture(t, { send: async () => ({ ok: false, status }) });
        f.reporter.createObserver()(event()); await tick();
        assert.deepEqual(f.queue(), [], String(status));
        f.advance(60_000); f.reporter.flush(); assert.equal(f.calls.length, 1);
    }
});

test('reload retries old pending clips with their original credential; a new session cannot retag them', async t => {
    const disk = storage();
    const before = fixture(t, { storage: disk, send: async () => { throw Error('offline'); } });
    before.reporter.createObserver()(event()); await tick(); before.reporter.dispose();
    const after = fixture(t, { storage: disk, context: { sessionRequestId: clip, capability: 'new-session' } });
    await tick();
    assert.equal(after.calls[0].init.headers['X-SW-Session-Request'], id);
    assert.equal(after.calls[0].init.headers['X-SW-Recording'], context.capability);
    assert.equal(after.calls[0].body.recordingId, clip);
    assert.deepEqual(after.queue(), []);
});

test('queue is bounded and expired entries or malformed/private payloads are not sent', async t => {
    const f = fixture(t, { send: async () => { throw Error('offline'); } });
    for (let i = 0; i < 140; i++) f.reporter.createObserver()(event());
    await tick();
    assert.equal(f.queue().length, 128);
    f.advance(86_400_001); f.reporter.flush();
    assert.deepEqual(f.queue(), []);
    const before = f.calls.length;
    for (const patch of [{ filename: 'secret.webm' }, { durationMs: -1 }, { bytesWritten: 0 },
        { codec: 'VP8' }, { container: 'mp4' }, { occurredAtUtc: 'bad' }]) {
        f.reporter.createObserver()({ ...event(), ...patch });
    }
    assert.equal(f.calls.length, before);
});

test('blocked/quota-full storage still allows in-memory reports; restored data is validated', async t => {
    const denied = { getItem() { throw Error(); }, setItem() { throw Error(); }, removeItem() { throw Error(); } };
    const f = fixture(t, { storage: denied });
    assert.doesNotThrow(() => f.reporter.createObserver()(event()));
    await tick(); assert.equal(f.calls.length, 1);
    for (const raw of ['bad JSON', '{}', JSON.stringify([{ context, report: { ...event(), schemaVersion: 1, recordingId: clip, filename: 'private' }, expiresAt: Date.now() + 60_000 }])]) {
        const disk = storage(); disk.setItem('queue', raw);
        const restored = fixture(t, { storage: disk });
        assert.equal(restored.calls.length, 0);
    }
});
