// Copyright Epic Games, Inc. All Rights Reserved.

/** Cumulative browser evidence. Only paired samples taken while connected contribute. */
export class SessionQuality {
    private baseline?: { id: string; timestamp: number; bytes: number };
    private connected = false;
    private lastReportMs = 0;
    private latency?: { value: number; at: number };
    private connectedMs = 0;
    private videoBytes = 0;
    private latencyWeightedMs = 0;
    private latencyDurationMs = 0;

    setConnected(connected: boolean) {
        this.connected = connected;
        this.baseline = undefined;
        this.latency = undefined;
    }

    observeLatency(value: number | undefined, now: number) {
        this.latency =
            this.connected && value !== undefined && Number.isFinite(value) && value >= 0 && value <= 60_000
                ? { value, at: now }
                : undefined;
    }

    observe(id: string, timestamp: number, bytes: number, now: number) {
        if (!this.connected || !Number.isFinite(timestamp) || !Number.isSafeInteger(bytes) || bytes < 0)
            return;
        const previous = this.baseline;
        this.baseline = { id, timestamp, bytes };
        if (!previous || previous.id !== id || timestamp <= previous.timestamp || bytes < previous.bytes)
            return;
        const elapsed = timestamp - previous.timestamp;
        // A suspended tab or missing stats is uncovered time, never fabricated connected time.
        if (elapsed > 15_000) return;
        this.connectedMs += elapsed;
        this.videoBytes += bytes - previous.bytes;
        if (this.latency && now - this.latency.at <= 5_000) {
            this.latencyWeightedMs += this.latency.value * elapsed;
            this.latencyDurationMs += elapsed;
        }
    }

    report(now: number, maxBitrateKbps: number | undefined, final = false) {
        if (this.connectedMs <= 0 || (!final && (!this.connected || now - this.lastReportMs < 60_000)))
            return undefined;
        this.lastReportMs = now;
        return {
            type: 'scaleWorldSessionQuality',
            telemetryVersion: 1,
            connectedMs: Math.round(this.connectedMs),
            videoBytes: this.videoBytes,
            latencyWeightedMs: Math.round(this.latencyWeightedMs),
            latencyDurationMs: Math.round(this.latencyDurationMs),
            maxBitrateKbps:
                maxBitrateKbps !== undefined && Number.isFinite(maxBitrateKbps) && maxBitrateKbps > 0
                    ? maxBitrateKbps
                    : undefined
        };
    }
}
