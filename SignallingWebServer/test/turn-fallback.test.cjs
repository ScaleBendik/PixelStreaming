const assert = require('node:assert/strict');
const test = require('node:test');
const { TurnRelayClassifier, withTurnFallback } = require('../dist/turn-fallback');

const environment = {
    SCALEWORLD_TURN_MODE: 'redundant', SCALEWORLD_STREAMING_LANE: 'prod', TURN_PUBLIC_HOST: 'turn-prod.scaleworld.net',
    TURN_PRIVATE_HOST: 'turn-prod.internal.scaleworld.net', TURN_USERNAME: 'primary-user', TURN_CREDENTIAL: 'primary-secret',
    TURN_FALLBACK_USERNAME: 'fallback-user', TURN_FALLBACK_CREDENTIAL: 'fallback-secret'
};
test('independent fallback credentials preserve primary and STUN entries on both peers', () => {
    const primary = { iceTransportPolicy: 'all', iceServers: [
        { urls: ['stun:stun.example.test'] },
        { urls: ['turn:turn-prod.scaleworld.net:3478?transport=udp'], username: 'primary-user', credential: 'primary-secret' }
    ] };
    for (const peer of ['player', 'streamer']) {
        const result = withTurnFallback(primary, peer, environment);
        assert.equal(primary.iceServers.length, 2);
        assert.deepEqual(result.iceServers.slice(0, 2), primary.iceServers);
        assert.equal(result.iceServers[2].credential, 'fallback-secret');
        assert.equal(result.iceServers[2].username, 'fallback-user');
        assert.match(result.iceServers[2].urls[0], peer === 'player' ? /turn.scaleworld.net/ : /172.31.32.124/);
    }
    assert.equal(withTurnFallback(primary, 'player', {}), primary);
    assert.throws(() => withTurnFallback(primary, 'player', {...environment, TURN_FALLBACK_CREDENTIAL: ''}));
    assert.throws(() => withTurnFallback(primary, 'player', {...environment, TURN_FALLBACK_USERNAME: 'primary-user'}));
    for (const lane of ['nonprod', undefined])
        assert.throws(() => withTurnFallback(primary, 'player', {...environment, SCALEWORLD_STREAMING_LANE: lane}), /Prod-only/);
});

test('DNS aliases cannot turn primary identity into a false fallback warning or conceal a different relay leg', async () => {
    const classifier = new TurnRelayClassifier(environment, async () => [{address:'192.0.2.10',family:4}]);
    await classifier.refreshAddresses();
    const observation = { usesTurn:true, localRelay:true, remoteRelay:false,
        localRelayUrl:'turn:turn-prod.scaleworld.net:3478?transport=udp', remoteRelayAddress:'192.0.2.10' };
    assert.equal(classifier.classify(observation), 'primary', 'unused remote address cannot override the explicit local URL');
    assert.equal(classifier.classify({...observation, remoteRelay:true}), 'unknown', 'the remote leg is ambiguous, not proven fallback');
    assert.equal(classifier.classify({...observation, remoteRelay:true, localRelayUrl:'turn:turn.scaleworld.net:3478?transport=udp'}), 'fallback', 'explicit local fallback still counts');
    const nonprod = new TurnRelayClassifier({...environment, SCALEWORLD_TURN_MODE:'isolated', SCALEWORLD_STREAMING_LANE:'nonprod',
        TURN_PUBLIC_HOST:'turn-nonprod.scaleworld.net'}, async () => [{address:'172.31.32.124',family:4}]);
    await nonprod.refreshAddresses();
    assert.equal(nonprod.classify({...observation, localRelay:false, remoteRelay:true, remoteRelayAddress:'172.31.32.124'}), 'primary');
});

test('concurrent first reports share DNS completion, and stalled DNS is bounded', async () => {
    let release;
    const held = new Promise(resolve => { release = resolve; });
    let calls = 0;
    const classifier = new TurnRelayClassifier(environment, async () => { calls++; return held; });
    const first = classifier.refreshAddresses();
    const second = classifier.refreshAddresses();
    assert.equal(first, second);
    assert.equal(calls, 3);
    release([{address:'192.0.2.10',family:4}]);
    await second;
    const stalled = new TurnRelayClassifier(environment, () => new Promise(() => {}), 5);
    await Promise.all([stalled.refreshAddresses(), new Promise(resolve => setTimeout(resolve, 20))]);
    assert.equal(stalled.classify({usesTurn:true, localRelay:false, remoteRelay:true, remoteRelayAddress:'192.0.2.30'}), 'unknown');
});
test('classifies either selected relay leg without treating missing or malformed identity as primary', async () => {
    const classifier = new TurnRelayClassifier(environment, async host => [{address: host === 'turn.scaleworld.net' ? '192.0.2.10' : '192.0.2.20', family: 4}]);
    await classifier.refreshAddresses();
    const observation = { usesTurn: true, localRelay: true, remoteRelay: false,
        localRelayUrl: 'turns:turn.scaleworld.net:443?transport=tcp' };
    assert.equal(classifier.classify(observation), 'fallback');
    assert.equal(classifier.classify({...observation, localRelayUrl: 'turn:turn-prod.scaleworld.net:3478?transport=udp'}), 'primary');
    assert.equal(classifier.classify({...observation, localRelayUrl: 'turn:turn-prod.scaleworld.net:3478?transport=udp', remoteRelay: true, remoteRelayAddress: '192.0.2.10'}), 'fallback');
    assert.equal(classifier.classify({...observation, localRelayUrl: undefined}), 'unknown');
    assert.equal(classifier.classify({...observation, localRelayUrl: 'turn:user:secret@turn.scaleworld.net:3478?transport=udp'}), 'unknown');
    assert.equal(classifier.classify({...observation, localRelay: false, remoteRelay: true, localRelayUrl: undefined, remoteRelayAddress: '172.31.32.124'}), 'fallback');
    assert.equal(classifier.classify({usesTurn:false}), 'direct');
    const legacy = new TurnRelayClassifier({...environment, SCALEWORLD_TURN_MODE:'legacy-shared', TURN_PUBLIC_HOST:'turn.scaleworld.net'});
    assert.equal(legacy.classify(observation), 'primary');
});
test('failed DNS does not make unknown remote relay evidence healthy', async () => {
    const classifier = new TurnRelayClassifier(environment, async () => { throw Error('offline'); });
    await classifier.refreshAddresses();
    assert.equal(classifier.classify({usesTurn:true, localRelay:false, remoteRelay:true, remoteRelayAddress:'192.0.2.30'}), 'unknown');
});
