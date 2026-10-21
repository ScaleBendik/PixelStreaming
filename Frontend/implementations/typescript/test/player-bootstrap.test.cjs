const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const source = ts.transpileModule(fs.readFileSync(require.resolve('../src/player.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function boot({ missingControls = false, installationFails = false, navigationFails = false, recordingFails = false, autoConnect = true, capability, storedCapability, freshTicket = true, beforeLeave = async () => true } = {}) {
    const state = { connections: 0, installed: 0, warnings: [], navigations: [], closes: 0, endedMarks: 0, events: new Map() };
    state.emit = (name, data) => { for (const listener of state.events.get(name) || []) listener({ data }); };
    const ids = new Proxy({}, { get: (_, key) => key });
    const toolbar = {};
    const modules = {
        '@epicgames-ps/lib-pixelstreamingfrontend-ue5.8': {
            Flags: ids, NumericParameters: ids, TextParameters: ids, LogLevel: ids,
            Logger: { InitLogging() {}, Warning(message) { state.warnings.push(message); } },
            Config: class {
                constructor() { this.flags = { AutoConnect: autoConnect }; }
                isFlagEnabled(key) { return this.flags[key] ?? true; }
                setFlagEnabled(key, value) { this.flags[key] = value; state.inputFlags = { ...this.flags }; }
                setNumericSetting() {}
            },
            PixelStreaming: class {
                constructor(config) {
                    this.config = config;
                    this.videoElementParent = {};
                    this.signallingProtocol = { transport: { addListener() {} } };
                }
                setSignallingUrlBuilder() {}
                addEventListener(name, listener) {
                    const listeners = state.events.get(name) || [];
                    listeners.push(listener);
                    state.events.set(name, listeners);
                }
                connect() { state.connections++; }
            },
            SessionQuality: class { report() { return null; } setConnected() {} }
        },
        '@epicgames-ps/lib-pixelstreamingfrontend-ui-ue5.8': {
            Application: class {
                constructor() { this.rootElement = {}; if (!missingControls) this.controls = { rootElement: toolbar }; }
            },
            PixelStreamingApplicationStyle: class { applyStyleSheet() {} }
        },
        './navigationMode': { installNavigationMode: () => {
            if (navigationFails) throw new Error('Simulated navigation failure');
            return { dispose() {} };
        } },
        './resolutionRecovery': { installResolutionRecovery: () => ({ cancel() {}, dispose() {} }) },
        './runtimeRecovery': { installRuntimeRecovery: (_stream, _url, beforeNavigate) => {
            state.beforeRecoveryNavigate = beforeNavigate;
            return { cancel() {}, dispose() {} };
        } },
        './playerRecording': { installPlayerRecording(options) {
            if (recordingFails) throw new Error('Simulated recording initialization failure');
            state.recordingOptions = options;
            return { beforeLeave, dispose() {} };
        } },
        './sessionEndRequest': { requestSessionEnd: async (token, requestId) => { state.directRequest = { token, requestId }; return true; } },
        './endSession': {
            isManagedEndContext: () => true,
            installEndSession(options) {
                if (installationFails) throw new Error('Simulated optional UI failure');
                assert.equal(options.controls, toolbar);
                state.installed++;
                state.endOptions = options;
                return { markEnded() { state.endedMarks++; options.onEnded(); }, dispose() {} };
            }
        }
    };
    const storage = new Map([['sw-connect-ticket:stream.test/', 'test']]);
    if (storedCapability) storage.set('sw-session-end:stream.test/', storedCapability);
    state.storage = storage;
    const document = { body: { appendChild() {} } };
    const window = {
        location: new URL('https://stream.test/' + (freshTicket ? '?ct=test' : '') + '#sm_region=eu-north-1&sm_instance_id=i-test&sm_session_request_id=request-test&sm_session_manager_env=dev' + (capability ? '&sw_end=' + capability : '')),
        history: { replaceState(_a, _b, url) { state.scrubbedUrl = url; } }, addEventListener() {},
        setTimeout() { return 1; }, clearTimeout() {}, close() { state.closes++; },
        sessionStorage: { getItem: k => storage.get(k), setItem: (k,v) => storage.set(k,v), removeItem: k => storage.delete(k) }
    };
    window.location.replace = url => state.navigations.push(['replace', url]);
    window.location.assign = url => state.navigations.push(['assign', url]);
    const exports = {};
    vm.runInNewContext(source, { exports, module: { exports }, document, window, URL, URLSearchParams,
        atob, console, performance, require(name) { assert.ok(modules[name], name); return modules[name]; } });
    document.body.onload();
    assert.ok(window.pixelStreaming, 'bootstrap must finish');
    return state;
}

test('managed owner bootstrap installs the control and connects', () => {
    const state = boot();
    assert.equal(state.installed, 1);
    assert.equal(state.connections, 1);
    assert.deepEqual(state.warnings, []);
});
for (const options of [{ missingControls: true }, { installationFails: true }]) {
    test('optional End session initialization cannot block streaming: ' + JSON.stringify(options), () => {
        const state = boot(options);
        assert.equal(state.connections, 1);
        assert.equal(state.warnings.length, 1);
    });
}
test('manual-connect configuration remains manual after an optional control failure', () => {
    assert.equal(boot({ autoConnect: false, installationFails: true }).connections, 0);
});

test('recording failure cannot prevent streaming or session controls', () => {
    const state = boot({ recordingFails: true });
    assert.equal(state.connections, 1);
    assert.equal(state.installed, 1);
    assert.equal(state.warnings.length, 1);
    assert.equal(boot({ recordingFails: true, autoConnect: false }).connections, 0);
});

test('overlapping recording and end-session dialogs restore inputs after the last dialog closes', () => {
    const state = boot();
    state.recordingOptions.setModalInput(true);
    state.endOptions.setModalInput(true);
    state.recordingOptions.setModalInput(false);
    assert.equal(state.inputFlags.KeyboardInput, false);
    state.endOptions.setModalInput(false);
    assert.equal(state.inputFlags.KeyboardInput, true);
    assert.equal(state.inputFlags.MouseInput, true);
});

test('navigation initialization failure cannot block player connection or optional session controls', () => {
    const state = boot({ navigationFails: true });
    assert.equal(state.connections, 1);
    assert.equal(state.installed, 1);
    assert.equal(state.warnings.length, 1);
    assert.equal(boot({ navigationFails: true, autoConnect: false }).connections, 0);
});


test('end capability is consumed from fragment, scrubbed, and bound to the displayed session', async () => {
    const state = boot({ capability: 'new-capability', storedCapability: 'old-capability' });
    assert.equal(state.connections, 1);
    assert.equal(new URL(state.scrubbedUrl).hash, '');
    assert.equal(new URL(state.scrubbedUrl).search, '');
    assert.equal(state.storage.get('sw-session-end:stream.test/'), 'new-capability');
    await state.endOptions.endDirect();
    assert.deepEqual(state.directRequest, { token: 'new-capability', requestId: 'request-test' });
    state.endOptions.onEnded();
    assert.equal(state.storage.has('sw-session-end:stream.test/'), false);
});
test('reload retains capability but a new connect ticket cannot inherit an old session capability', () => {
    assert.equal(typeof boot({ freshTicket: false, storedCapability: 'saved' }).endOptions.endDirect, 'function');
    const state = boot({ storedCapability: 'old' });
    assert.equal(state.endOptions.endDirect, undefined);
    assert.equal(state.storage.has('sw-session-end:stream.test/'), false);
    assert.equal(state.connections, 1);
});

const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
    let resolve;
    const promise = new Promise(yes => { resolve = yes; });
    return { promise, resolve };
}

test('session-end event supersedes a reconnect redirect waiting for the recording save', async () => {
    const save = deferred();
    const state = boot({ beforeLeave: () => save.promise });
    state.emit('webRtcDisconnected', { eventString: 'Connect ticket expired' });
    assert.deepEqual(state.navigations, []);
    state.emit('webRtcDisconnected', { eventString: 'ScaleWorld session ended' });
    assert.equal(state.endedMarks, 1);
    save.resolve(true);
    await tick();
    assert.deepEqual(state.navigations, [], 'stale ticket-refresh destination cannot replace the ended-session destination');
    state.emit('webRtcDisconnected', { eventString: 'Connect ticket expired' });
    await tick();
    assert.deepEqual(state.navigations, []);
});

test('accepted End session also fences reconnect navigation before a disconnect notification arrives', async () => {
    const save = deferred();
    const state = boot({ beforeLeave: () => save.promise });
    state.emit('webRtcDisconnected', { eventString: 'Connect ticket expired' });
    state.endOptions.onEnded();
    save.resolve(true);
    await tick();
    assert.deepEqual(state.navigations, []);
});

test('fallback tab close supersedes a pending reconnect and can retry when the browser refuses close', async () => {
    const save = deferred();
    const state = boot({ installationFails: true, beforeLeave: () => save.promise });
    state.emit('webRtcDisconnected', { eventString: 'Connect ticket expired' });
    state.emit('webRtcDisconnected', { eventString: 'ScaleWorld session ended' });
    assert.equal(state.closes, 0);
    save.resolve(true);
    await tick();
    assert.deepEqual(state.navigations, []);
    assert.equal(state.closes, 1);
    state.emit('webRtcDisconnected', { eventString: 'ScaleWorld session ended' });
    await tick();
    assert.equal(state.closes, 2, 'a refused close does not leave navigation latched');
});

test('cancelled recording save permits a later reconnect navigation attempt', async () => {
    let allowed = false;
    const state = boot({ beforeLeave: async () => allowed });
    state.emit('webRtcDisconnected', { eventString: 'Connect ticket expired' });
    await tick();
    assert.deepEqual(state.navigations, []);
    allowed = true;
    state.emit('webRtcDisconnected', { eventString: 'Connect ticket expired' });
    await tick();
    assert.equal(state.navigations.length, 1);
    assert.equal(state.navigations[0][0], 'replace');
    assert.match(state.navigations[0][1], /reconnectInstanceId=i-test/);
});

test('a pending recovery-link navigation cannot reconnect after the session ends', async () => {
    const save = deferred();
    const state = boot({ beforeLeave: () => save.promise });
    const recovery = state.beforeRecoveryNavigate();
    state.endOptions.onEnded();
    save.resolve(true);
    assert.equal(await recovery, false);
    assert.equal(await state.endOptions.beforeNavigate(), true, 'terminal navigation can still finish');
});
