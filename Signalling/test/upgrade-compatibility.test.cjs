// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');
const { Logger: CommonLogger } = require('@epicgames-ps/lib-pixelstreamingcommon-ue5.8');
const { Logger } = require('../dist/cjs/Logger.js');
CommonLogger.InitLogging(0, false);
Logger.silent = true;
const WebSocket = require('ws');
const { SignallingServer } = require('../dist/cjs/SignallingServer.js');
const { StreamerRegistry } = require('../dist/cjs/StreamerRegistry.js');
const { PlayerRegistry } = require('../dist/cjs/PlayerRegistry.js');
const { IceCandidateMonitor } = require('../dist/cjs/IceCandidateMonitor.js');

const shared = { iceServers: [{ urls: ['stun:shared.example.test'] }] };
const playerOptions = { iceTransportPolicy: 'relay', iceServers: [{ urls: ['turn:player.example.test'] }] };
const streamerOptions = { iceServers: [{ urls: ['turn:streamer.example.test'] }] };

// Exercise real protocol/connection/registry objects, with no network or listening socket.
class Socket extends WebSocket {
    constructor() {
        super(null, undefined, { autoPong: true });
        this._readyState = WebSocket.OPEN;
        this.messages = [];
        this.pings = 0;
        this.terminations = 0;
    }
    send(message) { this.messages.push(JSON.parse(message)); }
    ping() { this.pings++; }
    close() {
        if (this._readyState === WebSocket.CLOSED) return;
        this._readyState = WebSocket.CLOSED;
        this.emit('close', 1000, Buffer.alloc(0));
    }
    terminate() { this.terminations++; this.close(); }
    receive(message) { this.emit('message', Buffer.from(JSON.stringify(message)), false); }
}

function serverWith(overrides = {}) {
    const server = Object.create(SignallingServer.prototype);
    server.config = { streamerPort: 0, peerOptions: shared, ...overrides };
    server.protocolConfig = { peerConnectionOptions: shared };
    server.protocolConfigPlayer = { peerConnectionOptions: playerOptions };
    server.protocolConfigStreamer = { peerConnectionOptions: streamerOptions };
    server.streamerRegistry = new StreamerRegistry(overrides.authorizeStreamerId);
    server.playerRegistry = new PlayerRegistry();
    server.codecJournalReady = () => true;
    server.codecEvidenceRecorder = () => {};
    server.playerKeepaliveEnabled = true;
    server.playerKeepaliveMaxMissedPongs = 2;
    server.playerKeepaliveState = new Map();
    server.iceCandidateMonitor = new IceCandidateMonitor({ enabled: false });
    return server;
}

function request(identity) {
    return {
        socket: { remoteAddress: '127.0.0.1' },
        url: '/?ct=private-ticket&sm_session_request_id=untrusted-query&sm_session_id=untrusted-session',
        ...(identity ? {
            scaleWorldConnectTicketIdentityValidated: true,
            scaleWorldValidatedConnectTicketIdentity: { ...identity, codecPolicy: identity.codecPolicy ?? { version: 1, snapshotId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', policyHash: 'A'.repeat(64), allowedCodecs: ['VP9'], defaultCodec: 'VP9', allowSwitching: false } }
        } : {})
    };
}

test('governed codec switch replaces only media, preserves viewer identity and records decoded codec', () => {
    const server = serverWith(); const events = []; let removed = 0;
    server.codecEvidenceRecorder = event => events.push(event);
    server.playerRegistry.on('removed', () => removed++);
    const streamer = new Socket(); const viewer = new Socket();
    server.onStreamerConnected(streamer, request());
    streamer.receive({ type: 'endpointId', id: 'test-streamer' });
    const policy = { version: 1, snapshotId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', policyHash: 'A'.repeat(64), allowedCodecs: ['VP9', 'H264'], defaultCodec: 'VP9', allowSwitching: true };
    server.onPlayerConnected(viewer, request({ sessionRequestId: 'signed-request', activeSessionId: 'signed-session', codecPolicy: policy }));
    const player = server.playerRegistry.listPlayers()[0]; const playerId = player.playerId;
    viewer.receive({ type: 'subscribe', streamerId: 'test-streamer' });
    const sdp = ['v=0', 'm=video 9 UDP/TLS/RTP/SAVPF 96 98', 'a=rtpmap:96 H264/90000', 'a=rtpmap:98 VP9/90000', ''].join('\r\n');
    const firstMediaId = player.streamerPlayerId;
    streamer.receive({ type: 'offer', playerId: firstMediaId, sdp });
    assert.doesNotMatch(viewer.messages.at(-1).sdp, /H264/);
    const before = streamer.messages.length;
    viewer.receive({ type: 'scaleWorldCodecSwitch', codec: 'AV1', mediaGeneration: 0 });
    assert.equal(streamer.messages.length, before);
    viewer.receive({ type: 'scaleWorldCodecSwitch', codec: 'H264', mediaGeneration: 0 });
    assert.deepEqual(streamer.messages.slice(before).map(m => m.type), ['playerDisconnected', 'playerConnected']);
    assert.equal(streamer.messages[before].playerId, firstMediaId);
    assert.equal(streamer.messages[before + 1].playerId, player.streamerPlayerId);
    assert.notEqual(player.streamerPlayerId, firstMediaId);
    assert.equal(removed, 0); assert.equal(server.playerRegistry.count(), 1); assert.equal(player.playerId, playerId);
    assert.equal(player.scaleWorldSessionId, 'signed-session'); assert.equal(player.scaleWorldSessionRequestId, 'signed-request');
    const delivered = viewer.messages.length;
    for (const staleId of [firstMediaId, playerId]) {
        for (const type of ['offer', 'answer', 'iceCandidate', 'disconnectPlayer'])
            streamer.receive({ type, playerId: staleId, sdp, candidate: {}, reason: 'retired media peer' });
    }
    assert.equal(viewer.messages.length, delivered);
    assert.equal(viewer.readyState, WebSocket.OPEN);
    streamer.receive({ type: 'offer', playerId: player.streamerPlayerId, sdp });
    assert.equal(viewer.messages.at(-1).playerId, playerId, 'browser keeps its logical player identity');
    assert.doesNotMatch(viewer.messages.at(-1).sdp, /VP9/);
    viewer.receive({ type: 'scaleWorldCodecObservation', codec: 'H264', mediaGeneration: 1, framesDecoded: 100, bytesReceived: 999999 });
    assert.equal(events.filter(e => e.eventType === 'observed').length, 0, 'an offer alone cannot confirm decoded media');
    viewer.receive({ type: 'answer', sdp: viewer.messages.at(-1).sdp, mediaGeneration: 1 });
    viewer.receive({ type: 'scaleWorldCodecObservation', codec: 'H264', mediaGeneration: 0, framesDecoded: 100, bytesReceived: 999999 });
    assert.equal(events.filter(e => e.eventType === 'observed').length, 0);
    viewer.receive({ type: 'scaleWorldCodecObservation', codec: 'H264', mediaGeneration: 1, framesDecoded: 100, bytesReceived: 999999 });
    assert.equal(events.at(-1).eventType, 'switch_succeeded');
    assert.equal(events.find(e => e.eventType === 'observed').evidenceSource, 'browser');
    assert.equal(new Set(events.map(e => e.connectionId)).size, 1);
    assert.deepEqual(events.map(e => e.sequence), events.map((_, i) => i + 1));
    // No mutation is allowed when pre-switch durable persistence fails.
    const count = streamer.messages.length;
    server.codecEvidenceRecorder = () => { throw new Error('disk full'); };
    viewer.receive({ type: 'scaleWorldCodecSwitch', codec: 'VP9', mediaGeneration: 1 });
    assert.equal(streamer.messages.length, count); assert.equal(player.selectedCodec, 'H264');
    server.codecEvidenceRecorder = event => events.push(event);
    streamer.receive({ type: 'disconnectPlayer', playerId: player.streamerPlayerId, reason: 'current peer closed' });
    assert.equal(viewer.readyState, WebSocket.CLOSED, 'current peer disconnect remains authoritative');
    viewer.close(); streamer.close();
});

test('managed same-stream retry resets counters and fences stale answers and media observations', () => {
    const server = serverWith(); const events = []; server.codecEvidenceRecorder = e => events.push(e);
    const streamer = new Socket(); const viewer = new Socket(); server.onStreamerConnected(streamer, request());
    streamer.receive({ type: 'endpointId', id: 'test-streamer' });
    server.onPlayerConnected(viewer, request({ sessionRequestId: 'signed-request' }));
    const player = server.playerRegistry.listPlayers()[0];
    const sdp = 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 98\r\na=rtpmap:98 VP9/90000\r\n';
    const negotiate = generation => {
        streamer.receive({ type: 'offer', playerId: player.streamerPlayerId, sdp });
        viewer.receive({ type: 'answer', sdp, mediaGeneration: generation });
    };
    viewer.receive({ type: 'subscribe', streamerId: 'test-streamer' }); negotiate(0);
    viewer.receive({ type: 'scaleWorldCodecObservation', codec: 'VP9', mediaGeneration: 0, framesDecoded: 1000, bytesReceived: 999999 });
    viewer.receive({ type: 'subscribe', streamerId: 'test-streamer' });
    assert.equal(player.codecGeneration, 1);
    assert.equal(viewer.messages.at(-1).status, 'restarting');
    assert.equal(server.playerRegistry.count(), 1);
    const before = streamer.messages.length;
    viewer.receive({ type: 'answer', sdp, mediaGeneration: 0 });
    viewer.receive({ type: 'iceCandidate', candidate: {}, mediaGeneration: 0 });
    viewer.receive({ type: 'scaleWorldCodecObservation', codec: 'VP9', mediaGeneration: 0, framesDecoded: 2000, bytesReceived: 1999999 });
    assert.equal(streamer.messages.length, before);
    negotiate(1);
    viewer.receive({ type: 'scaleWorldCodecObservation', codec: 'VP9', mediaGeneration: 1, framesDecoded: 10, bytesReceived: 10000 });
    assert.deepEqual(events.filter(e => e.eventType === 'observed').map(e => e.mediaGeneration), [0, 1]);
    viewer.receive({ type: 'unsubscribe' });
    const stopped = streamer.messages.length;
    viewer.receive({ type: 'iceCandidate', candidate: {}, mediaGeneration: 1 });
    viewer.receive({ type: 'offer', sdp, mediaGeneration: 1 });
    assert.equal(streamer.messages.length, stopped, 'late signalling cannot revive paused media');
    viewer.close(); streamer.close();
});

test('browser-first offers publish governed choices and require the opposite peer to answer', () => {
    for (const wrongPeer of [false, true]) {
        const server = serverWith(); const events = []; server.codecEvidenceRecorder = e => events.push(e);
        const streamer = new Socket(); const viewer = new Socket(); server.onStreamerConnected(streamer, request());
        streamer.receive({ type: 'endpointId', id: 'test-streamer' });
        server.onPlayerConnected(viewer, request({ sessionRequestId: 'signed-request', codecPolicy: {
            version: 1, snapshotId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', policyHash: 'A'.repeat(64), allowedCodecs: ['VP9', 'H264'], defaultCodec: 'VP9', allowSwitching: true
        } }));
        const player = server.playerRegistry.listPlayers()[0];
        viewer.receive({ type: 'offer', mediaGeneration: 0, sdp: 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 98\r\na=rtpmap:96 H264/90000\r\na=rtpmap:98 VP9/90000\r\n' });
        assert.deepEqual(viewer.messages.at(-1).availableCodecs, ['VP9', 'H264']);
        const answer = { type: 'answer', playerId: player.streamerPlayerId, sdp: streamer.messages.at(-1).sdp, mediaGeneration: 0 };
        assert.doesNotMatch(answer.sdp, /H264/);
        (wrongPeer ? viewer : streamer).receive(answer);
        assert.equal(events.some(e => e.eventType === 'negotiated'), !wrongPeer);
        assert.equal(player.subscribedStreamer !== null, !wrongPeer);
        viewer.close(); streamer.close();
    }
});

test('an answer cannot reintroduce a codec removed from the offer', () => {
    const server = serverWith(); const streamer = new Socket(); const viewer = new Socket();
    server.onStreamerConnected(streamer, request()); streamer.receive({ type: 'endpointId', id: 'test-streamer' });
    server.onPlayerConnected(viewer, request({ sessionRequestId: 'signed-request' }));
    const player = server.playerRegistry.listPlayers()[0];
    viewer.receive({ type: 'subscribe', streamerId: 'test-streamer' });
    const sdp = 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 98\r\na=rtpmap:96 H264/90000\r\na=rtpmap:98 VP9/90000\r\n';
    streamer.receive({ type: 'offer', playerId: player.streamerPlayerId, sdp });
    viewer.receive({ type: 'answer', mediaGeneration: 0, sdp });
    assert.equal(player.subscribedStreamer, null);
    assert.equal(streamer.messages.filter(m => m.type === 'answer').length, 0);
    viewer.close(); streamer.close();
});

test('codec switch timeout restores the previous permitted codec once without removing the viewer', context => {
    const timers = []; context.mock.method(global, 'setTimeout', fn => { timers.push(fn); return { unref() {} }; });
    const server = serverWith(); const events = []; server.codecEvidenceRecorder = e => events.push(e);
    const streamer = new Socket(); const viewer = new Socket(); server.onStreamerConnected(streamer, request());
    streamer.receive({ type: 'endpointId', id: 'test-streamer' });
    server.onPlayerConnected(viewer, request({ sessionRequestId: 'signed-request', codecPolicy: {
        version: 1, snapshotId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', policyHash: 'A'.repeat(64), allowedCodecs: ['VP9', 'AV1'], defaultCodec: 'VP9', allowSwitching: true } }));
    const player = server.playerRegistry.listPlayers()[0];
    viewer.receive({ type: 'subscribe', streamerId: 'test-streamer' });
    streamer.receive({ type: 'offer', playerId: player.streamerPlayerId, sdp: 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 98\r\na=rtpmap:96 AV1/90000\r\na=rtpmap:98 VP9/90000\r\n' });
    viewer.receive({ type: 'scaleWorldCodecSwitch', codec: 'AV1', mediaGeneration: 0 });
    timers.at(-1)(); assert.equal(player.selectedCodec, 'VP9'); assert.equal(player.codecGeneration, 2);
    timers[0](); assert.notEqual(player.subscribedStreamer, null, 'the superseded timeout must not terminate rollback');
    timers.at(-1)(); assert.equal(player.codecGeneration, 2); assert.equal(player.subscribedStreamer, null);
    assert.equal(server.playerRegistry.count(), 1); assert.equal(viewer.readyState, WebSocket.OPEN);
    assert.ok(events.some(e => e.eventType === 'switch_failed'));
    viewer.close(); streamer.close();
});

for (const mode of ['static', 'provider', 'provider-failure']) {
    test('streamer config precedes identify exactly once with role options: ' + mode, () => {
        const seen = [];
        const dynamic = { iceServers: [{ urls: ['turn:dynamic.example.test'], username: 'per-peer' }] };
        const server = serverWith(mode === 'static' ? {} : { peerOptionsProvider(peer) {
            seen.push(peer);
            if (mode === 'provider-failure') throw new Error('unavailable');
            return dynamic;
        } });
        const first = new Socket();
        const second = new Socket();
        server.onStreamerConnected(first, request());
        server.onStreamerConnected(second, request());
        for (const socket of [first, second]) {
            assert.deepEqual(socket.messages.map(message => message.type), ['config', 'identify']);
            assert.deepEqual(socket.messages[0].peerConnectionOptions, mode === 'provider' ? dynamic : streamerOptions);
        }
        if (mode !== 'static') {
            assert.deepEqual(seen, [
                { peerType: 'streamer', peerId: 'UnknownStreamer' },
                { peerType: 'streamer', peerId: 'UnknownStreamer1' }
            ]);
        }
        first.close(); second.close();
        assert.equal(server.streamerRegistry.streamers.length, 0);
    });
}

test('player and SFU retain separate static options, including provider failure fallback', () => {
    const server = serverWith({ peerOptionsProvider() { throw new Error('unavailable'); } });
    const player = new Socket();
    const sfu = new Socket();
    server.onPlayerConnected(player, request());
    server.onSFUConnected(sfu, request());
    assert.deepEqual(player.messages.filter(message => message.type === 'config').map(message => message.peerConnectionOptions), [playerOptions]);
    assert.deepEqual(sfu.messages.filter(message => message.type === 'config').map(message => message.peerConnectionOptions), [shared]);
    player.close(); sfu.close();
});

test('validated ticket identity survives request propagation and untrusted query media is rejected', () => {
    const server = serverWith();
    const evidence = [];
    server.playerRegistry.on('scaleWorldMediaReceived', (...args) => evidence.push(args));
    const managed = new Socket();
    const unsigned = new Socket();
    const managedRequest = request({ sessionRequestId: 'signed-request', activeSessionId: 'signed-session' });
    server.onPlayerConnected(managed, managedRequest);
    server.onPlayerConnected(unsigned, request());
    const [trustedPlayer, untrustedPlayer] = server.playerRegistry.listPlayers();
    assert.equal(trustedPlayer.request, managedRequest);
    assert.equal(trustedPlayer.scaleWorldSessionRequestId, 'signed-request');
    assert.equal(trustedPlayer.scaleWorldSessionId, 'signed-session');
    assert.equal(trustedPlayer.scaleWorldSessionIdentityValidated, true);
    assert.equal(trustedPlayer.scaleWorldActiveSessionIdValidated, true);
    assert.equal(untrustedPlayer.scaleWorldSessionIdentityValidated, false);
    const message = { type: 'scaleWorldMediaReceived', telemetryVersion: 1, proofType: 'video_frame_callback', mediaPresentationGuardVersion: 2, videoWidth: 2560, extraSecret: 'discarded' };
    unsigned.receive(message);
    managed.receive(message);
    managed.receive(message);
    assert.equal(evidence.length, 1);
    assert.equal(evidence[0][0], trustedPlayer.playerId);
    assert.equal(evidence[0][1].videoWidth, 2560);
    assert.equal('extraSecret' in evidence[0][1], false);
    managed.close(); unsigned.close();
});

test('websocket watchdog keeps existing default behavior without enabling protocol keepalive', (context) => {
    const timers = [];
    context.mock.method(global, 'setInterval', (callback, delay) => { timers.push({ callback, delay }); return {}; });
    const server = serverWith();
    const player = new Socket();
    server.onPlayerConnected(player, request());
    assert.equal(timers.length, 0);
    server.runPlayerKeepaliveTick();
    assert.equal(player.pings, 1);
    player.emit('pong');
    server.runPlayerKeepaliveTick();
    server.runPlayerKeepaliveTick();
    assert.equal(player.terminations, 0);
    server.runPlayerKeepaliveTick();
    assert.equal(player.terminations, 1);
    assert.equal(server.playerRegistry.count(), 0);
    assert.equal(server.playerKeepaliveState.size, 0);
});

test('explicit protocol keepalive timeout remains supported and stops on disconnect', (context) => {
    const timers = [];
    const cleared = [];
    context.mock.method(global, 'setInterval', (callback, delay) => { const timer = { callback, delay }; timers.push(timer); return timer; });
    context.mock.method(global, 'clearInterval', timer => cleared.push(timer));
    const server = serverWith({ playerKeepaliveTimeout: 2500 });
    const player = new Socket();
    server.onPlayerConnected(player, request());
    assert.equal(timers.length, 1);
    assert.equal(timers[0].delay, 2500);
    timers[0].callback();
    assert.equal(player.messages.at(-1).type, 'ping');
    player.receive({ type: 'pong', time: player.messages.at(-1).time });
    timers[0].callback();
    assert.equal(player.terminations, 0);
    timers[0].callback();
    assert.equal(player.terminations, 1);
    assert.deepEqual(cleared, [timers[0]]);
    assert.equal(server.playerRegistry.count(), 0);
});

test('upstream subscription refusal remains safe and streamer forwarding stays subscriber-scoped', () => {
    const server = serverWith({ maxSubscribers: 1 });
    const streamer = new Socket();
    const first = new Socket();
    const second = new Socket();
    server.onStreamerConnected(streamer, request());
    server.onPlayerConnected(first, request());
    server.onPlayerConnected(second, request());
    const [firstPlayer, secondPlayer] = server.playerRegistry.listPlayers();
    first.receive({ type: 'subscribe', streamerId: 'UnknownStreamer' });
    const secondMessageCount = second.messages.length;
    streamer.receive({ type: 'offer', playerId: secondPlayer.playerId, sdp: 'not-for-this-player' });
    assert.equal(second.messages.length, secondMessageCount);
    streamer.receive({ type: 'offer', playerId: firstPlayer.playerId, sdp: 'subscribed-player' });
    assert.equal(first.messages.at(-1).sdp, 'subscribed-player');
    assert.doesNotThrow(() => second.receive({ type: 'answer', sdp: 'implicit-subscription' }));
    assert.equal(second.readyState, WebSocket.CLOSED);
    assert.equal(server.playerRegistry.count(), 1);
    first.close(); streamer.close();
});

test('SFU resubscription releases old membership and forwarding remains limited to its viewers', () => {
    const server = serverWith();
    const oldStreamer = new Socket();
    const replacementStreamer = new Socket();
    const sfu = new Socket();
    const viewer = new Socket();
    const unrelatedViewer = new Socket();
    server.onStreamerConnected(oldStreamer, request());
    server.onStreamerConnected(replacementStreamer, request());
    server.onSFUConnected(sfu, request());
    server.onPlayerConnected(viewer, request());
    server.onPlayerConnected(unrelatedViewer, request());
    const [oldConnection, replacementConnection, sfuConnection] = server.streamerRegistry.streamers;
    const [, viewerConnection, unrelatedConnection] = server.playerRegistry.listPlayers();
    sfu.receive({ type: 'subscribe', streamerId: oldConnection.streamerId });
    oldStreamer.receive({ type: 'offer', playerId: sfuConnection.playerId, sdp: 'sfu-upstream' });
    assert.equal(sfu.messages.at(-1).sdp, 'sfu-upstream');
    viewer.receive({ type: 'subscribe', streamerId: sfuConnection.streamerId });
    const unrelatedCount = unrelatedViewer.messages.length;
    sfu.receive({ type: 'offer', playerId: unrelatedConnection.playerId, sdp: 'unrelated-viewer' });
    assert.equal(unrelatedViewer.messages.length, unrelatedCount);
    sfu.receive({ type: 'offer', playerId: viewerConnection.playerId, sdp: 'sfu-viewer' });
    assert.equal(viewer.messages.at(-1).sdp, 'sfu-viewer');

    sfu.receive({ type: 'subscribe', streamerId: replacementConnection.streamerId });
    assert.equal(oldConnection.subscribers.has(sfuConnection.playerId), false);
    assert.equal(replacementConnection.subscribers.has(sfuConnection.playerId), true);
    assert.equal(oldStreamer.messages.at(-1).type, 'playerDisconnected');
    const sfuCount = sfu.messages.length;
    oldStreamer.receive({ type: 'offer', playerId: sfuConnection.playerId, sdp: 'stale-upstream' });
    assert.equal(sfu.messages.length, sfuCount);
    oldStreamer.close();
    assert.equal(sfuConnection.subscribedStreamer, replacementConnection);
    replacementStreamer.receive({ type: 'offer', playerId: sfuConnection.playerId, sdp: 'current-upstream' });
    assert.equal(sfu.messages.at(-1).sdp, 'current-upstream');
    sfu.close();
    assert.equal(replacementConnection.subscribers.has(sfuConnection.playerId), false);
    viewer.close(); unrelatedViewer.close(); replacementStreamer.close();
});

test('streamer authorization remains optional and receives the original upgrade identity when supplied', () => {
    const server = serverWith();
    const ordinary = new Socket();
    server.onStreamerConnected(ordinary, request());
    ordinary.receive({ type: 'endpointId', id: 'application' });
    assert.equal(server.streamerRegistry.find('application').streamerId, 'application');
    ordinary.close();

    const seen = [];
    const guarded = serverWith({ authorizeStreamerId(details) { seen.push(details); return null; } });
    const rejected = new Socket();
    const authenticatedRequest = request();
    authenticatedRequest.authenticatedStreamer = 'tenant-a';
    guarded.onStreamerConnected(rejected, authenticatedRequest);
    rejected.receive({ type: 'endpointId', id: 'forbidden' });
    assert.equal(seen.length, 1);
    assert.equal(seen[0].streamer.request, authenticatedRequest);
    assert.equal(seen[0].requestedId, 'forbidden');
    assert.equal(seen[0].sanitizedId, 'forbidden');
    assert.equal(rejected.readyState, WebSocket.CLOSED);
    assert.equal(guarded.streamerRegistry.count(), 0);
});

test('numeric streamer-id collisions stay unique and repeated endpoint identity remains stable', () => {
    const server = serverWith();
    const first = new Socket();
    const second = new Socket();
    server.onStreamerConnected(first, request());
    server.onStreamerConnected(second, request());
    first.receive({ type: 'endpointId', id: 'application1' });
    second.receive({ type: 'endpointId', id: 'application1' });
    const [firstConnection, secondConnection] = server.streamerRegistry.streamers;
    assert.equal(firstConnection.streamerId, 'application1');
    assert.notEqual(secondConnection.streamerId, 'application1');
    assert.equal(server.streamerRegistry.find(firstConnection.streamerId), firstConnection);
    assert.equal(server.streamerRegistry.find(secondConnection.streamerId), secondConnection);
    first.receive({ type: 'endpointId', id: 'application1' });
    assert.equal(firstConnection.streamerId, 'application1');
    assert.equal(first.messages.at(-1).committedId, 'application1');
    first.close(); second.close();
});

test('malformed endpoint ids reject only their streamer and cannot corrupt later registrations', () => {
    const server = serverWith();
    for (const id of [null, undefined, [], {}, true, 123]) {
        const socket = new Socket();
        server.onStreamerConnected(socket, request());
        socket.receive({ type: 'endpointId', id });
        assert.equal(socket.readyState, WebSocket.CLOSED);
        assert.equal(server.streamerRegistry.count(), 0);
    }
    const healthy = new Socket();
    server.onStreamerConnected(healthy, request());
    healthy.receive({ type: 'endpointId', id: 'healthy' });
    assert.ok(server.streamerRegistry.find('healthy'));
    healthy.close();
});

test('throwing or malformed streamer authorizers reject the connection without corrupting the registry', () => {
    for (const authorizer of [() => { throw new Error('synthetic-provider-secret'); }, () => undefined, () => 12, () => [], () => '']) {
        const server = serverWith({ authorizeStreamerId: authorizer });
        const socket = new Socket();
        server.onStreamerConnected(socket, request());
        socket.receive({ type: 'endpointId', id: 'application' });
        assert.equal(socket.readyState, WebSocket.CLOSED);
        assert.equal(server.streamerRegistry.count(), 0);
    }
});

test('peer-options provider errors cannot leak exception details or break role fallback', (context) => {
    const logs = [];
    context.mock.method(Logger, 'error', (...args) => logs.push(args));
    const cyclicError = { credential: 'synthetic-provider-secret' };
    cyclicError.self = cyclicError;
    for (const error of [new Error('synthetic-provider-secret'), cyclicError]) {
        const server = serverWith({ peerOptionsProvider() { throw error; } });
        const socket = new Socket();
        assert.doesNotThrow(() => server.onStreamerConnected(socket, request()));
        assert.deepEqual(socket.messages[0].peerConnectionOptions, streamerOptions);
        assert.deepEqual(socket.messages.map(message => message.type), ['config', 'identify']);
        socket.close();
    }
    assert.equal(JSON.stringify(logs).includes('synthetic-provider-secret'), false);
});

for (const role of ['player', 'sfu']) {
    test(role + ' subscription rejects non-string streamer ids without escaping its handler', () => {
        const server = serverWith();
        for (const streamerId of [null, undefined, 12, [], { toString: null }]) {
            const socket = new Socket();
            if (role === 'player') server.onPlayerConnected(socket, request());
            else server.onSFUConnected(socket, request());
            socket.receive({ type: 'subscribe', streamerId });
            assert.equal(socket.readyState, WebSocket.CLOSED);
            assert.equal(server.playerRegistry.count(), 0);
            assert.equal(server.streamerRegistry.count(), 0);
        }
    });
}

test('streamer and SFU messages with malformed player ids are ignored and valid forwarding still works', () => {
    const server = serverWith();
    const streamer = new Socket();
    const sfu = new Socket();
    const viewer = new Socket();
    server.onStreamerConnected(streamer, request());
    server.onSFUConnected(sfu, request());
    server.onPlayerConnected(viewer, request());
    const [streamerConnection, sfuConnection] = server.streamerRegistry.streamers;
    const [, viewerConnection] = server.playerRegistry.listPlayers();
    viewer.receive({ type: 'subscribe', streamerId: streamerConnection.streamerId });
    const count = viewer.messages.length;
    for (const playerId of [null, undefined, 123, [], { toString: null }]) {
        for (const type of ['offer', 'answer', 'iceCandidate', 'disconnectPlayer']) {
            streamer.receive({ type, playerId, sdp: 'malformed' });
        }
        sfu.receive({ type: 'offer', playerId, sdp: 'malformed' });
    }
    assert.equal(viewer.readyState, WebSocket.OPEN);
    assert.equal(viewer.messages.length, count);
    streamer.receive({ type: 'offer', playerId: viewerConnection.playerId, sdp: 'valid-direct' });
    assert.equal(viewer.messages.at(-1).sdp, 'valid-direct');
    viewer.receive({ type: 'subscribe', streamerId: sfuConnection.streamerId });
    sfu.receive({ type: 'offer', playerId: viewerConnection.playerId, sdp: 'valid-sfu' });
    assert.equal(viewer.messages.at(-1).sdp, 'valid-sfu');
    viewer.close(); sfu.close(); streamer.close();
});

test('streamer disconnect reasons preserve valid UTF-8 values and cannot break ws close framing', () => {
    // Use the real ws close-frame builder so a malformed/overlong reason fails this regression
    // if it ever reaches the transport again, without opening an external network connection.
    class ClosingSocket extends Socket {
        close(code, reason) {
            if (this.readyState === WebSocket.CLOSED) return;
            const sender = new WebSocket.Sender({});
            sender.sendFrame = () => {};
            sender.close(code, reason, false, () => {});
            this.closeFrame = { code, reason };
            super.close();
        }
    }
    for (const reason of [undefined, '', 'Session ended', 'a'.repeat(123), '€'.repeat(41), null, { toString: null }, 'a'.repeat(124), '€'.repeat(42)]) {
        const server = serverWith();
        const streamer = new Socket();
        const viewer = new ClosingSocket();
        server.onStreamerConnected(streamer, request());
        server.onPlayerConnected(viewer, request());
        const player = server.playerRegistry.listPlayers()[0];
        viewer.receive({ type: 'subscribe', streamerId: 'UnknownStreamer' });
        streamer.receive({ type: 'disconnectPlayer', playerId: player.playerId, reason });
        assert.equal(viewer.readyState, WebSocket.CLOSED);
        assert.equal(viewer.closeFrame.code, 1011);
        assert.equal(viewer.closeFrame.reason, typeof reason === 'string' && Buffer.byteLength(reason) <= 123 ? reason : undefined);
        assert.equal(server.playerRegistry.count(), 0);
        streamer.close();
    }
});

test('unhandled player and streamer diagnostics redact credential fields without losing message identity', (context) => {
    const logs = [];
    context.mock.method(Logger, 'warn', message => logs.push(message));
    const server = serverWith();
    const streamer = new Socket();
    const player = new Socket();
    server.onStreamerConnected(streamer, request());
    server.onPlayerConnected(player, request());
    const message = { type: 'custom-extension', diagnostic: 'retained', nested: { credential: 'synthetic-private-credential', authorization: 'synthetic-private-authorization', access_token: 'synthetic-private-token' } };
    streamer.receive(message);
    player.receive(message);
    assert.equal(logs.length, 2);
    for (const log of logs) {
        assert.equal(log.includes('synthetic-private'), false);
        assert.match(log, /custom-extension/);
        assert.match(log, /retained/);
        assert.match(log, /\[REDACTED\]/);
    }
    assert.equal(message.nested.credential, 'synthetic-private-credential');
    player.close(); streamer.close();
});
