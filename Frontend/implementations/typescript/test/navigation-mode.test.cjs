const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const filename = path.resolve(__dirname, '../src/navigationMode.ts');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const loaded = new Module(filename, module);
loaded.filename = filename;
loaded.paths = module.paths;
loaded.require = (name) => name === '@epicgames-ps/lib-pixelstreamingfrontend-ue5.8'
    ? { Flags: { HoveringMouseMode: 'HoveringMouse' } } : require(name);
loaded._compile(compiled, filename);
const { installNavigationMode } = loaded.exports;

function fixture(t) {
    const flags = new Map([['HoveringMouse', true], ['MouseInput', false], ['KeyboardInput', false]]);
    const writes = [];
    const responses = new Map();
    const events = new Map();
    const stream = {
        config: {
            isFlagEnabled: (key) => flags.get(key),
            setFlagEnabled: (key, value) => { writes.push([key, value]); flags.set(key, value); }
        },
        addResponseEventListener: (name, callback) => responses.set(name, callback),
        removeResponseEventListener: (name) => responses.delete(name),
        addEventListener: (name, callback) => events.set(name, callback),
        removeEventListener: (name) => events.delete(name)
    };
    const control = installNavigationMode(stream);
    t.after(() => control.dispose());
    return { stream, flags, writes, responses, events, control,
        send: (value) => responses.forEach(callback => callback(value)),
        emit: (name) => events.get(name)?.() };
}

test('exact navigation responses select both schemes without enabling suspended inputs', t => {
    const f = fixture(t);
    f.send('Navigation.Free');
    assert.equal(f.flags.get('HoveringMouse'), false);
    f.send('Navigation.Menu');
    assert.equal(f.flags.get('HoveringMouse'), true);
    assert.deepEqual(f.writes, [['HoveringMouse', false], ['HoveringMouse', true]]);
    assert.equal(f.flags.get('MouseInput'), false);
    assert.equal(f.flags.get('KeyboardInput'), false);
});

test('duplicate responses do not rebuild controllers; unrelated payloads are ignored', t => {
    const f = fixture(t);
    for (const message of ['Navigation.Menu', 'navigation.free', ' Navigation.Free',
        'Navigation.Free\n', '"Navigation.Free"', '{"type":"resolutionApplied"}', '', 'x'.repeat(10000)]) {
        f.send(message);
    }
    assert.deepEqual(f.writes, []);
    f.send('Navigation.Free'); f.send('Navigation.Free');
    assert.deepEqual(f.writes, [['HoveringMouse', false]]);
});

test('current navigation wins over late initial settings, but never survives disconnect as authority', t => {
    const f = fixture(t);
    f.emit('initialSettings');
    assert.equal(f.writes.length, 0);
    f.send('Navigation.Free');
    f.flags.set('HoveringMouse', true); // Engine DefaultToHover applied before event.
    f.emit('initialSettings');
    assert.equal(f.flags.get('HoveringMouse'), false);
    f.emit('webRtcDisconnected');
    f.flags.set('HoveringMouse', true);
    f.emit('initialSettings');
    assert.equal(f.flags.get('HoveringMouse'), true);
    f.send('Navigation.Free'); // Current-state replay from Unreal on the new connection.
    assert.equal(f.flags.get('HoveringMouse'), false);
});

test('manual selection remains possible until the next explicit navigation response', t => {
    const f = fixture(t);
    f.send('Navigation.Free');
    f.flags.set('HoveringMouse', true);
    f.send('unrelated');
    assert.equal(f.flags.get('HoveringMouse'), true);
    f.send('Navigation.Free');
    assert.equal(f.flags.get('HoveringMouse'), false);
});

test('disposal removes only owned listeners and queued callbacks cannot mutate settings', t => {
    const f = fixture(t);
    const queued = f.responses.get('scaleWorldNavigationMode');
    let otherResponses = 0;
    f.responses.set('resolutionRecovery', () => otherResponses++);
    f.control.dispose(); f.control.dispose();
    queued('Navigation.Free'); f.send('Navigation.Free');
    assert.equal(f.writes.length, 0);
    assert.equal(f.events.size, 0);
    assert.equal(otherResponses, 1);
});

test('failed settings reads/writes cannot interrupt other responses and later notifications can recover', t => {
    const f = fixture(t);
    let received = 0;
    f.responses.set('other', () => received++);
    const read = f.stream.config.isFlagEnabled;
    const write = f.stream.config.setFlagEnabled;
    f.stream.config.isFlagEnabled = () => { throw new Error('read failure'); };
    assert.doesNotThrow(() => f.send('Navigation.Free'));
    f.stream.config.isFlagEnabled = read;
    f.stream.config.setFlagEnabled = () => { throw new Error('write failure'); };
    assert.doesNotThrow(() => f.send('Navigation.Free'));
    assert.doesNotThrow(() => f.emit('initialSettings'));
    assert.equal(received, 2);
    f.stream.config.setFlagEnabled = write;
    f.send('Navigation.Free');
    assert.equal(f.flags.get('HoveringMouse'), false);
});

test('optional listener registration and cleanup failures never escape to player bootstrap', () => {
    const fail = () => { throw new Error('listener failure'); };
    let control;
    assert.doesNotThrow(() => {
        control = installNavigationMode({ addResponseEventListener: fail, addEventListener: fail,
            removeResponseEventListener: fail, removeEventListener: fail });
    });
    assert.doesNotThrow(() => control.dispose());
});

test('partial installation is disabled even if cleanup also fails', () => {
    let response;
    let writes = 0;
    const fail = () => { throw new Error('event API unavailable'); };
    installNavigationMode({
        config: { isFlagEnabled: () => true, setFlagEnabled: () => writes++ },
        addResponseEventListener: (_name, callback) => { response = callback; },
        addEventListener: fail,
        removeResponseEventListener: fail,
        removeEventListener: fail
    });
    assert.doesNotThrow(() => response('Navigation.Free'));
    assert.equal(writes, 0);
});
