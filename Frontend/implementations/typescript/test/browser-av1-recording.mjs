/**
 * Real Chromium AV1/VP9/H264 recording proof. No hosted services or installed Unreal needed.
 * Run from the repository root:
 *   node Frontend/implementations/typescript/test/browser-av1-recording.mjs
 * Requires Playwright (or PLAYWRIGHT_MODULE_PATH pointing to its package directory).
 * Optional CHROME_EXECUTABLE / EDGE_EXECUTABLE override installed browser paths.
 * Optional RECORDING_BROWSER=chrome|edge and RECORDING_CODEC=AV1|VP9|H264 filter cases.
 * RECORDING_MUTED=1 verifies recording while the playing audio element is muted.
 * Writes evidence under ignored .review-tmp/recording-proof; never edits dependencies.
 * This intentionally is not a *.test.cjs unit test: it launches real browsers.
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..');
const outputDirectory = path.join(repository, '.review-tmp/recording-proof');
assert.ok(!process.env.RECORDING_BROWSER || ['chrome', 'edge'].includes(process.env.RECORDING_BROWSER), 'Unsupported RECORDING_BROWSER');
assert.ok(!process.env.RECORDING_CODEC || ['AV1', 'VP9', 'H264'].includes(process.env.RECORDING_CODEC), 'Unsupported RECORDING_CODEC');
const ts = require('typescript');
const controllerJavascript = ts.transpileModule(await readFile(path.join(repository, 'Frontend/implementations/typescript/src/localRecording.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 }
}).outputText;
const modulePath = process.env.PLAYWRIGHT_MODULE_PATH;
let playwright;
try { playwright = require(modulePath || 'playwright'); }
catch (error) {
    throw new Error('Install/use existing Playwright, or set PLAYWRIGHT_MODULE_PATH to its package directory.', { cause: error });
}

// Minimal, bounded WebM parser. MediaRecorder emits unlaced video blocks; reject
// other encodings instead of accidentally comparing a container header as video.
function readVint(bytes, offset, keepMarker = false) {
    const first = bytes[offset];
    assert.ok(first > 0, `Invalid EBML VINT at ${offset}`);
    let width = 1;
    while (!(first & (0x80 >> (width - 1)))) width++;
    assert.ok(width <= 8 && offset + width <= bytes.length, 'Truncated EBML VINT');
    let value = keepMarker ? first : first & ((1 << (8 - width)) - 1);
    let unknown = !keepMarker && value === ((1 << (8 - width)) - 1);
    for (let index = 1; index < width; index++) {
        value = value * 256 + bytes[offset + index];
        unknown &&= bytes[offset + index] === 255;
    }
    return { value, width, unknown };
}

function children(bytes, start, end) {
    const result = [];
    for (let offset = start; offset < end;) {
        const id = readVint(bytes, offset, true);
        const size = readVint(bytes, offset + id.width);
        const dataStart = offset + id.width + size.width;
        let dataEnd = size.unknown ? end : dataStart + size.value;
        // LiveWebmMuxer may leave Cluster sizes unknown. The next segment-level
        // element terminates that cluster; do not silently lose later frames.
        if (size.unknown && id.value === 0x1f43b675) {
            let childOffset = dataStart;
            while (childOffset < end) {
                const childId = readVint(bytes, childOffset, true);
                if ([0x1f43b675, 0x1c53bb6b, 0x1549a966, 0x1654ae6b].includes(childId.value)) break;
                const childSize = readVint(bytes, childOffset + childId.width);
                assert.equal(childSize.unknown, false, 'Unexpected nested unknown-size WebM element');
                childOffset += childId.width + childSize.width + childSize.value;
            }
            dataEnd = childOffset;
        }
        assert.ok(dataEnd <= end && dataEnd > offset, 'Invalid EBML element length');
        result.push({ id: id.value, start: dataStart, end: dataEnd });
        offset = dataEnd;
    }
    return result;
}

function demuxWebM(bytes, requestedCodec) {
    const segment = children(bytes, 0, bytes.length).find(element => element.id === 0x18538067);
    assert.ok(segment, 'Missing WebM segment');
    const elements = children(bytes, segment.start, segment.end);
    const tracks = elements.find(element => element.id === 0x1654ae6b);
    assert.ok(tracks, 'Missing WebM tracks');
    const uint = element => bytes.subarray(element.start, element.end).reduce((value, byte) => value * 256 + byte, 0);
    const trackInfo = children(bytes, tracks.start, tracks.end).filter(element => element.id === 0xae).map(entry => {
        const fields = children(bytes, entry.start, entry.end);
        const number = uint(fields.find(element => element.id === 0xd7));
        const type = uint(fields.find(element => element.id === 0x83));
        const codec = fields.find(element => element.id === 0x86);
        return { number, type, codec: bytes.subarray(codec.start, codec.end).toString('utf8') };
    });
    const videoTrack = trackInfo.find(track => track.type === 1);
    const expectedCodec = { AV1: 'V_AV1', VP9: 'V_VP9', H264: 'V_MPEG4/ISO/AVC' }[requestedCodec];
    assert.equal(videoTrack?.codec, expectedCodec, 'Recording must preserve video codec');
    const audioTrack = trackInfo.find(track => track.type === 2);
    assert.equal(audioTrack?.codec, 'A_OPUS', 'Recording must include the separate incoming audio track');
    const frames = [];
    let audioBlocks = 0;
    function readBlock(element, keyFrameOverride) {
        const track = readVint(bytes, element.start);
        if (track.value === audioTrack.number) audioBlocks++;
        if (track.value !== videoTrack.number) return;
        const flags = bytes[element.start + track.width + 2];
        assert.equal(flags & 6, 0, 'Laced blocks are not supported by this proof');
        frames.push({
            keyFrame: keyFrameOverride ?? !!(flags & 0x80),
            bytes: bytes.subarray(element.start + track.width + 3, element.end)
        });
    }
    for (const cluster of elements.filter(element => element.id === 0x1f43b675)) {
        for (const element of children(bytes, cluster.start, cluster.end)) {
            if (element.id === 0xa3) readBlock(element);
            if (element.id === 0xa0) {
                const group = children(bytes, element.start, element.end);
                const block = group.find(child => child.id === 0xa1);
                if (block) readBlock(block, !group.some(child => child.id === 0xfb));
            }
        }
    }
    assert.ok(frames.length > 10, 'Expected multiple recorded video frames');
    assert.ok(audioBlocks > 10, 'Expected recorded Opus audio packets');
    assert.equal(frames[0].keyFrame, true, 'Recording must start on a keyframe');
    return { trackInfo, frames, audioBlocks };
}

const server = createServer((request, response) => {
    if (request.url === '/localRecording.js') {
        response.writeHead(200, { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-store' });
        response.end(controllerJavascript);
        return;
    }
    response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
    response.end('<!doctype html><html><body><h1>Local video recording proof</h1></body></html>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const address = `http://127.0.0.1:${server.address().port}`;
const browsers = [
    ['chrome', process.env.CHROME_EXECUTABLE || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe'],
    ['edge', process.env.EDGE_EXECUTABLE || 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe']
];
await mkdir(outputDirectory, { recursive: true });
const browserTemp = path.join(outputDirectory, 'browser-temp');
await mkdir(browserTemp, { recursive: true });
process.env.TEMP = browserTemp;
process.env.TMP = browserTemp;
const evidence = [];
try {
    for (const [name, executablePath] of browsers) {
        if (process.env.RECORDING_BROWSER && process.env.RECORDING_BROWSER !== name) continue;
        const browser = await playwright.chromium.launch({ executablePath, headless: true, args: ['--autoplay-policy=no-user-gesture-required'] });
        try {
            for (const requestedCodec of process.env.RECORDING_CODEC ? [process.env.RECORDING_CODEC] : ['AV1', 'VP9', 'H264']) {
                assert.ok(['AV1', 'VP9', 'H264'].includes(requestedCodec), 'Unsupported RECORDING_CODEC');
                const page = await browser.newPage();
                page.setDefaultTimeout(30000);
                await page.goto(address);
                const mutedAudio = process.env.RECORDING_MUTED === '1';
                const caseName = `${name}-${requestedCodec}${mutedAudio ? '-muted' : ''}`;
                const result = await page.evaluate(async ({ requestedCodec, mutedAudio }) => {
                    const { LocalRecordingController } = await import('/localRecording.js');
                    const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
                    const deadline = (promise, label) => Promise.race([promise, wait(20000).then(() => { throw new Error(`Timed out: ${label}`); })]);
                    if (!globalThis.RTCRtpScriptTransform) throw new Error('RTCRtpScriptTransform unavailable');
                    if (!globalThis.MediaRecorder) throw new Error('MediaRecorder unavailable');
                    const supported = RTCRtpSender.getCapabilities('video').codecs.filter(codec => codec.mimeType.toLowerCase() === `video/${requestedCodec.toLowerCase()}`);
                    if (!supported.length) throw new Error(`No ${requestedCodec} sender capability`);
                    const canvas = document.createElement('canvas');
                    canvas.width = 320; canvas.height = 180;
                    const context = canvas.getContext('2d');
                    let iteration = 0;
                    const draw = () => {
                        iteration++;
                        context.fillStyle = `hsl(${iteration * 9 % 360} 80% 35%)`;
                        context.fillRect(0, 0, canvas.width, canvas.height);
                        context.fillStyle = 'white'; context.font = '24px sans-serif';
                        context.fillText(`${requestedCodec} frame ${iteration}`, 20, 90);
                        context.fillRect(iteration * 7 % 280, 130, 40, 30);
                    };
                    draw();
                    const drawing = setInterval(draw, 1000 / 20);
                    const source = canvas.captureStream(20);
                    const audioContext = new AudioContext();
                    const oscillator = audioContext.createOscillator();
                    const audioDestination = audioContext.createMediaStreamDestination();
                    oscillator.frequency.value = 440;
                    oscillator.connect(audioDestination);
                    oscillator.start();
                    await audioContext.resume();
                    const sender = new RTCPeerConnection();
                    const receiver = new RTCPeerConnection();
                    const received = [];
                    const worker = new Worker(URL.createObjectURL(new Blob([`
                        onrtctransform = event => {
                            const transformer = event.transformer;
                            transformer.readable.pipeThrough(new TransformStream({ transform(frame, controller) {
                                const bytes = frame.data.slice(0);
                                postMessage({ type: frame.type, timestamp: frame.timestamp, bytes }, [bytes]);
                                controller.enqueue(frame);
                            } })).pipeTo(transformer.writable).catch(error => postMessage({ error: String(error) }));
                        };
                    `], { type: 'text/javascript' })));
                    worker.onmessage = event => {
                        if (event.data.error) throw new Error(event.data.error);
                        received.push({ type: event.data.type, timestamp: event.data.timestamp, bytes: Array.from(new Uint8Array(event.data.bytes)) });
                    };
                    let fileHandle;
                    try {
                        const trackResolvers = {};
                        const incoming = new Promise(resolve => { trackResolvers.video = resolve; });
                        const incomingAudio = new Promise(resolve => { trackResolvers.audio = resolve; });
                        receiver.ontrack = event => {
                            if (event.track.kind === 'video') event.receiver.transform = new RTCRtpScriptTransform(worker);
                            trackResolvers[event.track.kind](event.track);
                        };
                        const transceiver = sender.addTransceiver(source.getVideoTracks()[0], { direction: 'sendonly', streams: [source] });
                        transceiver.setCodecPreferences(supported);
                        sender.addTransceiver(audioDestination.stream.getAudioTracks()[0], { direction: 'sendonly', streams: [audioDestination.stream] });
                        await sender.setLocalDescription(await sender.createOffer());
                        const gather = async peer => {
                            if (peer.iceGatheringState === 'complete') return;
                            await deadline(new Promise(resolve => peer.addEventListener('icegatheringstatechange', () => {
                                if (peer.iceGatheringState === 'complete') resolve();
                            })), 'ICE gathering');
                        };
                        await gather(sender);
                        await receiver.setRemoteDescription(sender.localDescription);
                        await receiver.setLocalDescription(await receiver.createAnswer());
                        await gather(receiver);
                        await sender.setRemoteDescription(receiver.localDescription);
                        const videoTrack = await deadline(incoming, 'incoming track');
                        const audioTrack = await deadline(incomingAudio, 'incoming audio track');
                        const preview = document.createElement('video');
                        preview.muted = true; preview.srcObject = new MediaStream([videoTrack]);
                        document.body.appendChild(preview);
                        await deadline(preview.play(), 'incoming playback');
                        const audioPreview = document.createElement('audio');
                        audioPreview.muted = mutedAudio;
                        audioPreview.srcObject = new MediaStream([audioTrack]);
                        document.body.appendChild(audioPreview);
                        await deadline(audioPreview.play(), 'incoming audio playback');
                        await wait(750);
                        const reports = await receiver.getStats();
                        const inbound = [...reports.values()].find(report => report.type === 'inbound-rtp' && report.kind === 'video');
                        const codec = reports.get(inbound.codecId)?.mimeType;
                        if (codec.toLowerCase() !== `video/${requestedCodec.toLowerCase()}`) throw new Error(`Unexpected received codec: ${codec}`);
                        const directory = await navigator.storage.getDirectory();
                        let chunks = 0;
                        let recordingBytes = 0;
                        const states = [];
                        const recorderEvents = [];
                        const controller = new LocalRecordingController({
                            getSource: () => ({ connection: receiver, videoTrack, audioTrack, codec, eligible: true }),
                            onState: state => states.push(state.phase),
                            createRecorder: stream => {
                                const recorder = new MediaRecorder(stream);
                                recorder.addEventListener('dataavailable', event => recorderEvents.push({ bytes: event.data.size, mime: recorder.mimeType }));
                                return recorder;
                            },
                            pickFile: async options => {
                                fileHandle = await directory.getFileHandle(options.suggestedName, { create: true });
                                return { name: fileHandle.name, createWritable: async () => {
                                    const writable = await fileHandle.createWritable();
                                    return {
                                        write: async blob => { await writable.write(blob); chunks++; recordingBytes += blob.size; },
                                        close: () => writable.close(), abort: () => writable.abort()
                                    };
                                } };
                            }
                        });
                        await controller.chooseLocation();
                        if (controller.snapshot.phase !== 'ready') throw new Error(JSON.stringify(controller.snapshot));
                        await controller.start();
                        await wait(4000);
                        if (!await deadline(controller.stop(), 'recording controller stop')) throw new Error(JSON.stringify({ snapshot: controller.snapshot, states, recorderEvents, audioContextState: audioContext.state, audioMuted: audioTrack.muted, stats: [...(await receiver.getStats()).values()].filter(report => report.type === 'inbound-rtp') }));
                        if (controller.snapshot.phase !== 'saved') throw new Error(JSON.stringify(controller.snapshot));
                        const recorded = await fileHandle.getFile();
                        if (recorded.size !== recordingBytes) throw new Error('Disk size differs from written chunks');
                        const playback = document.createElement('video');
                        playback.muted = true;
                        playback.src = URL.createObjectURL(recorded);
                        document.body.appendChild(playback);
                        let durationAtMetadata;
                        let seekableAtMetadata;
                        playback.addEventListener('loadedmetadata', () => {
                            durationAtMetadata = String(playback.duration);
                            seekableAtMetadata = playback.seekable.length;
                        });
                        let decodedFrames = 0;
                        const countFrame = () => { decodedFrames++; playback.requestVideoFrameCallback(countFrame); };
                        playback.requestVideoFrameCallback(countFrame);
                        const ended = new Promise((resolve, reject) => {
                            playback.onended = resolve;
                            playback.onerror = () => reject(new Error(`Saved clip playback failed: ${playback.error?.message}`));
                        });
                        await deadline(playback.play(), 'recorded playback start');
                        await deadline(ended, 'recorded playback end');
                        if (decodedFrames < 10) throw new Error(`Only ${decodedFrames} decoded frames`);
                        const playbackFrameCount = decodedFrames;
                        const durationAfterPlayback = String(playback.duration);
                        const seeked = new Promise(resolve => { playback.onseeked = resolve; });
                        playback.currentTime = 1.25;
                        await deadline(seeked, 'recorded seek after playback');
                        const seekPosition = playback.currentTime;
                        const freshPlayer = document.createElement('video');
                        const freshMetadata = new Promise(resolve => { freshPlayer.onloadedmetadata = resolve; });
                        freshPlayer.src = URL.createObjectURL(recorded);
                        document.body.appendChild(freshPlayer);
                        await deadline(freshMetadata, 'fresh saved clip metadata');
                        const freshSeeked = new Promise(resolve => { freshPlayer.onseeked = () => resolve({ currentTime: freshPlayer.currentTime, duration: String(freshPlayer.duration) }); });
                        freshPlayer.currentTime = 1.25;
                        const freshSeek = await Promise.race([freshSeeked, wait(3000).then(() => ({ error: 'Seek did not complete within 3 seconds' }))]);
                        return {
                            userAgent: navigator.userAgent, codec, mimeType: recorderEvents[0]?.mime, chunks, recordingBytes, decodedFrames: playbackFrameCount, states,
                            durationAtMetadata, seekableAtMetadata, durationAfterPlayback, seekPosition, freshSeek,
                            incomingFrames: received,
                            webm: Array.from(new Uint8Array(await recorded.arrayBuffer())),
                            inputTrackRemainedLive: videoTrack.readyState === 'live' && audioTrack.readyState === 'live'
                        };
                    } finally {
                        clearInterval(drawing); worker.terminate(); sender.close(); receiver.close(); oscillator.stop(); await audioContext.close();
                        audioDestination.stream.getTracks().forEach(track => track.stop());
                        source.getTracks().forEach(track => track.stop());
                    }
                }, { requestedCodec, mutedAudio });
                const bytes = Buffer.from(result.webm);
                const demuxed = demuxWebM(bytes, requestedCodec);
                const hash = data => createHash('sha256').update(data).digest('hex');
                const receivedHashes = result.incomingFrames.map(frame => hash(Buffer.from(frame.bytes)));
                assert.ok(receivedHashes.length > 10, 'Receiver transform must observe actual encoded video');
                let previousIndex = -1;
                const packetHashes = demuxed.frames.map(frame => {
                    const digest = hash(frame.bytes);
                    const index = receivedHashes.indexOf(digest, previousIndex + 1);
                    assert.ok(index >= 0, `Recorded ${requestedCodec} frame ${digest} differs from received encoded frames (possible re-encoding)`);
                    previousIndex = index;
                    return digest;
                });
                assert.equal(result.inputTrackRemainedLive, true, 'Stopping recorder must not stop stream');
                assert.equal(result.seekPosition, 1.25, 'Saved recording must seek after playback');
                assert.equal(result.freshSeek.currentTime, 1.25, 'Saved recording must seek on first open');
                const summary = {
                    browser: name, requestedCodec, mutedAudio, version: browser.version(), executablePath,
                    receivedCodec: result.codec, recordedMimeType: result.mimeType,
                    trackInfo: demuxed.trackInfo, recordedAudioPackets: demuxed.audioBlocks, receivedFrames: receivedHashes.length,
                    matchedRecordedFrames: demuxed.frames.length, firstFrameIsKeyframe: demuxed.frames[0].keyFrame,
                    decodedFrames: result.decodedFrames, writtenChunks: result.chunks,
                    durationAtMetadata: result.durationAtMetadata, seekableAtMetadata: result.seekableAtMetadata,
                    durationAfterPlayback: result.durationAfterPlayback, seekPosition: result.seekPosition, freshSeek: result.freshSeek,
                    fileBytes: bytes.length, inputTrackRemainedLive: result.inputTrackRemainedLive,
                    videoSha256: hash(bytes), packetHashes,
                    controllerStates: result.states,
                    limitations: 'Synthetic local video/Opus sender with separate original audio track; production controller; OPFS disk writer instead of native picker; no Unreal/server acceptance or perceptual A/V sync measurement.'
                };
                await writeFile(path.join(outputDirectory, `${caseName}.${requestedCodec === 'H264' ? 'mkv' : 'webm'}`), bytes);
                await writeFile(path.join(outputDirectory, `${caseName}.json`), JSON.stringify(summary, null, 2));
                evidence.push(summary);
                console.log(JSON.stringify({ ...summary, packetHashes: `${packetHashes.length} exact SHA-256 matches` }, null, 2));
                await page.close();
            }
        } finally { await browser.close(); }
    }
    const summaryName = `summary${process.env.RECORDING_BROWSER ? `-${process.env.RECORDING_BROWSER}` : ''}${process.env.RECORDING_CODEC ? `-${process.env.RECORDING_CODEC}` : ''}${process.env.RECORDING_MUTED === '1' ? '-muted' : ''}.json`;
    await writeFile(path.join(outputDirectory, summaryName), JSON.stringify({ testedAt: new Date().toISOString(), nodeVersion: process.version, evidence }, null, 2));
} finally {
    await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    assert.equal(server.listening, false, 'Test HTTP server must be stopped');
    console.log('Cleanup complete: browser contexts closed and local HTTP server stopped.');
}
