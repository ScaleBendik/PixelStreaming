// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');

const { redactSensitiveLogValue, redactSensitiveProtocolLog } = require('../dist/cjs/LogRedaction.js');

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

test('redacts enumerable fields on generated protocol-message class instances', () => {
    class GeneratedConfigMessage {
        constructor() {
            this.type = 'config';
            this.peerConnectionOptions = {
                iceServers: [
                    {
                        urls: ['turn:turn.example.test:3478'],
                        username: 'generated-turn-user',
                        credential: 'generated-turn-secret'
                    }
                ]
            };
        }
    }

    const redacted = redactSensitiveLogValue(new GeneratedConfigMessage());

    assert.equal(redacted.peerConnectionOptions.iceServers[0].username, '[REDACTED]');
    assert.equal(redacted.peerConnectionOptions.iceServers[0].credential, '[REDACTED]');
});

for (const direction of ['sent', 'received']) {
    test('redacts serialized Common protocol ' + direction + ' debug messages', () => {
        const payload = { type: 'config', peerConnectionOptions: { iceServers: [{
            urls: 'turn:example.test', username: 'temporary-username', credential: 'temporary-credential'
        }] } };
        const prefix = 'Protocol ' + direction + ' => \n';
        const redacted = redactSensitiveProtocolLog(prefix + JSON.stringify(payload, undefined, 4));
        assert.ok(redacted.startsWith(prefix));
        const parsed = JSON.parse(redacted.slice(prefix.length));
        assert.equal(parsed.peerConnectionOptions.iceServers[0].credential, '[REDACTED]');
        assert.equal(parsed.peerConnectionOptions.iceServers[0].username, '[REDACTED]');
        assert.equal(parsed.peerConnectionOptions.iceServers[0].urls, 'turn:example.test');
        assert.equal(payload.peerConnectionOptions.iceServers[0].credential, 'temporary-credential');
    });
}

test('malformed protocol debug payloads fail closed without changing ordinary debug text', () => {
    assert.equal(redactSensitiveProtocolLog('Protocol sent => {invalid-secret'), 'Protocol sent => [REDACTED]');
    assert.equal(redactSensitiveProtocolLog('peer disconnected'), 'peer disconnected');
});
