const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const filename = path.resolve(__dirname, '../src/seekableRecording.ts');
const loaded = new Module(filename, module);
loaded._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, filename);
const { SeekableRecordingWriter } = loaded.exports;

const cat = (...parts) => Buffer.concat(parts);
const id = hex => Buffer.from(hex, 'hex');
function size(n) {
    if (n < 127) return Buffer.from([128 | n]);
    return Buffer.from([0x40 | (n >> 8), n & 255]);
}
const el = (hex, payload) => cat(id(hex), size(payload.length), payload);
const u = n => n < 256 ? Buffer.from([n]) : Buffer.from([n >> 8, n & 255]);
const block = (time, key = false, track = 1) => el('a3', cat(Buffer.from([0x80 | track, time >> 8 & 255, time & 255, key ? 128 : 0]), Buffer.from('encoded frame')));
function fixture(known = false, group = false) {
    const ebml = el('1a45dfa3', el('4282', Buffer.from('webm')));
    const info = el('1549a966', el('2ad7b1', Buffer.from([0x0f, 0x42, 0x40])));
    const tracks = el('1654ae6b', el('ae', cat(el('d7', u(1)), el('83', u(1)), el('86', Buffer.from('V_AV1')))));
    const key = group ? el('a0', cat(el('a1', cat(Buffer.from([0x81, 0, 0, 0]), Buffer.from('encoded frame'))), el('9b', u(40)))) : block(0, true);
    const payload = cat(el('e7', u(0)), block(0, false, 2), key, block(40));
    const cluster1 = known ? el('1f43b675', payload) : cat(id('1f43b675'), Buffer.from([255]), payload);
    const cluster2 = el('1f43b675', cat(el('e7', u(1000)), block(0, true), block(40)));
    return cat(ebml, id('18538067'), Buffer.from([1,255,255,255,255,255,255,255]), info, tracks, cluster1, cluster2);
}
function memory() {
    let bytes = Buffer.alloc(0), position = 0, committed = false, aborted = false;
    const sink = {
        async write(blob) {
            const b = Buffer.from(await blob.arrayBuffer());
            if (position + b.length > bytes.length) bytes = cat(bytes, Buffer.alloc(position + b.length - bytes.length));
            b.copy(bytes, position); position += b.length;
        },
        async seek(n) { position = n; },
        async close() { committed = true; },
        async abort() { aborted = true; }
    };
    return { sink, get bytes() { return bytes; }, get committed() { return committed; }, get aborted() { return aborted; } };
}

// Independent test decoder: includes offsets so assertions validate the index
// actually addresses clusters/blocks, rather than just checking tags exist.
function vint(b, p, retain = false) {
    let w = 1;
    while (!(b[p] & 128 >> (w - 1))) w++;
    let n = retain ? b[p] : b[p] & (255 >> w);
    for (let i = 1; i < w; i++) n = n * 256 + b[p + i];
    return { n, w, unknown: !retain && n === 2 ** (7 * w) - 1 };
}
function head(b, p) {
    const i = vint(b, p, true), s = vint(b, p + i.w);
    return { id: i.n, offset: p, start: p + i.w + s.w, end: s.unknown ? b.length : p + i.w + s.w + s.n, unknown: s.unknown };
}
function children(b, start, end) {
    const list = [];
    for (let p = start; p < end;) { const h = head(b, p); list.push(h); p = h.end; }
    return list;
}
const value = (b, h) => b.subarray(h.start, h.end).reduce((a, x) => a * 256 + x, 0);
function verify(bytes) {
    const segment = head(bytes, head(bytes, 0).end);
    assert.equal(segment.unknown, false);
    assert.equal(segment.end, bytes.length);
    const seekHead = head(bytes, segment.start);
    assert.equal(seekHead.id, 0x114d9b74);
    const targets = new Map(children(bytes, seekHead.start, seekHead.end).map(seek => {
        const f = children(bytes, seek.start, seek.end);
        const target = head(bytes, segment.start + value(bytes, f.find(x => x.id === 0x53ac)));
        assert.equal(target.id, value(bytes, f.find(x => x.id === 0x53ab)));
        return [target.id, target];
    }));
    const info = targets.get(0x1549a966);
    const duration = children(bytes, info.start, info.end).find(x => x.id === 0x4489);
    assert.equal(bytes.readDoubleBE(duration.start), 1080);
    const cues = targets.get(0x1c53bb6b);
    const points = children(bytes, cues.start, cues.end);
    assert.equal(points.length, 2);
    assert.deepEqual(points.map(point => {
        const f = children(bytes, point.start, point.end);
        const positions = f.find(x => x.id === 0xb7);
        const pf = children(bytes, positions.start, positions.end);
        assert.equal(value(bytes, pf.find(x => x.id === 0xf7)), 1);
        const cluster = head(bytes, segment.start + value(bytes, pf.find(x => x.id === 0xf1)));
        assert.equal(cluster.id, 0x1f43b675);
        const block = head(bytes, cluster.start + value(bytes, pf.find(x => x.id === 0xf0)));
        assert.ok([0xa3, 0xa0].includes(block.id));
        return value(bytes, f.find(x => x.id === 0xb3));
    }), [0, 1000]);
}

test('indexes unknown/finite clusters and BlockGroups across arbitrary chunk boundaries without changing media', async () => {
    for (const known of [false, true]) for (const group of [false, true]) for (const chunkSize of [1, 7, 41, 10000]) {
        const input = fixture(known, group), m = memory(), writer = new SeekableRecordingWriter(m.sink);
        for (let p = 0; p < input.length; p += chunkSize) await writer.write(new Blob([input.subarray(p, p + chunkSize)]));
        await writer.close();
        assert.equal(m.committed, true);
        assert.equal(writer.bytesWritten, m.bytes.length);
        const firstCluster = input.indexOf(id('1f43b675'));
        assert.equal(m.bytes.indexOf(input.subarray(firstCluster)) >= 0, true, 'All cluster and encoded media bytes are unchanged');
        verify(m.bytes);
    }
});

test('truncated blocks, empty input and invalid EBML cannot be reported as saved', async () => {
    const input = fixture();
    for (const bytes of [input.subarray(0, input.length - 1), Buffer.from('invalid'), Buffer.alloc(0), input.subarray(0, 9)]) {
        const m = memory(), writer = new SeekableRecordingWriter(m.sink);
        await assert.rejects(async () => { await writer.write(new Blob([bytes])); await writer.close(); });
        assert.equal(m.committed, false);
        await writer.abort(); assert.equal(m.aborted, true);
    }
});

test('recording without video keyframes is not committed with an unusable index', async () => {
    const input = fixture();
    const marker = Buffer.from([0x81, 0, 0, 128]);
    for (let p = input.indexOf(marker); p >= 0; p = input.indexOf(marker, p + 4)) input[p + 3] = 0;
    const m = memory(), writer = new SeekableRecordingWriter(m.sink);
    await writer.write(new Blob([input]));
    await assert.rejects(writer.close(), /cannot be indexed/);
    assert.equal(m.committed, false);
});

test('oversized recording metadata fails before buffering its declared payload', async () => {
    const m = memory(), writer = new SeekableRecordingWriter(m.sink);
    // EBML header followed by a Segment whose Info declares 2 MiB of payload.
    const input = cat(el('1a45dfa3', Buffer.alloc(0)), id('18538067ff1549a96610200000'));
    await assert.rejects(writer.write(new Blob([input])), /header/);
    assert.equal(m.committed, false);
});

test('patch/write/close failures propagate without a false saved result', async () => {
    for (const operation of ['seek', 'write', 'close']) {
        const m = memory(), writer = new SeekableRecordingWriter(m.sink);
        await writer.write(new Blob([fixture()]));
        m.sink[operation] = async () => { throw Error('disk failure'); };
        await assert.rejects(writer.close(), /disk failure/);
        assert.equal(m.committed, false);
        await writer.abort(); assert.equal(m.aborted, true);
    }
});

test('abort during a slow metadata patch prevents late commit', async () => {
    const m = memory(), writer = new SeekableRecordingWriter(m.sink);
    await writer.write(new Blob([fixture()]));
    let resume, entered;
    const ready = new Promise(resolve => { entered = resolve; });
    m.sink.seek = () => { entered(); return new Promise(resolve => { resume = resolve; }); };
    const closing = writer.close();
    await ready;
    await writer.abort(); resume();
    await assert.rejects(closing, /closed/);
    assert.equal(m.committed, false);
});
