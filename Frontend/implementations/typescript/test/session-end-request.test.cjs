const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const source = ts.transpileModule(fs.readFileSync(require.resolve('../src/sessionEndRequest.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
function fixture(responses) {
    const exports = {}, calls = [];
    vm.runInNewContext(source, { exports, AbortController, window: { setTimeout, clearTimeout }, fetch: async (url, options) => {
        calls.push({ url, ...options }); const next = responses.shift();
        if (next instanceof Error) throw next;
        return { ok: next.ok !== false, json: async () => next };
    } });
    return { run: exports.requestSessionEnd, calls };
}
test('direct end accepts only an exact response and sends no cookies or general API login', async () => {
    const f = fixture([{ accepted: true, sessionRequestId: 'one' }]);
    assert.equal(await f.run('capability', 'one'), true);
    assert.equal(f.calls.length, 1); assert.equal(f.calls[0].method, 'POST');
    assert.equal(f.calls[0].url, '/api/session-end'); assert.equal(f.calls[0].credentials, 'omit');
    assert.equal(f.calls[0].headers['X-SW-Session-End'], 'capability');
    assert.equal(f.calls[0].headers['X-SW-Session-Request'], 'one');
    assert.equal(f.calls[0].headers.Authorization, undefined);
});
test('lost response reconciles with GET and never repeats POST', async () => {
    const f = fixture([new Error('lost response'), { accepted: true, sessionRequestId: 'one' }]);
    assert.equal(await f.run('capability', 'one'), true);
    assert.deepEqual(f.calls.map(c => c.method), ['POST', 'GET']);
});
test('wrong identity, expired credentials and uncertain outcomes cannot close the stream', async () => {
    for (const responses of [
        [{ accepted: true, sessionRequestId: 'other' }, { accepted: false, sessionRequestId: 'one' }],
        [{ ok: false }, { ok: false }], [new Error('offline'), new Error('offline')]
    ]) {
        const f = fixture(responses);
        assert.equal(await f.run('capability', 'one'), false);
        assert.deepEqual(f.calls.map(c => c.method), ['POST', 'GET']);
    }
});
