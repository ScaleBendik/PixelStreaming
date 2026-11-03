const assert = require('node:assert/strict');
const test = require('node:test');
const { TurnRelayObservationReceiver } = require('../dist/cjs/TurnRelayObservation');

const observation = host => ({relayEvidenceVersion:1, usesTurn:true, localRelay:true, remoteRelay:false,
    localRelayUrl:`turn:${host}:3478?transport=udp`});

test('path transitions are immediate, duplicate reports are throttled, and bursts remain bounded', () => {
    const receiver = new TurnRelayObservationReceiver();
    const first = receiver.accept(observation('primary.test'), 100_000);
    assert.equal(first.sequence, 1);
    assert.equal(receiver.accept(observation('primary.test'), 100_001), undefined);
    const fallback = receiver.accept(observation('fallback.test'), 100_002);
    assert.equal(fallback.sequence, 2);
    assert.equal(fallback.connectionId, first.connectionId);
    assert.equal(receiver.accept(observation('primary.test'), 100_003).sequence, 3);
    assert.equal(receiver.accept(observation('fallback.test'), 100_004).sequence, 4);
    assert.equal(receiver.accept(observation('primary.test'), 100_005), undefined);
    assert.equal(receiver.accept(observation('primary.test'), 110_000).sequence, 5, 'one token refills after ten seconds');
});

test('invalid messages cannot consume the transition budget or overwrite server correlation', () => {
    const receiver = new TurnRelayObservationReceiver();
    for (let i = 0; i < 20; i++) assert.equal(receiver.accept({...observation('bad.test'), relayEvidenceVersion:2}, 100_000), undefined);
    const accepted = receiver.accept({...observation('primary.test'), connectionId:'spoof', sequence:500, relayRole:'fallback'}, 100_000);
    assert.equal(accepted.sequence, 1);
    assert.notEqual(accepted.connectionId, 'spoof');
    assert.equal(accepted.relayRole, undefined);
});
