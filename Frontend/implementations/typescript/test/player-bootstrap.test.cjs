const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const source = ts.transpileModule(fs.readFileSync(require.resolve('../src/player.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function boot({ missingControls = false, installationFails = false, navigationFails = false, autoConnect = true, capability, storedCapability, freshTicket = true } = {}) {
    const state = { connections: 0, installed: 0, warnings: [] };
    const ids = new Proxy({}, { get: (_, key) => key });
    const toolbar = {};
    const modules = {
        '@epicgames-ps/lib-pixelstreamingfrontend-ue5.8': {
            Flags: ids, NumericParameters: ids, TextParameters: ids, LogLevel: ids,
            Logger: { InitLogging() {}, Warning(message) { state.warnings.push(message); } },
            Config: class {
                constructor() { this.flags = { AutoConnect: autoConnect }; }
                isFlagEnabled(key) { return this.flags[key] ?? true; }
                setFlagEnabled(key, value) { this.flags[key] = value; }
                setNumericSetting() {}
            },
            PixelStreaming: class {
                constructor(config) {
                    this.config = config;
                    this.videoElementParent = {};
                    this.signallingProtocol = { transport: { addListener() {} } };
                }
                setSignallingUrlBuilder() {}
                addEventListener() {}
                connect() { state.connections++; }
            },
            SessionQuality: class {}
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
        './runtimeRecovery': { installRuntimeRecovery: () => ({ cancel() {}, dispose() {} }) },
        './sessionEndRequest': { requestSessionEnd: async (token, requestId) => { state.directRequest = { token, requestId }; return true; } },
        './endSession': {
            isManagedEndContext: () => true,
            installEndSession(options) {
                if (installationFails) throw new Error('Simulated optional UI failure');
                assert.equal(options.controls, toolbar);
                state.installed++;
                state.endOptions = options;
                return { dispose() {} };
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
        sessionStorage: { getItem: k => storage.get(k), setItem: (k,v) => storage.set(k,v), removeItem: k => storage.delete(k) }
    };
    const exports = {};
    vm.runInNewContext(source, { exports, module: { exports }, document, window, URL, URLSearchParams,
        atob, console, require(name) { assert.ok(modules[name], name); return modules[name]; } });
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
