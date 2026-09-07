// Copyright Epic Games, Inc. All Rights Reserved.
const assert = require('node:assert/strict');
const test = require('node:test');
const { EventEmitter, SignallingProtocol, overrideLogger } = require('@epicgames-ps/lib-pixelstreamingcommon-ue5.8');
const messages = [];
overrideLogger({ InitLogging() {}, Debug() {}, Info() {}, Warning(message) { messages.push(message); }, Error(message) { messages.push(message); } });

function harness() {
    const transport = new EventEmitter();
    const protocol = new SignallingProtocol(transport);
    return { transport, protocol };
}

test('malformed protocol envelopes never reach transport or protocol handlers and later messages still work', () => {
    const { transport, protocol } = harness();
    const received = [];
    const unhandled = [];
    transport.on('message', value => received.push(value));
    protocol.on('unhandled', value => unhandled.push(value));
    for (const envelope of [null, [], [1], true, 12, 'text', {}, { type: null }, { type: [] }, { type: 1 }, { type: '' }]) {
        assert.doesNotThrow(() => transport.onMessage(JSON.stringify(envelope)));
    }
    assert.deepEqual(received, []);
    assert.deepEqual(unhandled, []);
    const extension = { type: 'custom-extension', opaque: { version: 1 } };
    transport.onMessage(JSON.stringify(extension));
    assert.deepEqual(received, [extension]);
    assert.deepEqual(unhandled, [extension]);
    const pings = [];
    protocol.on('ping', value => pings.push(value));
    transport.onMessage(JSON.stringify({ type: 'ping', time: 123 }));
    assert.deepEqual(pings, [{ type: 'ping', time: 123 }]);
});

test('invalid JSON is discarded without exposing its raw credential-like contents', () => {
    const { transport } = harness();
    messages.length = 0;
    assert.doesNotThrow(() => transport.onMessage('{"credential":"synthetic-private-value"'));
    assert.equal(messages.length, 1);
    assert.equal(messages[0].includes('synthetic-private-value'), false);
});

test('valid-message handler failures remain outside the parser exception boundary', () => {
    const { transport, protocol } = harness();
    const failure = new Error('handler failed');
    protocol.emit = () => { throw failure; };
    assert.throws(() => transport.onMessage('{"type":"ping"}'), error => error === failure);
});
