import { SessionQuality } from './SessionQuality';

describe('session quality', () => {
    test('uses connected byte deltas including stalls and excludes available/reconnect time', () => {
        const q = new SessionQuality();
        q.observe('a', 0, 0, 0);
        q.setConnected(true);
        q.observe('a', 100_000, 100, 100_000);
        q.observeLatency(50, 100_000);
        q.observe('a', 101_000, 2_500_100, 101_000);
        q.observe('a', 102_000, 2_500_100, 102_000);
        q.setConnected(false);
        q.observe('a', 200_000, 100_000_000, 200_000);
        q.setConnected(true);
        q.observe('b', 300_000, 0, 300_000);
        q.observe('b', 301_000, 1_250_000, 301_000);
        expect(q.report(301_000, 30_000)).toMatchObject({
            connectedMs: 3000,
            videoBytes: 3_750_000,
            latencyDurationMs: 2000,
            latencyWeightedMs: 100_000,
            maxBitrateKbps: 30_000
        });
    });
    test('ignores counter reset, replacement stream, suspended gaps and unavailable latency', () => {
        const q = new SessionQuality();
        q.setConnected(true);
        q.observe('a', 0, 1000, 0);
        q.observe('a', 1000, 0, 1000);
        q.observe('b', 2000, 9000, 2000);
        q.observe('b', 100_000, 100_000, 100_000);
        q.observeLatency(NaN, 100_000);
        q.observe('b', 101_000, 101_000, 101_000);
        expect(q.report(101_000, undefined)).toMatchObject({
            connectedMs: 1000,
            videoBytes: 1000,
            latencyDurationMs: 0
        });
    });
    test('bounds reports to one minute with a best-effort final summary and latest cap', () => {
        const q = new SessionQuality();
        q.setConnected(true);
        q.observe('a', 0, 0, 0);
        q.observe('a', 1000, 1000, 1000);
        expect(q.report(10_000, 30_000)).toBeUndefined();
        expect(q.report(60_000, 30_000)?.maxBitrateKbps).toBe(30_000);
        expect(q.report(61_000, 20_000)).toBeUndefined();
        expect(q.report(61_000, 20_000, true)?.maxBitrateKbps).toBe(20_000);
    });
});
