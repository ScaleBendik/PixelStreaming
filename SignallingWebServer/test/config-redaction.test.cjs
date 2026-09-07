// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');
const { sanitizeOptionsForLogging } = require('../dist/Utils.js');

test('startup and interactive config views redact all runtime secrets without changing live options', () => {
    const options = {
        auth_signing_key: 'test-ticket-key',
        turn_secret: 'test-turn-secret',
        instance_agent_bootstrap_shared_secret: 'test-agent-secret',
        peer_options: { iceServers: [{ username: 'test-user', credential: 'test-password' }] },
        peer_options_player: { iceServers: [{ credential: 'test-player' }] },
        peer_options_streamer: { iceServers: [{ credential: 'test-streamer' }] },
        turn_secret_file: 'test-secret-file',
        player_port: 8080
    };
    const original = structuredClone(options);
    const sanitized = sanitizeOptionsForLogging(options);
    for (const field of Object.keys(options).filter((key) => key !== 'turn_secret_file' && key !== 'player_port')) {
        assert.equal(sanitized[field], '[redacted]');
    }
    assert.equal(sanitized.turn_secret_file, options.turn_secret_file);
    assert.equal(sanitized.player_port, options.player_port);
    assert.deepEqual(options, original);
});
