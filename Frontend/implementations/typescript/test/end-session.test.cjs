const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const filename = path.resolve(__dirname, '../src/endSession.ts');
const loaded = new Module(filename, module);
loaded.filename = filename; loaded.paths = module.paths;
loaded._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, filename);
const { installEndSession, isManagedEndContext, buildEndSessionUrl } = loaded.exports;

const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

test('owner presentation excludes shadows, malformed tickets and previous request context', () => {
    const ticket = claims => 'header.' + Buffer.from(JSON.stringify(claims)).toString('base64url') + '.signature';
    assert.equal(isManagedEndContext(ticket({ sessionRequestId: 'one' }), 'one'), true);
    assert.equal(isManagedEndContext(ticket({ sessionRequestId: 'two' }), 'one'), false);
    assert.equal(isManagedEndContext(ticket({ shadowSessionRequestId: 'one' }), 'one'), false);
    assert.equal(isManagedEndContext('bad', 'one'), false);
    const url = new URL(buildEndSessionUrl('https://manager.test', { region: 'r', instanceId: 'i', sessionRequestId: 's' }));
    assert.equal(url.pathname, '/servers/');
    assert.equal(url.searchParams.get('endSessionRequestId'), 's');
    assert.equal(url.searchParams.has('reconnectInstanceId'), false);
});

test('accepted session end waits for the recording save before navigating', async t => {
    let finish;
    const saved = new Promise(resolve => { finish = resolve; });
    let requests = 0;
    const f = fixture(t, { beforeNavigate: () => { requests++; return saved; } });
    f.controller.markEnded(); f.controller.markEnded();
    assert.equal(f.ended, 1);
    assert.equal(requests, 1);
    assert.deepEqual(f.navigations, []);
    finish(true); await flush();
    assert.deepEqual(f.navigations, ['https://manager.test/servers/']);
});

test('failed or cancelled recording save keeps ended session on the page with a guarded return action', async t => {
    let allow = false;
    const f = fixture(t, { beforeNavigate: async () => allow });
    f.controller.markEnded(); await flush();
    assert.deepEqual(f.navigations, []);
    const link = f.nodes.find(n => n.tag === 'a');
    assert.equal(link.style.display, 'block');
    let prevented = false;
    allow = true;
    link.listeners.click({ preventDefault() { prevented = true; } }); await flush();
    assert.equal(prevented, true);
    assert.deepEqual(f.navigations, ['https://manager.test/servers/']);
});

test('manager confirmation fallback is also guarded by recording finalization', async t => {
    let finish;
    const f = fixture(t, { beforeNavigate: () => new Promise(resolve => { finish = resolve; }) });
    f.button.click(); f.confirm.click();
    assert.deepEqual(f.navigations, []);
    finish(false); await flush();
    assert.deepEqual(f.navigations, []);
});

test('authoritative end supersedes pending manager confirmation after the recording saves', async t => {
    let finish, requests = 0;
    const f = fixture(t, { beforeNavigate: () => { requests++; return new Promise(resolve => { finish = resolve; }); } });
    f.button.click(); f.confirm.click();
    f.controller.markEnded();
    assert.equal(requests, 1, 'reuse the in-flight save rather than starting another');
    assert.deepEqual(f.navigations, []);
    finish(true); await flush();
    assert.deepEqual(f.navigations, ['https://manager.test/servers/']);
    assert.equal(f.ended, 1);
});

test('authoritative end removes old confirmation intent from retry links after cancelled or rejected saves', async t => {
    for (const rejected of [false, true]) {
        await t.test(rejected ? 'rejected save' : 'cancelled save', async t => {
            let finish, reject;
            const f = fixture(t, { beforeNavigate: () => new Promise((resolve, fail) => { finish = resolve; reject = fail; }) });
            f.button.click(); f.confirm.click();
            f.controller.markEnded();
            if (rejected) reject(new Error('Save failed')); else finish(false);
            await flush();
            assert.deepEqual(f.navigations, []);
            const link = f.nodes.find(n => n.tag === 'a');
            assert.equal(link.href, 'https://manager.test/servers/');
            assert.equal(link.textContent, 'Return to session manager');
            assert.equal(link.style.display, 'block');
            link.listeners.click({ preventDefault() {} });
            finish(true); await flush();
            assert.deepEqual(f.navigations, ['https://manager.test/servers/']);
        });
    }
});

test('disposing the control prevents a pending save from navigating or changing removed UI', async t => {
    let finish;
    const f = fixture(t, { beforeNavigate: () => new Promise(resolve => { finish = resolve; }) });
    f.controller.markEnded();
    const status = f.nodes.find(n => n.attributes.role === 'status');
    const previousStatus = status.textContent;
    f.controller.dispose();
    finish(true); await flush();
    assert.deepEqual(f.navigations, []);
    assert.equal(status.textContent, previousStatus);
    assert.equal(f.input.at(-1), false);
});

test('disposing during a direct end fences its late completion and subsequent markEnded calls', async t => {
    let finish;
    const f = fixture(t, { endDirect: () => new Promise(resolve => { finish = resolve; }) });
    f.button.click();
    const completion = f.confirm.click();
    f.controller.dispose();
    finish(true); await completion;
    f.controller.markEnded();
    assert.equal(f.ended, 0);
    assert.deepEqual(f.navigations, []);
    assert.equal(f.input.at(-1), false);
});

function fixture(t, extra = {}) {
    const originalWindow = global.window, originalDocument = global.document;
    const nodes = [], events = new Map(), timers = new Map();
    let timerId = 0, closes = 0, ended = 0;
    const input = [];
    const navigations = [];
    function element(tag) {
        const el = { tag, children: [], style: {}, attributes: {}, listeners: {}, open: false, disabled: false,
            setAttribute(k, v) { this.attributes[k] = v; }, append(...items) { this.children.push(...items); },
            appendChild(item) { this.children.push(item); }, addEventListener(n, fn) { this.listeners[n] = fn; },
            showModal() { this.open = true; }, close() { this.open = false; this.listeners.close?.(); },
            focus() {}, remove() {}, click() { if (!this.disabled) return this.listeners.click?.(); } };
        nodes.push(el); return el;
    }
    global.document = { createElement: element, exitPointerLock() {} };
    global.window = { location: { assign(url) { navigations.push(url); } }, addEventListener(n, fn) { events.set(n, fn); }, removeEventListener(n) { events.delete(n); },
        setTimeout(fn) { timers.set(++timerId, fn); return timerId; }, clearTimeout(id) { timers.delete(id); }, close() { closes++; } };
    const context = { region: 'r', instanceId: 'i', sessionRequestId: 's' };
    const controller = installEndSession({ controls: element('controls'), modalParent: element('parent'), managerOrigin: 'https://manager.test', context,
        setModalInput(open) { input.push(open); }, onEnded() { ended++; }, ...extra });
    const receive = (overrides = {}) => {
        const sent = [];
        const port = { close() {}, postMessage(data) { sent.push(data); }, onmessage: null };
        events.get('message')({ origin: 'https://manager.test', source: {}, data: { type: 'sw-session-end-channel', version: 1, ...context }, ports: [port], ...overrides });
        return { port, sent };
    };
    t.after(() => { controller.dispose(); global.window = originalWindow; global.document = originalDocument; });
    return { nodes, input, controller, receive, timers, navigations,
        get closes() { return closes; }, get ended() { return ended; },
        get button() { return nodes.find(n => n.id === 'endSessionBtn'); },
        get dialog() { return nodes.find(n => n.tag === 'dialog'); },
        get confirm() { return nodes.find(n => n.tag === 'button' && (n.textContent === 'End session' || n.textContent === 'Continue in session manager')); },
        get cancel() { return nodes.find(n => n.textContent === 'Keep streaming'); } };
}
test('dialog cancels without mutation; matching channel requires confirmation and returns to the manager only after acceptance', t => {
    const f = fixture(t), { port, sent } = f.receive();
    f.button.click(); assert.equal(f.dialog.open, true); assert.deepEqual(f.input, [true]);
    f.cancel.click(); assert.equal(f.dialog.open, false); assert.deepEqual(sent, [{ type: 'ready' }]);
    assert.deepEqual(f.input, [true, false]);
    f.button.click(); f.confirm.click(); f.confirm.click();
    assert.equal(sent.filter(m => m.type === 'end').length, 0);
    port.onmessage({ data: { type: 'available' } });
    assert.equal(sent.filter(m => m.type === 'end').length, 1);
    assert.equal(f.closes, 0); assert.equal(f.cancel.disabled, true);
    let prevented = false; f.dialog.listeners.cancel({ preventDefault() { prevented = true; } }); assert.equal(prevented, true);
    port.onmessage({ data: { type: 'end-result', accepted: true } });
    assert.equal(f.closes, 0); assert.equal(f.ended, 1);
    assert.deepEqual(f.navigations, ['https://manager.test/servers/']);
});
test('rejects wrong origin, protocol, identity and missing source without granting a channel', t => {
    const f = fixture(t);
    for (const overrides of [{ origin: 'https://evil.test' }, { source: null }, { data: { type: 'sw-session-end-channel', version: 1, region: 'r', instanceId: 'i', sessionRequestId: 'new' } }, { data: { type: 'sw-session-end-channel', version: 2, region: 'r', instanceId: 'i', sessionRequestId: 's' } }]) {
        assert.deepEqual(f.receive(overrides).sent, []);
    }
    f.button.click(); assert.equal(f.confirm.disabled, false);
    assert.equal(f.nodes.find(n => n.tag === 'a').style.display, 'block');
    assert.equal(f.closes, 0);
});
test('failed and timed-out ends keep the tab open with manager fallback', t => {
    const f = fixture(t), { port } = f.receive();
    f.button.click(); f.confirm.click();
    port.onmessage({ data: { type: 'available' } });
    port.onmessage({ data: { type: 'end-result', accepted: false } });
    assert.equal(f.closes, 0); assert.equal(f.confirm.disabled, false); assert.equal(f.cancel.disabled, false);
    f.confirm.click();

    assert.equal(f.ended, 0);
    for (const timeout of [...f.timers.values()]) timeout();
    assert.equal(f.closes, 0); assert.equal(f.nodes.find(n => n.tag === 'a').style.display, 'block');
});

test('unresponsive manager never receives an end and a late probe cannot end after timeout', t => {
    const f = fixture(t), { port, sent } = f.receive();
    f.button.click(); f.confirm.click();
    assert.equal(sent.at(-1).type, 'probe');
    for (const timeout of [...f.timers.values()]) timeout();
    port.onmessage({ data: { type: 'available' } });
    assert.equal(sent.filter(m => m.type === 'end').length, 0);
    assert.equal(f.closes, 0);
});


test('isolated or missing manager offers explicit authenticated navigation without ending or closing', t => {
    const f = fixture(t);
    f.button.click();
    assert.equal(f.confirm.disabled, false);
    assert.equal(f.confirm.textContent, 'Continue in session manager');
    assert.deepEqual(f.navigations, []);
    f.cancel.click();
    assert.deepEqual(f.navigations, []);
    f.button.click(); f.confirm.click();
    assert.deepEqual(f.navigations, [buildEndSessionUrl('https://manager.test', { region: 'r', instanceId: 'i', sessionRequestId: 's' })]);
    assert.equal(f.closes, 0);
    assert.equal(f.ended, 0);
});

test('late healthy bridge restores direct confirmation before a request is made', t => {
    const f = fixture(t);
    f.button.click();
    const { port, sent } = f.receive();
    port.onmessage({ data: { type: 'ping' } });
    assert.equal(f.confirm.textContent, 'End session');
    f.confirm.click();
    assert.deepEqual(f.navigations, []);
    assert.equal(sent.at(-1).type, 'probe');
    assert.equal(sent.filter(m => m.type === 'end').length, 0);
});


test('direct end works without any manager port, coalesces clicks, and returns to the manager only after acceptance', async t => {
    let calls = 0, finish;
    const f = fixture(t, { endDirect: () => { calls++; return new Promise(resolve => { finish = resolve; }); } });
    f.button.click();
    assert.equal(f.confirm.textContent, 'End session');
    f.cancel.click(); assert.equal(calls, 0);
    f.button.click(); const completion = f.confirm.click(); f.confirm.click();
    assert.equal(calls, 1); assert.equal(f.closes, 0); assert.equal(f.cancel.disabled, true);
    finish(true); await completion;
    assert.equal(f.closes, 0); assert.equal(f.ended, 1);
    assert.deepEqual(f.navigations, ['https://manager.test/servers/']);
    assert.equal(f.navigations.length, 1);
});
test('failed direct end restores pending state, keeps stream open and offers manual fallback', async t => {
    const pending = [];
    const f = fixture(t, { endDirect: async () => false, onPending: v => pending.push(v) });
    f.button.click(); await f.confirm.click();
    assert.deepEqual(pending, [true, false]);
    assert.equal(f.closes, 0); assert.equal(f.ended, 0); assert.equal(f.cancel.disabled, false);
    assert.equal(f.confirm.textContent, 'Continue in session manager');
    assert.deepEqual(f.navigations, []);
});

test('initial connection hint appears once, expires, and is dismissed when opening the dialog', t => {
    const f = fixture(t);
    const hint = f.nodes.find(n => n.id === 'endSessionHint');
    assert.equal(hint.style.display, undefined);
    f.controller.showInitialHint();
    assert.equal(hint.textContent, 'Click here to end your session');
    assert.equal(hint.style.display, 'block');
    for (const timer of [...f.timers.values()]) timer();
    assert.equal(hint.style.display, 'none');
    f.controller.showInitialHint();
    assert.equal(hint.style.display, 'none');
    f.button.click();
    assert.equal(hint.style.display, 'none');
});
