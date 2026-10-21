const test = require('node:test');
const assert = require('node:assert/strict');
const { createRecordingEventsProxy, createRecordingEventsRouter, validRecordingEvent } = require('../dist/recording-events-proxy');
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const clip = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const body = { schemaVersion: 1, recordingId: clip, eventType: 'recording_saved',
    occurredAtUtc: '2026-10-21T12:00:00.000Z', codec: 'AV1', container: 'webm', bytesWritten: 512, durationMs: 1000 };
const ack = { accepted: true, sessionRequestId: id, recordingId: clip, eventType: 'recording_saved' };
async function run(options = {}) {
    const calls = [], result = {};
    const handler = createRecordingEventsProxy(options.url ?? 'https://api.example.test/some/base', async (...args) => {
        calls.push(args); return options.send ? options.send(...args) : { ok: true, json: async () => ({ ...ack, secret: 'omit' }) };
    });
    await handler({ method: options.method || 'POST', body: options.body ?? body,
        get: n => n === 'X-SW-Recording' ? options.capability ?? 'recording-token' : options.sessionId ?? id }, {
        setHeader(k, v) { result[k] = v; }, sendStatus(s) { result.status = s; }, json(b) { result.body = b; }
    });
    return { calls, result };
}

test('only the fixed HTTPS recording endpoint and dedicated headers are forwarded; acknowledgement is stripped', async () => {
    const { calls, result } = await run();
    assert.equal(calls[0][0], 'https://api.example.test/session/player-recordings');
    assert.deepEqual(calls[0][1].headers, { 'Content-Type': 'application/json', 'X-SW-Recording': 'recording-token', 'X-SW-Session-Request': id });
    assert.deepEqual(JSON.parse(calls[0][1].body), body);
    assert.equal(calls[0][1].redirect, 'error');
    assert.equal(calls[0][1].method, 'POST');
    assert.deepEqual(result.body, ack);
    assert.equal(result['Cache-Control'], 'no-store');
});

test('all recording codecs, terminal failures and a start before any write fit the contract', () => {
    for (const [codec, container] of [['AV1', 'webm'], ['VP9', 'webm'], ['H264', 'matroska']]) {
        assert.ok(validRecordingEvent({ ...body, codec, container }));
    }
    assert.ok(validRecordingEvent({ ...body, eventType: 'recording_started', bytesWritten: 0 }));
    assert.ok(validRecordingEvent({ ...body, eventType: 'recording_failed', failureCode: 'file_open_failed', bytesWritten: 0 }));
});

test('unknown fields, media/paths, malformed IDs, unbounded metrics and incompatible formats never reach the API', async () => {
    for (const patch of [{ filename: 'private.webm' }, { video: 'base64' }, { sessionRequestId: id },
        { endpoint: 'https://untrusted.test/' }, { schemaVersion: 2 }, { recordingId: '-'.repeat(36) },
        { eventType: 'anything' }, { occurredAtUtc: 'invalid' }, { codec: 'VP8' }, { container: 'mp4' },
        { codec: 'H264' }, { bytesWritten: -1 }, { bytesWritten: 0 }, { bytesWritten: 2 ** 41 },
        { durationMs: 0.5 }, { durationMs: 86_400_001 }, { eventType: 'recording_failed' },
        { failureCode: 'private error' }]) {
        const r = await run({ body: { ...body, ...patch } });
        assert.equal(r.result.status, 400, JSON.stringify(patch));
        assert.equal(r.calls.length, 0);
    }
});

test('invalid credentials, methods and unsafe/missing upstream configuration do not forward anything', async () => {
    for (const options of [{ capability: '' }, { capability: 'x'.repeat(8193) }, { capability: 'token with spaces' },
        { sessionId: '-'.repeat(36) }, { url: '' }, { url: 'http://api.test' }, { url: 'https://user:password@api.test' },
        { method: 'GET' }, { method: 'HEAD' }, { method: 'PUT' }]) {
        const r = await run(options);
        assert.equal(r.calls.length, 0);
        assert.ok([401, 405, 503].includes(r.result.status));
    }
});

test('no success without durable API acknowledgement of the exact session, clip and event', async () => {
    for (const value of [null, {}, { ...ack, accepted: false }, { ...ack, sessionRequestId: clip },
        { ...ack, recordingId: id }, { ...ack, eventType: 'recording_started' }]) {
        const r = await run({ send: async () => ({ ok: true, json: async () => value }) });
        assert.equal(r.result.status, 502);
        assert.equal(r.result.body, undefined);
    }
    const failed = await run({ send: async () => { throw Error('private upstream detail'); } });
    assert.equal(failed.result.status, 503);
    for (const status of [401, 403, 404, 409, 410, 429, 503]) {
        const r = await run({ send: async () => ({ ok: false, status }) });
        assert.equal(r.result.status, status);
        assert.equal(r.result.body, undefined);
    }
});

test('HTTP route bounds parsing, hides parser errors and never forwards HEAD/GET', async () => {
    const express = require('express');
    const calls = [];
    const app = express();
    app.use('/api/recording-events', createRecordingEventsRouter('https://api.test', async (_url, init) => {
        calls.push(init); return { ok: true, json: async () => ack };
    }));
    const server = app.listen(0, '127.0.0.1');
    try {
        await new Promise((resolve, reject) => { server.once('listening', resolve); server.once('error', reject); });
        const url = 'http://127.0.0.1:' + server.address().port + '/api/recording-events';
        const headers = { 'Content-Type': 'application/json', 'X-SW-Recording': 'recording-token', 'X-SW-Session-Request': id };
        for (const method of ['GET', 'HEAD', 'PUT']) {
            const res = await fetch(url, { method, headers });
            assert.equal(res.status, 405); await res.text();
        }
        for (const [payload, expected] of [['{"secret":', 400], [JSON.stringify({ ...body, padding: 'x'.repeat(8192) }), 413]]) {
            const res = await fetch(url, { method: 'POST', headers, body: payload });
            assert.equal(res.status, expected);
            assert.equal(res.headers.get('cache-control'), 'no-store');
            assert.equal((await res.text()).includes('secret'), false);
        }
        assert.equal(calls.length, 0);
        const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body) });
        assert.equal(res.status, 200);
        assert.deepEqual(await res.json(), ack);
        assert.equal(calls.length, 1);
    } finally {
        server.closeAllConnections();
        await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    }
});
