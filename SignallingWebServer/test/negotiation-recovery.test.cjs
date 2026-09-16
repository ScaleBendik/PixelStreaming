const test = require('node:test');
const assert = require('node:assert/strict');
const { NegotiationRecovery } = require('../dist/negotiation-recovery.js');

test('short reconnects accumulate actual unanswered wait without counting disconnected gaps', () => {
    let now = 0;
    const faults = [], streamer = {};
    const recovery = new NegotiationRecovery(s => faults.push(s), () => now);
    recovery.started(streamer, 'signed-a', 'p1');
    now = 23_000; recovery.abandoned(streamer, 'signed-a', 'p1');
    now = 100_000; recovery.check();
    assert.equal(faults.length, 0, 'closed tabs and idle time alone are not a fault');
    recovery.started(streamer, 'signed-a', 'p2');
    now += 36_999; recovery.check(); assert.equal(faults.length, 0);
    now++; recovery.check(); assert.deepEqual(faults, [streamer]);
    recovery.check(); assert.equal(faults.length, 1);
});

test('a response, replacement, different request or expired retry history cannot inherit a timeout', () => {
    let now = 0;
    const faults = [], streamer = {}, replacement = {};
    const recovery = new NegotiationRecovery(s => faults.push(s), () => now);
    recovery.started(streamer, 'a', 'p1'); now = 50_000;
    recovery.responded(streamer, 'a'); recovery.check();
    recovery.started(streamer, 'b', 'p2');
    now += 20_000; recovery.check(); assert.equal(faults.length, 0);
    recovery.abandoned(streamer, 'b', 'p2');
    now += 300_001; recovery.started(streamer, 'b', 'p3');
    now += 40_000; recovery.check(); assert.equal(faults.length, 0);
    recovery.removed(streamer);
    recovery.started(replacement, 'b', 'p4'); now += 20_000;
    recovery.check(); assert.equal(faults.length, 0);
});

test('overlapping viewers count elapsed time once, and unanswered browser negotiation does not blame Unreal', () => {
    let now = 0;
    const faults = [], streamer = {};
    const recovery = new NegotiationRecovery(s => faults.push(s), () => now);
    recovery.started(streamer, 'a', 'p1');
    now = 20_000; recovery.started(streamer, 'a', 'p2');
    now = 40_000; recovery.abandoned(streamer, 'a', 'p1');
    recovery.check(); assert.equal(faults.length, 0);
    now = 59_999; recovery.check(); assert.equal(faults.length, 0);
    recovery.responded(streamer, 'a');
    now = 120_000; recovery.check();
    assert.equal(faults.length, 0, 'an Unreal offer clears the wait even if the browser never answers');
});

test('runtime health wiring catches short retries despite live pings, then clears on the Unreal response', t => {
    const { EventEmitter } = require('node:events');
    const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
    const { wireSignallingRuntimeStatus } = require('../dist/runtime-status.js');
    t.mock.timers.enable({ apis: ['Date'], now: 1_000_000 });
    const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-retry-health-'));
    t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
    const healthPath = path.join(folder, 'health.json');
    const streamer = Object.assign(new EventEmitter(), {
        streamerId: 'DefaultStreamer', streaming: true, protocol: new EventEmitter()
    });
    const registry = Object.assign(new EventEmitter(), {
        streamers: [streamer], count() { return this.streamers.length; }, find() { return this.streamers[0]; }
    });
    const players = new EventEmitter();
    wireSignallingRuntimeStatus({ streamerRegistry: registry, playerRegistry: players }, null, {
        logger() {}, heartbeatMs: 0, readySoakMs: 0, streamerHealthEnabled: true,
        streamerHealthPath: healthPath, streamerHealthWriteMs: 0
    });
    const health = () => JSON.parse(fs.readFileSync(healthPath, 'utf8'));
    players.emit('streamer_negotiation_started', streamer, 'signed-a', 'p1');
    t.mock.timers.tick(30_000);
    players.emit('streamer_negotiation_abandoned', streamer, 'signed-a', 'p1');
    t.mock.timers.tick(60_000); streamer.protocol.emit('ping', {});
    assert.equal(health().healthy, true, 'disconnected time cannot cause a restart');
    players.emit('streamer_negotiation_started', streamer, 'signed-a', 'p2');
    t.mock.timers.tick(30_000); streamer.protocol.emit('ping', {});
    assert.equal(health().healthy, false);
    assert.equal(health().reason, 'streamer_negotiation_timeout');
    streamer.protocol.emit('ping', {}); assert.equal(health().healthy, false);
    players.emit('streamer_negotiation_response', streamer, 'signed-a');
    assert.equal(health().healthy, true);
});
