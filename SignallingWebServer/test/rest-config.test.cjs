// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');
const operations = require('../dist/paths/config').default;

test('REST config omits live transports and redacts ICE secrets without mutating runtime options', () => {
    const transport = { privateKey: 'private-key-that-must-not-be-disclosed' };
    transport.self = transport;
    const peerOptions = {
        iceTransportPolicy: 'relay',
        iceServers: [{ urls: 'turn:example.test', username: 'private-user', credential: 'private-credential' }]
    };
    const server = {
        config: {
            streamerPort: 8888, maxSubscribers: 3,
            httpServer: transport, httpsServer: transport,
            playerWsOptions: { server: transport }, streamerWsOptions: { server: transport }, sfuWsOptions: { server: transport },
            peerOptions, peerOptionsPlayer: peerOptions, peerOptionsStreamer: peerOptions,
            authorizeStreamerId() {}, peerOptionsProvider() {}
        },
        protocolConfig: { peerConnectionOptions: peerOptions }
    };
    let body;
    const res = {
        status(code) { assert.equal(code, 200); return this; },
        json(value) { body = JSON.parse(JSON.stringify(value)); }
    };
    operations(server).GET({}, res, () => {});
    assert.equal(body.config.streamerPort, 8888);
    assert.equal(body.config.maxSubscribers, 3);
    for (const key of ['httpServer', 'httpsServer', 'playerWsOptions', 'streamerWsOptions', 'sfuWsOptions', 'authorizeStreamerId', 'peerOptionsProvider']) {
        assert.equal(Object.hasOwn(body.config, key), false, key + ' must not be exposed');
    }
    for (const options of [body.config.peerOptions, body.config.peerOptionsPlayer, body.config.peerOptionsStreamer, body.protocolConfig.peerConnectionOptions]) {
        assert.equal(options.iceTransportPolicy, 'relay');
        assert.equal(options.iceServers[0].urls, 'turn:example.test');
        assert.equal(options.iceServers[0].username, '[REDACTED]');
        assert.equal(options.iceServers[0].credential, '[REDACTED]');
    }
    assert.equal(peerOptions.iceServers[0].credential, 'private-credential');
    assert.equal(peerOptions.iceServers[0].username, 'private-user');
});
