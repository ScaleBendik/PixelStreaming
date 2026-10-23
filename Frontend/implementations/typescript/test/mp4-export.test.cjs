const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const filename = path.resolve(__dirname, '../src/mp4Export.ts');
const loaded = new Module(filename, module);
loaded._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8').replace('import.meta.url', JSON.stringify('file:///test/')), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, filename);
const { Mp4ExportController } = loaded.exports;
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(t) {
    const workers = [], writes = [], states = [];
    const destination = { name: 'clip.mp4' };
    const folder = { name: 'Videos', async getFileHandle(name, options) {
        if (!options?.create) throw Object.assign(new Error(), { name: 'NotFoundError' });
        writes.push(name); return destination;
    } };
    const source = { name: 'clip.webm', async getFile() { return { name: 'clip.webm' }; } };
    const controller = new Mp4ExportController(() => states.push(controller.snapshot), () => {
        const worker = { messages: [], terminated: false, postMessage(data) { this.messages.push(data); }, terminate() { this.terminated = true; } };
        workers.push(worker); return worker;
    });
    t.after(() => controller.dispose());
    return { controller, workers, folder, source, writes, states, destination };
}
test('MP4 remains unsaved until the worker confirms final file close', async t => {
    const f = fixture(t), done = f.controller.start(f.source, f.folder);
    await tick();
    f.workers[0].onmessage({data:{type:'progress',percent:100}});
    assert.equal(f.controller.snapshot.percent, 99);
    assert.equal(f.controller.savedFile, null);
    assert.equal(f.controller.busy, true);
    f.workers[0].onmessage({data:{type:'saved'}});
    await done;
    assert.equal(f.controller.savedFile, f.destination);
    assert.equal(f.controller.snapshot.percent, 100);
    assert.equal(f.workers[0].terminated, true);
});
test('worker failure permits retry and stale success cannot finish the new export', async t => {
    const f = fixture(t);
    const first = f.controller.start(f.source, f.folder); await tick();
    const old = f.workers[0]; old.onerror(); await first;
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.match(f.controller.snapshot.message, /original recording is saved/);
    const next = f.controller.start(f.source, f.folder); await tick();
    old.onmessage({data:{type:'saved'}});
    assert.equal(f.controller.busy, true);
    f.workers[1].onmessage({data:{type:'saved'}}); await next;
});
test('cancel during folder preparation prevents a late worker from starting', async t => {
    const f = fixture(t); let release;
    f.source.getFile = () => new Promise(resolve => { release = resolve; });
    const done = f.controller.start(f.source, f.folder);
    f.controller.cancel(); await done;
    release({}); await tick();
    assert.equal(f.controller.snapshot.phase, 'cancelled');
    assert.equal(f.workers.length, 0);
    assert.deepEqual(f.writes, []);
});
test('worker cancellation ignores further progress and never reports Saved', async t => {
    const f = fixture(t), done = f.controller.start(f.source, f.folder); await tick();
    f.controller.cancel();
    f.workers[0].onmessage({data:{type:'progress',percent:80}});
    assert.equal(f.controller.snapshot.percent, 0);
    assert.equal(f.workers[0].messages.at(-1).type, 'cancel');
    f.workers[0].onmessage({data:{type:'cancelled'}}); await done;
    assert.equal(f.controller.savedFile, null);
});
test('existing MP4 gets a new filename instead of being overwritten', async t => {
    const f = fixture(t);
    f.folder.getFileHandle = async (name, options) => { if (options?.create) f.writes.push(name); return f.destination; };
    const done = f.controller.start(f.source, f.folder); await tick();
    assert.match(f.writes[0], /^clip-.+\.mp4$/);
    f.workers[0].onmessage({data:{type:'saved'}}); await done;
});
test('manual export uses the explicit file without requesting a folder', async t => {
    const f = fixture(t), done = f.controller.start(f.source, f.destination); await tick();
    assert.equal(f.workers[0].messages[0].destination, f.destination);
    assert.deepEqual(f.writes, []);
    f.workers[0].onmessage({data:{type:'saved'}}); await done;
});
test('manual export refuses to replace the original even through another handle', async t => {
    const f = fixture(t);
    f.source.isSameEntry = async () => true;
    await f.controller.start(f.source, f.destination);
    assert.equal(f.controller.snapshot.phase, 'error');
    assert.equal(f.workers.length, 0);
});
