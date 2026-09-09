// Copyright Epic Games, Inc. All Rights Reserved.
import { randomUUID } from 'node:crypto';

/** One bounded, cumulative summary per authenticated signalling connection. */
export class SessionQualityReceiver {
    private readonly connectionId = randomUUID();
    private readonly startedAt = Date.now();
    private lastAt = 0;
    private sequence = 0;
    private connectedMs = 0;
    private videoBytes = 0;
    private latencyDurationMs = 0;
    private latencyWeightedMs = 0;

    accept(input: Record<string, unknown>, now = Date.now()): Record<string, unknown> | undefined {
        if (this.lastAt && now - this.lastAt < 10_000) return;
        const counter = (key: string, max: number): number | undefined => {
            const value = input[key];
            return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= max
                ? value
                : undefined;
        };
        const connectedMs = counter('connectedMs', Math.max(0, now - this.startedAt) + 5_000);
        const videoBytes = counter('videoBytes', 1_000_000_000_000_000);
        const latencyDurationMs = counter('latencyDurationMs', connectedMs ?? 0);
        const latencyWeightedMs = counter('latencyWeightedMs', (latencyDurationMs ?? 0) * 60_000);
        const maxBitrateKbps = input['maxBitrateKbps'];
        if (
            input['telemetryVersion'] !== 1 ||
            !connectedMs ||
            videoBytes === undefined ||
            latencyDurationMs === undefined ||
            latencyWeightedMs === undefined ||
            connectedMs < this.connectedMs ||
            videoBytes < this.videoBytes ||
            latencyDurationMs < this.latencyDurationMs ||
            latencyWeightedMs < this.latencyWeightedMs ||
            (maxBitrateKbps !== undefined &&
                (typeof maxBitrateKbps !== 'number' ||
                    !Number.isFinite(maxBitrateKbps) ||
                    maxBitrateKbps <= 0 ||
                    maxBitrateKbps > 10_000_000))
        )
            return;
        this.lastAt = now;
        this.connectedMs = connectedMs;
        this.videoBytes = videoBytes;
        this.latencyDurationMs = latencyDurationMs;
        this.latencyWeightedMs = latencyWeightedMs;
        return {
            connectionId: this.connectionId,
            sequence: ++this.sequence,
            telemetryVersion: 1,
            connectedMs,
            videoBytes,
            latencyDurationMs,
            latencyWeightedMs,
            maxBitrateKbps
        };
    }
}
