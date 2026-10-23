const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const dependency = path.resolve(__dirname, '../src/seekableRecording.ts');
const indexed = new Module(dependency, module);
indexed._compile(ts.transpileModule(fs.readFileSync(dependency, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, dependency);
const filename = path.resolve(__dirname, '../src/localRecording.ts');
const loaded = new Module(filename, module);
loaded.filename = filename;
loaded.paths = module.paths;
const originalRequire = loaded.require.bind(loaded);
loaded.require = name => name === './seekableRecording' ? indexed.exports : originalRequire(name);
loaded._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, filename);
const { LocalRecordingController, getRecordingSupport, getRecordingFormat } = loaded.exports;

const tick = () => new Promise(resolve => setImmediate(resolve));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function deferred() {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    return { promise, resolve, reject };
}
class Track extends EventTarget {
    readyState = 'live';
    stops = 0;
    constructor(kind) { super(); this.kind = kind; }
    stop() { this.stops++; this.readyState = 'ended'; }
    end() { this.readyState = 'ended'; this.dispatchEvent(new Event('ended')); }
}
class Recorder {
    state = 'inactive';
    mimeType = 'video/webm;codecs=av01,opus';
    ondataavailable = null;
    onstop = null;
    onerror = null;
    stopCalls = 0;
    finalChunk = null;
    automaticStop = true;
    start(timeslice) { this.timeslice = timeslice; this.state = 'recording'; }
    chunk(text, type = this.mimeType) { this.ondataavailable?.({ data: new Blob([text], { type }) }); }
    stop() {
        this.stopCalls++;
        this.state = 'inactive';
        if (this.automaticStop) queueMicrotask(() => {
            if (this.finalChunk !== null) this.chunk(this.finalChunk);
            this.onstop?.();
        });
    }
}

function fixture(t, overrides = {}) {
    const events = [], states = [], tracks = [new Track('video'), new Track('audio')];
    let source = { connection: {}, videoTrack: tracks[0], audioTrack: tracks[1], codec: 'video/AV1', eligible: true };
    let clock = 1000, pickerCalls = 0;
    const recorder = new Recorder();
    const writer = {
        async write(blob) { events.push(['write', await blob.text()]); },
        async close() { events.push(['close']); },
        async abort() { events.push(['abort']); }
    };
    const file = { name: 'clip.webm', async createWritable() { events.push(['open']); return writer; } };
    const options = {
        createFileWriter: file => file.createWritable(),
        getSource: () => source,
        getSupport: () => ({ supported: true, reason: '' }),
        async pickFile(options) { pickerCalls++; events.push(['choose', options]); return file; },
        createStream(incoming) { events.push(['tracks', incoming]); return { tracks: incoming }; },
        createRecorder(...args) { events.push(['recorder', args]); return recorder; },
        now: () => clock,
        onState(state) { states.push(state); },
        ...overrides
    };
    const controller = new LocalRecordingController(options);
    t.after(() => controller.dispose());
    return {
        controller, options, events, states, recorder, writer, file, tracks,
        get source() { return source; }, set source(value) { source = value; },
        get pickerCalls() { return pickerCalls; }, set clock(value) { clock = value; },
        async start() { await controller.chooseLocation(); await controller.start(); }
    };
}

test('production indexing rejects invalid media without committing or reporting saved', async t => {
    const reports = [];
    const f = fixture(t, { createFileWriter: undefined, createObserver: () => event => reports.push(event) });
    f.writer.seek = async () => {};
    await f.start();
    f.recorder.chunk('not an EBML recording');
    assert.equal(await f.controller.stop(), false);
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.equal(f.events.some(e => e[0] === 'close'), false);
    assert.equal(f.events.some(e => e[0] === 'abort'), true);
    assert.equal(reports.some(e => e.eventType === 'recording_saved'), false);
    assert.equal(reports.at(-1).eventType, 'recording_failed');
    assert.equal(f.tracks.every(track => track.stops === 0), true);
});

test('analytics starts on actual data and reports saved only after close; capture duration excludes disk finalization', async t => {
    const reports = [], closing = deferred();
    let elapsed = 100;
    const f = fixture(t, { elapsedNow: () => elapsed, createObserver: () => event => reports.push(event) });
    await f.controller.chooseLocation();
    assert.equal(reports.length, 0);
    await f.controller.start();
    assert.equal(reports.length, 0);
    elapsed = 1100;
    f.recorder.chunk('first');
    f.recorder.chunk('');
    await tick();
    assert.deepEqual(reports.map(r => r.eventType), ['recording_started']);
    f.recorder.finalChunk = 'last';
    f.writer.close = () => closing.promise;
    elapsed = 2100;
    const stopped = f.controller.stop();
    await tick();
    assert.equal(reports.length, 1);
    elapsed = 60_000;
    closing.resolve();
    assert.equal(await stopped, true);
    assert.deepEqual(reports[1], {
        eventType: 'recording_saved', occurredAtUtc: new Date(1000).toISOString(),
        codec: 'AV1', container: 'webm', bytesWritten: 9, durationMs: 2000
    });
    await f.controller.stop();
    assert.equal(reports.length, 2);
});

test('disconnect with only a final chunk reports both start and successful save', async t => {
    const reports = [];
    const f = fixture(t, { createObserver: () => event => reports.push(event) });
    await f.start();
    f.recorder.finalChunk = 'final';
    f.source = null;
    f.controller.sourceChanged();
    assert.equal(await f.controller.stop(), true);
    assert.deepEqual(reports.map(r => r.eventType), ['recording_started', 'recording_saved']);
    assert.equal(reports[1].bytesWritten, 5);
});

test('analytics never claims a saved clip after file open, write, close, format or empty-data failures', async t => {
    for (const kind of ['open', 'write', 'close', 'format', 'empty']) {
        const reports = [];
        const f = fixture(t, { createObserver: () => event => reports.push(event) });
        if (kind === 'open') f.file.createWritable = async () => { throw Error('private path'); };
        if (kind === 'write') f.writer.write = async () => { throw Error('private path'); };
        if (kind === 'close') f.writer.close = async () => { throw Error('private path'); };
        await f.start();
        if (kind === 'format') f.recorder.mimeType = 'video/webm;codecs=vp8';
        if (kind !== 'empty' && kind !== 'open') f.recorder.chunk('video');
        await tick();
        assert.equal(await f.controller.stop(), false, kind);
        assert.equal(reports.some(r => r.eventType === 'recording_saved'), false, kind);
        assert.equal(reports.filter(r => r.eventType === 'recording_failed').length, 1, kind);
        assert.equal(reports.at(-1).failureCode, {
            open: 'file_open_failed', write: 'write_failed', close: 'file_close_failed',
            format: 'format_mismatch', empty: 'empty_recording'
        }[kind]);
        assert.equal(JSON.stringify(reports).includes('private'), false);
    }
});

test('throwing factories, synchronous observers and rejected/hung observers cannot break or delay a saved file', async t => {
    for (const createObserver of [() => { throw Error('factory'); }, () => () => { throw Error('observer'); },
        () => async () => { throw Error('async'); }, () => () => new Promise(() => {})]) {
        const f = fixture(t, { createObserver });
        await f.start();
        f.recorder.chunk('video');
        assert.equal(await f.controller.stop(), true);
        assert.equal(f.controller.snapshot.phase, 'saved');
    }
    await tick();
});

test('opening cancelled before capture and cancelled picker do not report recording usage', async t => {
    const reports = [], opening = deferred();
    const f = fixture(t, { createObserver: () => event => reports.push(event) });
    f.file.createWritable = () => opening.promise;
    const starting = f.start();
    await tick();
    const stopping = f.controller.stop();
    opening.resolve(f.writer);
    await starting;
    await stopping;
    assert.deepEqual(reports, []);
    f.options.pickFile = async () => { throw { name: 'AbortError' }; };
    await f.controller.chooseLocation();
    await f.controller.start();
    assert.deepEqual(reports, []);
});

test('each clip gets its own observer before asynchronous file access, across codecs', async t => {
    const runs = [];
    const f = fixture(t, { createObserver: () => { const events = []; runs.push(events); return event => events.push(event); } });
    for (const [codec, mime, container] of [['VP9', 'video/webm;codecs=vp9', 'webm'], ['H264', 'video/x-matroska;codecs=avc1', 'matroska']]) {
        f.source = { ...f.source, codec };
        f.recorder.mimeType = mime;
        await f.start();
        f.recorder.chunk('data');
        await f.controller.stop();
        assert.equal(runs.at(-1)[1].codec, codec);
        assert.equal(runs.at(-1)[1].container, container);
    }
    assert.deepEqual(runs.map(r => r.map(e => e.eventType)), [
        ['recording_started', 'recording_saved'], ['recording_started', 'recording_saved']
    ]);
});

test('records original remote tracks, leaves MIME unspecified, and closes only after the final chunk', async t => {
    const f = fixture(t);
    await f.start();
    assert.equal(f.controller.snapshot.phase, 'starting');
    assert.equal(f.controller.hasUnsavedData, true);
    assert.deepEqual(f.events.find(e => e[0] === 'tracks')[1], f.tracks);
    const recorderArgs = f.events.find(e => e[0] === 'recorder')[1];
    assert.equal(recorderArgs.length, 1, 'no MIME type or bitrate options');
    assert.equal(f.recorder.timeslice, 1000);
    assert.equal(f.controller.snapshot.startedAt, null);
    f.clock = 2000;
    f.recorder.chunk('first');
    assert.equal(f.controller.snapshot.phase, 'recording');
    assert.equal(f.controller.snapshot.startedAt, 2000);
    f.recorder.finalChunk = 'last';
    const stop = f.controller.stop();
    assert.equal(f.controller.stop(), stop, 'concurrent stops share completion');
    assert.equal(await stop, true);
    assert.deepEqual(f.events.filter(e => ['write', 'close', 'abort'].includes(e[0])), [
        ['write', 'first'], ['write', 'last'], ['close']
    ]);
    assert.equal(f.recorder.stopCalls, 1);
    assert.equal(f.controller.snapshot.phase, 'saved');
    assert.equal(f.controller.snapshot.bytesWritten, 9);
    assert.equal(f.controller.hasUnsavedData, false);
    assert.ok(f.tracks.every(track => track.stops === 0), 'never stop the streaming tracks');
    await f.controller.start();
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.match(f.controller.snapshot.message, /new recording location/i);
    assert.equal(f.events.filter(e => e[0] === 'open').length, 1, 'do not overwrite an earlier clip without a new picker');
});

test('default MediaRecorder constructor receives only the original-track stream', async t => {
    const original = global.MediaRecorder;
    let args;
    const f = fixture(t, { createRecorder: undefined });
    global.MediaRecorder = function (...incoming) { args = incoming; return f.recorder; };
    t.after(() => { global.MediaRecorder = original; });
    await f.start();
    assert.equal(args.length, 1);
    assert.deepEqual(args[0].tracks, f.tracks);
    f.recorder.finalChunk = 'frame';
    assert.equal(await f.controller.stop(), true);
});

test('serializes writes and waits for disk completion before closing', async t => {
    const f = fixture(t), pending = deferred();
    f.writer.write = async blob => { f.events.push(['write', await blob.text()]); await pending.promise; };
    await f.start();
    f.recorder.chunk('a');
    f.recorder.chunk('b');
    await tick();
    assert.deepEqual(f.events.filter(e => e[0] === 'write'), [['write', 'a']]);
    let done = false;
    const stop = f.controller.stop().then(result => { done = true; return result; });
    await tick();
    assert.equal(done, false);
    assert.equal(f.controller.snapshot.phase, 'saving');
    assert.equal(f.events.some(e => e[0] === 'close'), false);
    pending.resolve();
    assert.equal(await stop, true);
    assert.deepEqual(f.events.filter(e => ['write', 'close'].includes(e[0])), [['write', 'a'], ['write', 'b'], ['close']]);
});

test('stop during file opening cancels without starting a recorder or committing an empty file', async t => {
    const f = fixture(t), opening = deferred();
    f.file.createWritable = () => opening.promise;
    await f.controller.chooseLocation();
    const start = f.controller.start();
    const stop = f.controller.stop();
    assert.equal(f.controller.snapshot.phase, 'saving');
    opening.resolve(f.writer);
    await start;
    assert.equal(await stop, true);
    assert.equal(f.controller.snapshot.phase, 'idle');
    assert.deepEqual(f.events.filter(e => ['recorder', 'close', 'abort'].includes(e[0])), [['abort']]);
});

test('a late file writer is aborted after opening times out and cannot revive the recording', async t => {
    const f = fixture(t, { ioTimeoutMs: 10 }), opening = deferred();
    f.file.createWritable = () => opening.promise;
    await f.controller.chooseLocation();
    await f.controller.start();
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.equal(await f.controller.stop(), false);
    opening.resolve(f.writer);
    await tick();
    assert.deepEqual(f.events.filter(e => ['recorder', 'close', 'abort'].includes(e[0])), [['abort']]);
});

test('canceling the system picker preserves the previous selected location', async t => {
    const f = fixture(t);
    await f.controller.chooseLocation();
    const previous = f.controller.snapshot;
    f.options.pickFile = async () => { throw Object.assign(new Error('cancel'), { name: 'AbortError' }); };
    await f.controller.chooseLocation();
    assert.deepEqual(f.controller.snapshot, previous);
    await f.controller.start();
    f.recorder.finalChunk = 'frame';
    assert.equal(await f.controller.stop(), true);
});

test('canceling an initial picker is not an error and stale picker results are ignored', async t => {
    const picking = deferred();
    const f = fixture(t, { pickFile: () => picking.promise });
    const choose = f.controller.chooseLocation();
    assert.equal(f.controller.snapshot.phase, 'choosing');
    assert.equal(f.controller.hasUnsavedData, false);
    await f.controller.stop();
    picking.resolve(f.file);
    await choose;
    assert.equal(f.controller.snapshot.phase, 'idle');
    assert.equal(f.controller.snapshot.filename, '');
    f.options.pickFile = async () => { throw Object.assign(new Error('cancel'), { name: 'AbortError' }); };
    await f.controller.chooseLocation();
    assert.equal(f.controller.snapshot.phase, 'idle');
});

test('disposing during the picker ignores its result and makes the controller inert', async t => {
    const picking = deferred();
    const f = fixture(t, { pickFile: () => picking.promise });
    const choose = f.controller.chooseLocation();
    await f.controller.dispose();
    picking.resolve(f.file);
    await choose;
    await f.controller.start();
    assert.equal(f.controller.snapshot.filename, '');
    assert.equal(f.events.some(e => e[0] === 'open'), false);
});

test('rejects unavailable, unsupported-codec and disconnected sources before opening a file', async t => {
    const f = fixture(t);
    for (const source of [null, { ...f.source, eligible: false }, { ...f.source, codec: 'video/VP8' }, { ...f.source, videoTrack: { readyState: 'ended' } }]) {
        f.source = source;
        await f.controller.chooseLocation();
        assert.equal(f.controller.snapshot.phase, 'error');
        assert.equal(f.pickerCalls, 0);
    }
    f.options.getSupport = () => ({ supported: false, reason: 'Unavailable browser' });
    await f.controller.chooseLocation();
    assert.equal(f.controller.snapshot.message, 'Unavailable browser');
    assert.equal(f.events.some(e => e[0] === 'open'), false);
});

test('checks eligibility again at Record after selecting a location', async t => {
    const f = fixture(t);
    await f.controller.chooseLocation();
    f.source.eligible = false;
    await f.controller.start();
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.equal(f.events.some(e => e[0] === 'open'), false);
});

test('rejects unexpected output codecs and aborts rather than saving a mislabeled recording', async t => {
    for (const mimeType of ['video/webm;codecs=vp9,opus', 'video/webm', 'video/mp4;codecs=av01']) {
        const f = fixture(t);
        await f.start();
        f.recorder.mimeType = mimeType;
        f.recorder.chunk('frame');
        assert.equal(await f.controller.stop(), false);
        assert.equal(f.controller.snapshot.phase, 'error');
        assert.match(f.controller.snapshot.message, /AV1 WebM/);
        assert.deepEqual(f.events.filter(e => ['write', 'close', 'abort'].includes(e[0])), [['abort']]);
    }
});

test('accepts AV1 profile codec names and uses blob MIME if the recorder omits it', async t => {
    const f = fixture(t);
    await f.start();
    f.recorder.mimeType = '';
    f.recorder.chunk('frame', 'video/webm;codecs="av01.0.04M.08,opus"');
    assert.equal(await f.controller.stop(), true);
    assert.equal(f.controller.snapshot.phase, 'saved');
});

test('writes a video-only session without adding unrelated tracks', async t => {
    const f = fixture(t);
    f.source.audioTrack = undefined;
    await f.start();
    assert.deepEqual(f.events.find(e => e[0] === 'tracks')[1], [f.tracks[0]]);
    f.recorder.finalChunk = 'frame';
    assert.equal(await f.controller.stop(), true);
});

test('stops and aborts on bounded queue overflow instead of growing memory indefinitely', async t => {
    const pending = deferred(), f = fixture(t, { maxPendingBytes: 6 });
    f.writer.write = async () => { await pending.promise; };
    await f.start();
    f.recorder.chunk('1234');
    await tick();
    f.recorder.chunk('5678');
    pending.resolve();
    assert.equal(await f.controller.stop(), false);
    assert.match(f.controller.snapshot.message, /disk could not keep up/);
    assert.deepEqual(f.events.filter(e => ['close', 'abort'].includes(e[0])), [['abort']]);
});

test('write failure stops the recorder, aborts output and never announces Saved', async t => {
    const f = fixture(t);
    f.writer.write = async () => { throw new Error('disk full'); };
    await f.start();
    f.recorder.chunk('frame');
    assert.equal(await f.controller.stop(), false);
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.ok(f.states.every(s => s.phase !== 'saved'));
    assert.deepEqual(f.events.filter(e => ['close', 'abort'].includes(e[0])), [['abort']]);
    assert.ok(f.tracks.every(track => track.stops === 0));
});

test('a failed final close is an error even after every data write succeeded', async t => {
    const f = fixture(t);
    f.writer.close = async () => { f.events.push(['close']); throw new Error('flush failed'); };
    await f.start();
    f.recorder.chunk('frame');
    assert.equal(await f.controller.stop(), false);
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.ok(f.states.every(s => s.phase !== 'saved'));
    assert.deepEqual(f.events.filter(e => ['close', 'abort'].includes(e[0])), [['close'], ['abort']]);
});

test('write timeout and absent browser stop event both finish with honest failure', async t => {
    const f = fixture(t, { ioTimeoutMs: 10 });
    f.writer.write = () => new Promise(() => {});
    await f.start();
    f.recorder.chunk('frame');
    assert.equal(await f.controller.stop(), false);
    assert.match(f.controller.snapshot.message, /Could not write/);
    const missingStop = fixture(t, { ioTimeoutMs: 10 });
    await missingStop.start();
    missingStop.recorder.automaticStop = false;
    missingStop.recorder.chunk('frame');
    assert.equal(await missingStop.controller.stop(), false);
    assert.match(missingStop.controller.snapshot.message, /did not finish/);
});

test('no keyframe/data timeout stops instead of showing a successful empty recording', async t => {
    const f = fixture(t, { startTimeoutMs: 10 });
    await f.start();
    f.recorder.chunk('');
    assert.equal(f.controller.snapshot.phase, 'starting');
    await delay(25);
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.match(f.controller.snapshot.message, /No recording data/);
    assert.equal(f.events.some(e => e[0] === 'close'), false);
});

test('source replacement, disconnect and codec fallback finalize the current clip', async t => {
    for (const change of ['connection', 'videoTrack', 'audioTrack', 'codec', 'eligible', 'disconnect']) {
        const f = fixture(t);
        await f.start();
        f.recorder.chunk('frame');
        f.recorder.finalChunk = 'last';
        f.controller.sourceChanged();
        assert.equal(f.recorder.stopCalls, 0, 'unchanged source keeps recording');
        if (change === 'disconnect') f.source = null;
        else f.source = { ...f.source, [change]: ({ connection: {}, videoTrack: new Track('video'), audioTrack: new Track('audio'), codec: 'video/H264', eligible: false })[change] };
        f.controller.sourceChanged();
        assert.equal(f.recorder.stopCalls, 1, `${change} stops the recorder without a manual Stop`);
        await tick();
        assert.equal(f.controller.snapshot.phase, 'saved');
        assert.deepEqual(f.events.filter(e => ['write', 'close', 'abort'].includes(e[0])), [
            ['write', 'frame'], ['write', 'last'], ['close']
        ], `${change} drains the final chunk and closes the file`);
    }
});

test('ended remote tracks finalize the file without stopping any playback tracks', async t => {
    const f = fixture(t);
    await f.start();
    f.recorder.chunk('frame');
    f.tracks[1].end();
    assert.equal(await f.controller.stop(), true);
    assert.equal(f.recorder.stopCalls, 1);
    assert.ok(f.tracks.every(track => track.stops === 0));
    f.tracks[0].end();
    assert.equal(f.recorder.stopCalls, 1, 'ended listeners are removed at completion');
});

test('disconnection while opening a file cannot start a stale recorder', async t => {
    const pending = deferred(), f = fixture(t);
    f.file.createWritable = () => pending.promise;
    await f.controller.chooseLocation();
    const start = f.controller.start();
    f.source = null;
    f.controller.sourceChanged();
    pending.resolve(f.writer);
    await start;
    assert.equal(f.events.some(e => e[0] === 'recorder'), false);
    assert.deepEqual(f.events.filter(e => e[0] === 'abort'), [['abort']]);
});

test('listener errors do not interrupt data writes or finalization', async t => {
    const f = fixture(t, { onState() { throw new Error('broken toolbar'); } });
    await f.start();
    f.recorder.chunk('frame');
    assert.equal(await f.controller.stop(), true);
    assert.equal(f.controller.snapshot.phase, 'saved');
});

test('support checks secure desktop Chrome/Edge and required APIs', () => {
    const originalWindow = global.window, originalRecorder = global.MediaRecorder;
    const originalNavigator = Object.getOwnPropertyDescriptor(global, 'navigator');
    try {
        global.window = { isSecureContext: true, showSaveFilePicker() {} };
        global.MediaRecorder = Recorder;
        const agent = value => Object.defineProperty(global, 'navigator', { configurable: true, value: { userAgent: value } });
        agent('Mozilla/5.0 Windows Chrome/155.0.0.0 Safari/537.36');
        assert.equal(getRecordingSupport().supported, true);
        agent('Mozilla/5.0 Windows Chrome/155.0.0.0 Safari/537.36 Edg/155.0.0.0');
        assert.equal(getRecordingSupport().supported, true);
        agent('Mozilla/5.0 Windows Chrome/140.0.0.0 Safari/537.36');
        assert.equal(getRecordingSupport().supported, false);
        agent('Mozilla/5.0 Android Chrome/155.0.0.0 Safari/537.36');
        assert.equal(getRecordingSupport().supported, false);
        agent('Mozilla/5.0 Windows Chrome/155.0.0.0 Safari/537.36');
        global.window.isSecureContext = false;
        assert.equal(getRecordingSupport().supported, false);
        global.window.isSecureContext = true;
        global.window.showSaveFilePicker = undefined;
        assert.equal(getRecordingSupport().supported, false);
    } finally {
        global.window = originalWindow;
        global.MediaRecorder = originalRecorder;
        if (originalNavigator) Object.defineProperty(global, 'navigator', originalNavigator);
        else delete global.navigator;
    }
});

test('maps received AV1, VP9 and H264 to matching file containers without a tier condition', async t => {
    for (const [codec, mime, extension] of [
        ['video/AV1', 'video/webm;codecs=av01,opus', '.webm'],
        ['video/VP9', 'video/webm;codecs=vp9,opus', '.webm'],
        ['video/H264', 'video/x-matroska;codecs=avc1.42E01E,opus', '.mkv']
    ]) {
        const f = fixture(t);
        f.source.codec = codec;
        f.recorder.mimeType = mime;
        await f.start();
        const pickerOptions = f.events.find(e => e[0] === 'choose')[1];
        assert.ok(pickerOptions.suggestedName.endsWith(extension));
        assert.deepEqual(pickerOptions.types[0].accept, { [mime.split(';')[0]]: [extension] });
        assert.equal(f.events.find(e => e[0] === 'recorder')[1].length, 1);
        f.recorder.chunk('original encoded video');
        assert.equal(await f.controller.stop(), true);
        assert.equal(f.controller.snapshot.phase, 'saved');
    }
});

test('normalizes RTC and recording codec names without accepting an unrelated codec', () => {
    for (const [name, codec] of [
        ['AV1', 'AV1'], ['video/av1', 'AV1'], ['av01.0.04M.08', 'AV1'],
        ['VP9', 'VP9'], ['video/vp9', 'VP9'], ['vp09.00.10.08', 'VP9'],
        ['H264', 'H264'], ['video/h264', 'H264'], ['avc1.42E01E', 'H264'], ['avc3.42E01E', 'H264']
    ]) assert.equal(getRecordingFormat(name)?.codec, codec);
    for (const name of ['VP8', 'video/H265', 'opus', 'video/AV10', '']) assert.equal(getRecordingFormat(name), null);
});

test('a codec change after the picker requires a new selection and never opens the old file', async t => {
    const f = fixture(t);
    await f.controller.chooseLocation();
    f.source.codec = 'video/H264';
    await f.controller.start();
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.match(f.controller.snapshot.message, /codec changed/);
    assert.equal(f.events.some(e => e[0] === 'open'), false);
    await f.controller.start();
    assert.match(f.controller.snapshot.message, /new recording location/);
    await f.controller.chooseLocation();
    f.recorder.mimeType = 'video/x-matroska;codecs=avc1';
    await f.controller.start();
    f.recorder.finalChunk = 'frame';
    assert.equal(await f.controller.stop(), true);
});

test('rejects changed output video codec or mismatched H264 container without a transcode fallback', async t => {
    for (const [sourceCodec, wrongMime] of [
        ['video/VP9', 'video/webm;codecs=av01,opus'],
        ['video/H264', 'video/webm;codecs=avc1,opus'],
        ['video/H264', 'video/x-matroska;codecs=vp9,opus']
    ]) {
        const f = fixture(t);
        f.source.codec = sourceCodec;
        await f.start();
        f.recorder.mimeType = wrongMime;
        f.recorder.chunk('frame');
        assert.equal(await f.controller.stop(), false);
        assert.equal(f.controller.snapshot.phase, 'error');
        assert.equal(f.events.some(e => e[0] === 'close'), false);
    }
});
