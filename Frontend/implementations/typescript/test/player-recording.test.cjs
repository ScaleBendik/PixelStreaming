const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const source = ts.transpileModule(fs.readFileSync(require.resolve('../src/playerRecording.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function fixture() {
    const events = new Map(), transport = new Map();
    let uiOptions, refreshes = 0, disposed = 0;
    const exports = {};
    vm.runInNewContext(source, { exports, require() { return { installRecordingControl(options) {
        uiOptions = options;
        return { refresh() { refreshes++; }, dispose() { disposed++; }, beforeLeave: async () => false };
    } }; } });
    const peer = () => ({ iceConnectionState: 'connected', listeners: new Map(),
        addEventListener(n, fn) { this.listeners.set(n, fn); }, removeEventListener(n) { this.listeners.delete(n); } });
    const tracks = () => ({ videoTrack: { kind: 'video', readyState: 'live' }, audioTrack: { kind: 'audio', readyState: 'live' } });
    const config = { scaleWorldCodecPolicy: { selectedCodec: 'AV1', availableCodecs: ['AV1'] } };
    const stream = { webRtcController: { peerConnectionController: { peerConnection: peer(), ...tracks() } },
        addEventListener(n, fn) { events.set(n, fn); }, removeEventListener(n) { events.delete(n); },
        signallingProtocol: { transport: { addListener(n, fn) { transport.set(n, fn); }, removeListener(n) { transport.delete(n); } } } };
    const audio = { paused: true, muted: true, volume: 0.3, calls: 0,
        srcObject: { getAudioTracks: () => [stream.webRtcController.peerConnectionController.audioTrack] },
        play() { this.calls++; this.paused = false; return Promise.resolve(); } };
    const video = { ...audio, srcObject: { getAudioTracks: () => [] } };
    stream.webRtcController.streamController = { audioElement: audio };
    stream.webRtcController.videoPlayer = { getVideoElement: () => video };
    const controller = exports.installPlayerRecording({ stream, settingsSection: {}, modalParent: {}, closeSettings() {}, focusStream() {}, setModalInput() {} });
    const stats = (codec = 'AV1', framesDecoded = 3) => events.get('statsReceived')({ data: { aggregatedStats: {
        inboundVideoStats: { codecId: 'video-codec', framesDecoded, bytesReceived: framesDecoded * 100 },
        codecs: new Map([['video-codec', { mimeType: 'video/' + codec }]])
    } } });
    return { stream, config, events, transport, controller, stats, peer, tracks, audio, video,
        beforeRecord: () => uiOptions.beforeRecord(),
        source: () => uiOptions.getSource(), get refreshes() { return refreshes; }, get disposed() { return disposed; } };
}

test('recording requires observed media for the current connection and uses original tracks across tiers', async () => {
    const f = fixture();
    assert.equal(f.source(), null);
    f.stats('AV1', 0); assert.equal(f.source().codec, '');
    f.stats();
    const source = f.source(), pc = f.stream.webRtcController.peerConnectionController;
    assert.equal(source.eligible, true);
    assert.equal(source.codec, 'AV1');
    assert.equal(source.videoTrack, pc.videoTrack);
    assert.equal(source.audioTrack, pc.audioTrack);
    f.config.scaleWorldCodecPolicy = undefined;
    assert.equal(f.source().eligible, true, 'received media needs no separate tier grant');
    f.config.scaleWorldCodecPolicy = { selectedCodec: 'VP9', availableCodecs: ['VP9'] };
    f.stats('VP9'); assert.equal(f.source().eligible, true);
    assert.equal(f.source().codec, 'VP9');
    f.stats('H264'); assert.equal(f.source().eligible, true);
    assert.equal(f.source().codec, 'H264');
    assert.equal(await f.controller.beforeLeave(), false, 'save refusal propagates to navigation');
    f.controller.dispose();
});

test('Record resumes the matching audio sink immediately without changing mute or volume', async () => {
    const f = fixture(); f.stats();
    const pending = f.beforeRecord();
    assert.equal(f.audio.calls, 1, 'play starts inside the user gesture');
    await pending;
    assert.equal(f.audio.muted, true);
    assert.equal(f.audio.volume, 0.3);
    await f.beforeRecord();
    assert.equal(f.audio.calls, 1, 'already playing audio is left alone');
    assert.equal(f.video.calls, 0);
    f.controller.dispose();
});

test('Record uses the video element when incoming audio and video share its stream', async () => {
    const f = fixture(); f.stats();
    f.video.srcObject = f.audio.srcObject;
    f.audio.srcObject = null;
    await f.beforeRecord();
    assert.equal(f.video.calls, 1);
    assert.equal(f.audio.calls, 0);
    assert.equal(f.video.muted, true);
    f.controller.dispose();
});

test('audio preparation propagates playback failure and skips video-only media', async () => {
    const f = fixture(); f.stats();
    f.audio.play = () => Promise.reject(new Error('NotAllowedError'));
    await assert.rejects(f.beforeRecord(), /Could not start session audio/);
    f.audio.srcObject = null;
    await assert.rejects(f.beforeRecord(), /Audio is not ready/);
    f.stream.webRtcController.peerConnectionController.audioTrack = undefined;
    await f.beforeRecord();
    f.controller.dispose();
});

test('reconnect never inherits codec proof or old tracks and disconnect refreshes the recorder', () => {
    const f = fixture(); f.stats();
    const old = f.source().connection;
    f.stream.webRtcController.peerConnectionController = { peerConnection: f.peer(), ...f.tracks() };
    assert.equal(f.source(), null, 'replacement requires its own media observation');
    f.events.get('webRtcConnecting')();
    assert.equal(old.listeners.size, 0);
    f.events.get('webRtcConnected')(); f.stats();
    assert.notEqual(f.source().connection, old);
    const peer = f.source().connection;
    peer.iceConnectionState = 'disconnected';
    const before = f.refreshes;
    peer.listeners.get('iceconnectionstatechange')();
    assert.equal(f.refreshes, before + 1);
    assert.equal(f.source(), null);
    peer.iceConnectionState = 'connected';
    const beforeDisconnect = f.refreshes;
    f.events.get('webRtcDisconnected')(); assert.equal(f.source(), null);
    assert.equal(f.refreshes, beforeDisconnect + 1, 'disconnect notifies the recorder immediately');
    f.events.get('webRtcConnected')(); assert.equal(f.source(), null);
    f.stats(); assert.ok(f.source());
    const beforeFailure = f.refreshes;
    f.events.get('webRtcFailed')(); assert.equal(f.source(), null);
    assert.equal(f.refreshes, beforeFailure + 1, 'failed connections also notify the recorder');
    f.events.get('webRtcConnected')(); f.stats();
    f.transport.get('open')(); assert.equal(f.source(), null, 'new signalling generation clears prior proof');
    f.controller.dispose();
    assert.equal(peer.listeners.size, 0);
    assert.equal(f.events.size, 0);
    assert.equal(f.transport.size, 0);
    assert.equal(f.disposed, 1);
});
