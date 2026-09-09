const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { wireSignallingRuntimeStatus } = require('../dist/runtime-status.js');

test('Unreal negotiation timeout stays unhealthy through ping/pong and clears on a response or replacement', t => {
    const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-negotiation-health-'));
    t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
    const healthPath = path.join(folder, 'health.json');
    const createStreamer = () => Object.assign(new EventEmitter(), {
        streamerId: 'DefaultStreamer', streaming: true, protocol: new EventEmitter()
    });
    const streamer = createStreamer();
    const registry = Object.assign(new EventEmitter(), {
        streamers: [streamer], count() { return this.streamers.length; }, find() { return this.streamers[0]; }
    });
    const players = new EventEmitter();
    wireSignallingRuntimeStatus({ streamerRegistry: registry, playerRegistry: players }, null, {
        logger() {}, heartbeatMs: 0, readySoakMs: 0, streamerHealthEnabled: true,
        streamerHealthPath: healthPath, streamerHealthWriteMs: 0
    });
    const health = () => JSON.parse(fs.readFileSync(healthPath, 'utf8'));
    assert.equal(health().healthy, true); // Idle warm pool is valid.
    players.emit('streamer_negotiation_timeout', streamer);
    streamer.protocol.emit('ping', {});
    assert.equal(health().healthy, false);
    assert.equal(health().reason, 'streamer_negotiation_timeout');
    players.emit('streamer_negotiation_response', streamer);
    assert.equal(health().healthy, true);
    players.emit('streamer_negotiation_timeout', streamer);
    registry.streamers = [createStreamer()];
    registry.emit('added', 'DefaultStreamer');
    assert.equal(health().healthy, true);
});
