// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');

const { redactSensitiveLogValue } = require('../dist/cjs/LogRedaction.js');

test('redacts nested TURN credentials and tokens without mutating protocol messages', () => {
    const message = {
        type: 'config',
        peerConnectionOptions: {
            iceServers: [
                {
                    urls: ['turn:turn.example.test:3478'],
                    username: 'temporary-turn-user',
                    credential: 'temporary-turn-secret'
                }
            ],
            nested: {
                access_token: 'connect-ticket',
                harmless: 'retained'
            }
        }
    };

    const redacted = redactSensitiveLogValue(message);

    assert.deepEqual(redacted, {
        type: 'config',
        peerConnectionOptions: {
            iceServers: [
                {
                    urls: ['turn:turn.example.test:3478'],
                    username: '[REDACTED]',
                    credential: '[REDACTED]'
                }
            ],
            nested: {
                access_token: '[REDACTED]',
                harmless: 'retained'
            }
        }
    });
    assert.equal(message.peerConnectionOptions.iceServers[0].credential, 'temporary-turn-secret');
});

test('preserves cycles in the logging copy without retaining secrets', () => {
    const message = { type: 'config', password: 'secret' };
    message.self = message;

    const redacted = redactSensitiveLogValue(message);

    assert.equal(redacted.password, '[REDACTED]');
    assert.equal(redacted.self, redacted);
});
