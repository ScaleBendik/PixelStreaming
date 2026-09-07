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
            scaleWorldValidatedConnectTicketIdentity: identity
        } : {})
    };
}

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
