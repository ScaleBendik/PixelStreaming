const assert = require('node:assert/strict');
const test = require('node:test');
const { SessionQualityReceiver } = require('../dist/cjs/SessionQuality.js');
const report = { telemetryVersion: 1, connectedMs: 1000, videoBytes: 1000, latencyDurationMs: 1000, latencyWeightedMs: 50_000, maxBitrateKbps: 30_000 };
test('rate limits, bounds and assigns its own connection identity and sequence', () => {
    const q = new SessionQualityReceiver(); const now = Date.now();
    const first = q.accept({...report, connectionId: 'untrusted', sequence: 999}, now);
    assert.equal(first.sequence, 1); assert.notEqual(first.connectionId, 'untrusted');
    assert.equal(q.accept(report, now + 1000), undefined);
    assert.equal(q.accept({...report, connectedMs: 1e12}, now + 60_000), undefined);
    assert.equal(q.accept({...report, videoBytes: 1}, now + 60_000), undefined);
    assert.equal(q.accept({...report, maxBitrateKbps: Infinity}, now + 60_000), undefined);
    const second = q.accept({...report, connectedMs: 2000, maxBitrateKbps: 20_000}, now + 60_000);
    assert.equal(second.sequence, 2); assert.equal(second.connectionId, first.connectionId);
});
