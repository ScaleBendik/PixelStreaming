const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const source = ts.transpileModule(fs.readFileSync(require.resolve('../src/player.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function boot({ missingControls = false, installationFails = false, autoConnect = true } = {}) {
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
        './resolutionRecovery': { installResolutionRecovery: () => ({ cancel() {}, dispose() {} }) },
        './runtimeRecovery': { installRuntimeRecovery: () => ({ cancel() {}, dispose() {} }) },
        './endSession': {
            isManagedEndContext: () => true,
            installEndSession(options) {
                if (installationFails) throw new Error('Simulated optional UI failure');
                assert.equal(options.controls, toolbar);
                state.installed++;
                return { dispose() {} };
            }
        }
    };
    const storage = new Map();
    const document = { body: { appendChild() {} } };
    const window = {
        location: new URL('https://stream.test/?ct=test#sm_region=eu-north-1&sm_instance_id=i-test&sm_session_request_id=request-test&sm_session_manager_env=dev'),
        history: { replaceState() {} }, addEventListener() {},
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
