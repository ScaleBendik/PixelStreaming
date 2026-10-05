const test = require('node:test');
const assert = require('node:assert/strict');
const { createSessionEndProxy } = require('../dist/session-end-proxy.js');
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
async function run({ url = 'https://api.test/', credential = 'signed.token.value', expected = id, method = 'POST', send } = {}) {
    const calls = [];
    const handler = createSessionEndProxy(url, async (...args) => {
        calls.push(args); return send ? send(...args) : { ok: true, json: async () => ({ accepted: true, sessionRequestId: id, secret: 'omit' }) };
    });
    const result = {};
    await handler({ method, get: n => n === 'X-SW-Session-End' ? credential : expected }, {
        setHeader(k,v) { result[k] = v; }, sendStatus(s) { result.status = s; }, json(body) { result.body = body; }
    });
    return { calls, result };
}
test('fixed destination forwards only capability and expected identity and strips upstream extras', async () => {
    const { calls, result } = await run();
    assert.equal(calls[0][0], 'https://api.test/session/player-end');
    assert.deepEqual(calls[0][1].headers, { 'X-SW-Session-End': 'signed.token.value', 'X-SW-Session-Request': id });
    assert.equal(calls[0][1].redirect, 'error');
    assert.deepEqual(result.body, { accepted: true, sessionRequestId: id });
    assert.equal(result['Cache-Control'], 'no-store');
    assert.equal((await run({ method: 'GET' })).calls[0][1].method, 'GET');
});
test('missing or invalid credentials and insecure upstream never cause a request', async () => {
    for (const options of [{ credential: '' }, { credential: 'x'.repeat(8193) }, { expected: '' }, { url: '' }, { url: 'http://api.test' }, { url: 'https://user:pass@api.test' }]) {
        const r = await run(options); assert.equal(r.calls.length, 0); assert.ok([401,503].includes(r.result.status));
    }
});
test('upstream rejection, malformed reply, redirect/network failure are never success', async () => {
    for (const send of [async () => ({ ok:false, status:403 }), async () => ({ ok:true,json:async()=>({ accepted:true }) }), async () => { throw Error('private detail'); }]) {
        const r = await run({ send }); assert.equal(r.result.body, undefined); assert.ok([403,502,503].includes(r.result.status));
    }
});
