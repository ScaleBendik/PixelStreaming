const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');

function loadControl(Recorder, support) {
    const filename = path.resolve(__dirname, '../src/recordingControl.ts');
    const loaded = new Module(filename, module);
    loaded.filename = filename;
    loaded.paths = module.paths;
    loaded.require = request => request === './localRecording'
        ? { LocalRecordingController: Recorder, getRecordingSupport: () => support, getRecordingFormat: value => {
            const codec = value.toUpperCase().replace(/^VIDEO\//, '').split('.')[0];
            if (['AV1', 'AV01'].includes(codec)) return { codec: 'AV1', extension: '.webm' };
            if (['VP9', 'VP09'].includes(codec)) return { codec: 'VP9', extension: '.webm' };
            if (['H264', 'AVC1', 'AVC3'].includes(codec)) return { codec: 'H264', extension: '.mkv' };
            return null;
        } }
        : module.require(request);
    loaded._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
        compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText, filename);
    return loaded.exports.installRecordingControl;
}

function fixture(t, config = {}) {
    const originalWindow = global.window;
    const originalDocument = global.document;
    const nodes = [], events = new Map(), timers = new Map(), input = [], calls = [];
    let timerId = 0, modalOrder = 0, pointerReleases = 0, recorder;
    let source = { connection: {}, videoTrack: { readyState: 'live' }, codec: 'AV1', eligible: true };
    const support = { supported: true, reason: '', ...config.support };
    const element = tag => {
        const el = {
            tag, children: [], style: {}, attributes: {}, listeners: new Map(), open: false, disabled: false,
            setAttribute(k, v) { this.attributes[k] = v; },
            append(...items) { this.children.push(...items); },
            appendChild(item) { this.children.push(item); },
            addEventListener(name, listener) { this.listeners.set(name, [...(this.listeners.get(name) || []), listener]); },
            fire(name, event = {}) {
                let result;
                for (const listener of this.listeners.get(name) || []) result = listener(event);
                return result;
            },
            showModal() { this.open = true; this.modalOrder = ++modalOrder; },
            close() { this.open = false; this.fire('close'); },
            cancel() {
                let prevented = false;
                this.fire('cancel', { preventDefault() { prevented = true; } });
                if (!prevented) this.close();
            },
            focus() { this.focused = true; },
            remove() { this.removed = true; },
            click() { if (!this.disabled) return this.fire('click', { stopPropagation() {} }); }
        };
        nodes.push(el);
        return el;
    };
    class FakeRecorder {
        snapshot = { phase: 'idle', filename: '', bytesWritten: 0, startedAt: null, message: '' };
        listeners = new Set();
        constructor(options) { this.options = options; recorder = this; }
        get hasUnsavedData() { return ['starting', 'recording', 'saving'].includes(this.snapshot.phase); }
        state(phase, extra = {}) {
            this.snapshot = { ...this.snapshot, phase, message: '', ...extra };
            for (const listener of this.listeners) listener(this.snapshot);
        }
        subscribe(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
        async chooseLocation() {
            calls.push('choose');
            this.state('choosing');
            if (config.choose) return config.choose(this);
            this.state('ready', { filename: '<clip>.webm' });
        }
        async start() {
            calls.push('start');
            if (config.start) return config.start(this);
            this.state('starting', { startedAt: Date.now() });
            this.state('recording', { bytesWritten: 4096 });
        }
        async stop(reason) {
            calls.push(['stop', reason]);
            if (config.stop) return config.stop(this);
            if (!this.hasUnsavedData) return this.snapshot.phase !== 'error';
            this.state('saving');
            this.state('saved');
            return true;
        }
        sourceChanged() { calls.push('sourceChanged'); }
        async dispose() { calls.push('dispose'); }
    }
    global.document = { createElement: element, exitPointerLock() { pointerReleases++; } };
    global.window = {
        addEventListener(name, listener) { events.set(name, listener); },
        removeEventListener(name) { events.delete(name); },
        setInterval(fn) { timers.set(++timerId, fn); return timerId; },
        clearInterval(id) { timers.delete(id); }
    };
    const install = loadControl(FakeRecorder, support);
    const control = install({ controls: element('controls'), modalParent: element('parent'),
        getSource: () => source, setModalInput: open => input.push(open), beforeRecord: config.beforeRecord });
    const byId = id => nodes.find(node => node.id === id);
    t.after(() => { control.dispose(); global.window = originalWindow; global.document = originalDocument; });
    return { control, recorder, nodes, calls, events, input, timers, byId, support, element,
        setSource(value) { source = value; }, get pointerReleases() { return pointerReleases; },
        async begin() {
            byId('recordingBtn').click();
            await byId('recordingChoose').click();
            await byId('recordingStart').click();
        }
    };
}

test('choose, record and stop expose saved status without retaining the input modal during recording', async t => {
    const f = fixture(t);
    assert.equal(f.byId('recordingStart').disabled, true);
    f.byId('recordingBtn').click();
    assert.equal(f.byId('recordingDialog').open, true);
    assert.deepEqual(f.input, [true]);
    assert.equal(f.pointerReleases, 1);
    await f.byId('recordingChoose').click();
    assert.equal(f.byId('recordingFilename').textContent, '<clip>.webm');
    assert.equal(f.byId('recordingFilename').innerHTML, undefined);
    assert.equal(f.byId('recordingStart').disabled, false);
    await f.byId('recordingStart').click();
    assert.equal(f.byId('recordingDialog').open, false);
    assert.deepEqual(f.input, [true, false]);
    assert.match(f.byId('recordingBadge').textContent, /REC 00:00/);
    assert.equal(f.byId('recordingBadge').style.display, 'block');
    assert.match(f.byId('recordingDetails').textContent, /4 KB written/);
    f.byId('recordingBtn').click();
    assert.equal(f.byId('recordingChoose').disabled, true);
    assert.equal(f.byId('recordingStop').disabled, false);
    await f.byId('recordingStop').click();
    assert.equal(f.byId('recordingBadge').textContent, 'Saved');
    assert.equal(f.byId('recordingStart').disabled, true, 'a new file must be selected for another clip');
    assert.equal(f.byId('recordingChoose').disabled, false);
    f.byId('recordingClose').click();
    assert.deepEqual(f.input, [true, false, true, false]);
});

test('unsupported browsers remain usable and explain missing recording capability without opening a file', t => {
    const f = fixture(t, { support: { supported: false, reason: 'Use desktop Chrome or Edge over HTTPS.' } });
    assert.deepEqual(f.calls, []);
    f.byId('recordingBtn').click();
    assert.equal(f.byId('recordingStatus').textContent, 'Use desktop Chrome or Edge over HTTPS.');
    f.byId('recordingChoose').click();
    f.byId('recordingStart').click();
    assert.deepEqual(f.calls, []);
    f.byId('recordingDialog').cancel();
    assert.deepEqual(f.input, [true, false]);
    assert.equal(f.events.has('beforeunload'), false);
});

test('eligibility follows current source, received codec and live track instead of a chosen filename', async t => {
    const f = fixture(t);
    f.byId('recordingBtn').click();
    await f.byId('recordingChoose').click();
    f.setSource({ connection: {}, eligible: false, codec: 'AV1', videoTrack: { readyState: 'live' } });
    f.control.refresh();
    assert.equal(f.byId('recordingStart').disabled, true);
    assert.match(f.byId('recordingStatus').textContent, /not ready/);
    f.setSource({ connection: {}, eligible: true, codec: 'video/VP8', videoTrack: { readyState: 'live' } });
    f.control.refresh();
    assert.match(f.byId('recordingStatus').textContent, /AV1, VP9 or H.264/);
    f.setSource({ connection: {}, eligible: true, codec: 'video/AV1', videoTrack: { readyState: 'ended' } });
    f.control.refresh();
    assert.match(f.byId('recordingStatus').textContent, /Waiting/);
    f.setSource(null);
    f.control.refresh();
    assert.equal(f.byId('recordingChoose').disabled, true);
    assert.match(f.byId('recordingStatus').textContent, /Connect/);
});

test('AV1, VP9 and H.264 streams show their automatic local format without tier controls', t => {
    const f = fixture(t);
    for (const [codec, label] of [
        ['AV1', 'AV1 · WebM (.webm)'], ['video/av01.0.08M.08', 'AV1 · WebM (.webm)'],
        ['VP9', 'VP9 · WebM (.webm)'], ['vp09.00.10.08', 'VP9 · WebM (.webm)'],
        ['H264', 'H.264 · MKV (.mkv)'], ['video/avc1.42E01E', 'H.264 · MKV (.mkv)'],
        ['avc3', 'H.264 · MKV (.mkv)']
    ]) {
        f.setSource({ connection: {}, eligible: true, codec, videoTrack: { readyState: 'live' } });
        f.control.refresh();
        assert.equal(f.byId('recordingChoose').disabled, false, codec);
        assert.equal(f.byId('recordingFormat').textContent, `Format: ${label}`);
    }
});

test('keyboard events stay in the dialog and cancel or disposal restores stream input', t => {
    const f = fixture(t);
    f.byId('recordingBtn').click();
    for (const name of ['keydown', 'keyup', 'keypress', 'pointerdown', 'pointerup', 'click', 'wheel']) {
        let stopped = false;
        f.byId('recordingDialog').fire(name, { stopPropagation() { stopped = true; } });
        assert.equal(stopped, true, name);
    }
    for (const name of ['keydown', 'keyup', 'keypress', 'pointerdown', 'pointerup']) {
        let stopped = false;
        f.byId('recordingBtn').fire(name, { stopPropagation() { stopped = true; } });
        assert.equal(stopped, true, `toolbar ${name}`);
    }
    f.byId('recordingDialog').cancel();
    assert.equal(f.input.at(-1), false);
    f.byId('recordingBtn').click();
    f.control.dispose();
    assert.equal(f.input.at(-1), false);
    assert.equal(f.events.size, 0);
    assert.equal(f.timers.size, 0);
    assert.equal(f.byId('recordingDialog').removed, true);
});

test('saving is visible until the writer completes and unload protection exists only while data is unsaved', async t => {
    let complete;
    const f = fixture(t, { stop: recorder => {
        recorder.state('saving');
        return new Promise(resolve => { complete = () => { recorder.state('saved'); resolve(true); }; });
    } });
    assert.equal(f.events.has('beforeunload'), false);
    await f.begin();
    let prevented = false;
    const event = { preventDefault() { prevented = true; } };
    f.events.get('beforeunload')(event);
    assert.equal(prevented, true);
    assert.equal(event.returnValue, '');
    f.byId('recordingBtn').click();
    const stopped = f.byId('recordingStop').click();
    assert.equal(f.byId('recordingBadge').textContent, 'Saving…');
    assert.equal(f.byId('recordingStop').disabled, true);
    assert.equal(f.events.has('beforeunload'), true);
    complete();
    await stopped;
    assert.equal(f.events.has('beforeunload'), false);
    assert.equal(f.byId('recordingBadge').textContent, 'Saved');
});

test('beforeLeave coalesces finalization and asks before leaving after a save failure', async t => {
    const f = fixture(t, { stop: async recorder => { recorder.state('error', { message: 'Disk is full.' }); return false; } });
    await f.begin();
    const first = f.control.beforeLeave();
    assert.equal(f.control.beforeLeave(), first);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.byId('recordingDialog').open, true);
    assert.equal(f.byId('recordingLeaveWarning').style.display, 'block');
    assert.equal(f.byId('recordingStatus').textContent, 'Disk is full.');
    f.byId('recordingStay').click();
    assert.equal(await first, false);
    assert.equal(f.byId('recordingDialog').open, false);
    assert.equal(f.input.at(-1), false);
    f.byId('recordingBtn').click();
    assert.equal(f.byId('recordingStatus').textContent, 'Disk is full.', 'error can be reopened after staying');
    const second = f.control.beforeLeave();
    await new Promise(resolve => setImmediate(resolve));
    f.byId('recordingLeave').click();
    assert.equal(await second, true);
    assert.equal(f.events.has('beforeunload'), false);
});

test('Escape cancels the failed-save leave decision and successful finalization does not ask', async t => {
    const f = fixture(t, { stop: async recorder => { recorder.state('error'); return false; } });
    const leaving = f.control.beforeLeave();
    await new Promise(resolve => setImmediate(resolve));
    f.byId('recordingDialog').cancel();
    assert.equal(await leaving, false);
    assert.equal(f.input.at(-1), false);
    f.recorder.stop = async () => true;
    assert.equal(await f.control.beforeLeave(), true);
    assert.equal(f.byId('recordingDialog').open, false);
});

test('failed-save confirmation is promoted above an end-session modal without dropping the input lease', async t => {
    const f = fixture(t, { stop: async recorder => { recorder.state('error'); return false; } });
    f.byId('recordingBtn').click();
    const recordingDialog = f.byId('recordingDialog');
    const endDialog = f.element('dialog');
    endDialog.showModal();
    assert.ok(endDialog.modalOrder > recordingDialog.modalOrder);
    const leaving = f.control.beforeLeave();
    await new Promise(resolve => setImmediate(resolve));
    assert.ok(recordingDialog.modalOrder > endDialog.modalOrder);
    assert.equal(recordingDialog.open, true);
    assert.deepEqual(f.input, [true], 'promotion keeps the recording input lease');
    recordingDialog.fire('close'); // A queued close event from the old top-layer position.
    assert.deepEqual(f.input, [true]);
    assert.equal(f.byId('recordingLeaveWarning').style.display, 'block');
    f.byId('recordingStay').click();
    assert.equal(await leaving, false);
    assert.deepEqual(f.input, [true, false]);
});

test('recording startup errors stay visible; picker cancellation does not start recording', async t => {
    const f = fixture(t, { start: async recorder => { recorder.state('error', { message: 'Cannot record this stream.' }); } });
    await f.begin();
    assert.equal(f.byId('recordingDialog').open, true);
    assert.match(f.byId('recordingStatus').textContent, /Cannot record/);
    assert.equal(f.events.has('beforeunload'), false);
    f.recorder.chooseLocation = async () => f.recorder.state('idle', { filename: '' });
    await f.byId('recordingChoose').click();
    assert.equal(f.byId('recordingStart').disabled, true);
    assert.equal(f.byId('recordingFilename').textContent, 'No location selected');
});

test('pagehide only attempts best-effort finalization for an active recording', async t => {
    const f = fixture(t);
    f.events.get('pagehide')();
    assert.equal(f.calls.length, 0);
    await f.begin();
    f.events.get('pagehide')();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.calls.filter(call => Array.isArray(call) && call[0] === 'stop').length, 1);
});

test('Record invokes audio preparation within the gesture and coalesces clicks until playback is ready', async t => {
    let complete, preparations = 0;
    const f = fixture(t, { beforeRecord: () => { preparations++; return new Promise(resolve => { complete = resolve; }); } });
    f.byId('recordingBtn').click();
    await f.byId('recordingChoose').click();
    const started = f.byId('recordingStart').click();
    assert.equal(preparations, 1, 'audio play is invoked synchronously from the click');
    assert.equal(f.byId('recordingStart').disabled, true);
    assert.equal(f.byId('recordingChoose').disabled, true);
    assert.equal(f.byId('recordingClose').disabled, false);
    assert.equal(f.byId('recordingStatus').textContent, 'Preparing recording…');
    f.byId('recordingStart').click();
    assert.equal(preparations, 1);
    assert.equal(f.calls.includes('start'), false);
    complete();
    await started;
    assert.equal(f.calls.filter(call => call === 'start').length, 1);
    assert.equal(f.byId('recordingDialog').open, false);
});

test('failed audio preparation stays visible without starting a recording or blocking navigation', async t => {
    const f = fixture(t, { beforeRecord: async () => { throw new Error('Could not start audio playback.'); } });
    f.byId('recordingBtn').click();
    await f.byId('recordingChoose').click();
    await f.byId('recordingStart').click();
    assert.equal(f.calls.includes('start'), false);
    assert.equal(f.byId('recordingDialog').open, true);
    assert.equal(f.byId('recordingStatus').textContent, 'Could not start audio playback.');
    assert.equal(f.byId('recordingStart').disabled, false);
    assert.equal(f.events.has('beforeunload'), false);
    assert.equal(await f.control.beforeLeave(), true);
});

test('closing the dialog cancels pending preparation and a late playback completion cannot start recording', async t => {
    let complete;
    const f = fixture(t, { beforeRecord: () => new Promise(resolve => { complete = resolve; }) });
    f.byId('recordingBtn').click();
    await f.byId('recordingChoose').click();
    const started = f.byId('recordingStart').click();
    f.byId('recordingClose').click();
    assert.equal(f.input.at(-1), false);
    complete();
    await started;
    assert.equal(f.calls.includes('start'), false);
    assert.equal(f.byId('recordingDialog').open, false);
});

test('navigation cancels pending preparation without waiting for playback or leaking its later rejection', async t => {
    let fail;
    const f = fixture(t, { beforeRecord: () => new Promise((_resolve, reject) => { fail = reject; }) });
    f.byId('recordingBtn').click();
    await f.byId('recordingChoose').click();
    const started = f.byId('recordingStart').click();
    assert.equal(await f.control.beforeLeave(), true);
    fail(new Error('Late audio failure'));
    await started;
    assert.equal(f.calls.includes('start'), false);
    assert.equal(f.byId('recordingStatus').textContent, 'Ready to record.');
});

test('disposing during a pending save never authorizes stale navigation or opens a leave prompt', async t => {
    let complete;
    const f = fixture(t, { stop: () => new Promise(resolve => { complete = resolve; }) });
    await f.begin();
    const leaving = f.control.beforeLeave();
    f.control.dispose();
    complete(true);
    assert.equal(await leaving, false);
    assert.equal(await f.control.beforeLeave(), false);
    assert.equal(f.byId('recordingLeaveWarning').style.display, 'none');
    assert.equal(f.events.has('beforeunload'), false);
});
