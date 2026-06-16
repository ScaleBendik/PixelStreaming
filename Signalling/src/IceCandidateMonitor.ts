// Copyright Epic Games, Inc. All Rights Reserved.
import { BaseMessage, Messages } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.7';
import { IPlayer } from './PlayerRegistry';
import { IStreamer } from './StreamerRegistry';
import { Logger } from './Logger';

type CandidateEndpoint = 'player' | 'streamer';

interface ParsedIceCandidate {
    type: string;
    protocol?: string;
    relayProtocol?: string;
    tcpType?: string;
    component?: string;
}

interface EndpointStats {
    total: number;
    types: Map<string, number>;
    protocols: Map<string, number>;
    relayProtocols: Map<string, number>;
    tcpTypes: Map<string, number>;
    components: Map<string, number>;
}

interface CandidateRecord {
    playerId: string;
    streamerId?: string;
    sessionId?: string;
    sessionRequestId?: string;
    firstSeenAtMs: number;
    lastSeenAtMs: number;
    player: EndpointStats;
    streamer: EndpointStats;
    summaryTimer: NodeJS.Timeout | null;
    summaryEmitted: boolean;
    warningEmitted: boolean;
}

export interface IceCandidateMonitorOptions {
    enabled?: unknown;
    summaryDelayMs?: unknown;
    maxTrackedPlayers?: unknown;
}

const DEFAULT_SUMMARY_DELAY_MS = 5000;
const DEFAULT_MAX_TRACKED_PLAYERS = 256;
const UNKNOWN_VALUE = 'unknown';

function formatScalarValue(value: unknown): string | undefined {
    if (
        typeof value === 'string' ||
        typeof value === 'number' ||
        typeof value === 'boolean' ||
        typeof value === 'bigint'
    ) {
        return String(value);
    }

    return undefined;
}

function parseBoolean(value: unknown, fallback: boolean): boolean {
    if (typeof value === 'boolean') {
        return value;
    }

    if (value === undefined || value === null || value === '') {
        return fallback;
    }

    const normalized = formatScalarValue(value)?.trim().toLowerCase();
    if (!normalized) {
        return fallback;
    }

    if (['1', 'true', 'yes', 'on'].indexOf(normalized) >= 0) {
        return true;
    }

    if (['0', 'false', 'no', 'off'].indexOf(normalized) >= 0) {
        return false;
    }

    return fallback;
}

function parseNonNegativeInteger(value: unknown, fallback: number): number {
    if (value === undefined || value === null || value === '') {
        return fallback;
    }

    const normalized = formatScalarValue(value);
    if (!normalized) {
        return fallback;
    }

    const parsed = Number.parseInt(normalized, 10);
    if (Number.isNaN(parsed) || parsed < 0) {
        return fallback;
    }

    return parsed;
}

function normalizeOptionalText(value: unknown): string | undefined {
    return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined;
}

function createEndpointStats(): EndpointStats {
    return {
        total: 0,
        types: new Map<string, number>(),
        protocols: new Map<string, number>(),
        relayProtocols: new Map<string, number>(),
        tcpTypes: new Map<string, number>(),
        components: new Map<string, number>()
    };
}

function incrementCount(counts: Map<string, number>, rawValue: string | undefined): void {
    const value = rawValue && rawValue.length > 0 ? rawValue : UNKNOWN_VALUE;
    counts.set(value, (counts.get(value) ?? 0) + 1);
}

function recordCandidate(stats: EndpointStats, candidate: ParsedIceCandidate): void {
    stats.total++;
    incrementCount(stats.types, candidate.type);
    incrementCount(stats.protocols, candidate.protocol);
    if (candidate.relayProtocol) {
        incrementCount(stats.relayProtocols, candidate.relayProtocol);
    }
    if (candidate.tcpType) {
        incrementCount(stats.tcpTypes, candidate.tcpType);
    }
    if (candidate.component) {
        incrementCount(stats.components, candidate.component);
    }
}

function formatCounts(counts: Map<string, number>): string {
    if (counts.size === 0) {
        return 'none';
    }

    return Array.from(counts.entries())
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, value]) => `${key}:${value}`)
        .join(',');
}

function hasOnlyHostCandidates(stats: EndpointStats): boolean {
    return (
        stats.total > 0 &&
        stats.types.size === 1 &&
        stats.types.has('host') &&
        !stats.types.has('srflx') &&
        !stats.types.has('relay')
    );
}

function readCandidateText(message: BaseMessage): string | undefined {
    const iceCandidateMessage = message as Messages.iceCandidate;
    return normalizeOptionalText(iceCandidateMessage.candidate?.candidate);
}

export function parseIceCandidate(candidateText: string): ParsedIceCandidate | null {
    const trimmed = candidateText.trim();
    if (!trimmed) {
        return null;
    }

    const tokens = trimmed.split(/\s+/);
    const typeMarkerIndex = tokens.findIndex((token) => token.toLowerCase() === 'typ');
    if (typeMarkerIndex < 0 || typeMarkerIndex + 1 >= tokens.length) {
        return null;
    }

    const protocol = normalizeOptionalText(tokens[2]?.toLowerCase());
    const candidateType = normalizeOptionalText(tokens[typeMarkerIndex + 1]?.toLowerCase()) ?? UNKNOWN_VALUE;
    const tcpTypeMarkerIndex = tokens.findIndex((token) => token.toLowerCase() === 'tcptype');
    const tcpType =
        tcpTypeMarkerIndex >= 0 && tcpTypeMarkerIndex + 1 < tokens.length
            ? normalizeOptionalText(tokens[tcpTypeMarkerIndex + 1]?.toLowerCase())
            : undefined;

    return {
        type: candidateType,
        protocol,
        relayProtocol: candidateType === 'relay' ? protocol : undefined,
        tcpType,
        component: normalizeOptionalText(tokens[1])
    };
}

function readPlayerSessionValue(player: IPlayer | undefined, fieldName: string): string | undefined {
    if (!player) {
        return undefined;
    }

    const sessionPlayer = player as IPlayer & Record<string, unknown>;
    return normalizeOptionalText(sessionPlayer[fieldName]);
}

export class IceCandidateMonitor {
    private readonly enabled: boolean;
    private readonly summaryDelayMs: number;
    private readonly maxTrackedPlayers: number;
    private readonly records = new Map<string, CandidateRecord>();

    constructor(options: IceCandidateMonitorOptions = {}) {
        this.enabled = parseBoolean(options.enabled, false);
        this.summaryDelayMs = parseNonNegativeInteger(options.summaryDelayMs, DEFAULT_SUMMARY_DELAY_MS);
        this.maxTrackedPlayers = Math.max(
            1,
            parseNonNegativeInteger(options.maxTrackedPlayers, DEFAULT_MAX_TRACKED_PLAYERS)
        );

        if (this.enabled) {
            Logger.info(
                `[ice-candidate-monitor] Enabled (summaryDelayMs=${this.summaryDelayMs}, maxTrackedPlayers=${this.maxTrackedPlayers}).`
            );
        }
    }

    recordPlayerCandidate(player: IPlayer, streamer: IStreamer | null, message: BaseMessage): void {
        if (!this.enabled) {
            return;
        }

        try {
            this.recordCandidate('player', player.playerId, player, streamer, message);
        } catch (error) {
            Logger.warn(
                `[ice-candidate-monitor] Failed to record player ICE candidate: ${formatError(error)}.`
            );
        }
    }

    recordStreamerCandidate(streamer: IStreamer, player: IPlayer | undefined, message: BaseMessage): void {
        if (!this.enabled) {
            return;
        }

        const playerId = normalizeOptionalText(message.playerId) ?? player?.playerId;
        if (!playerId) {
            return;
        }

        try {
            this.recordCandidate('streamer', playerId, player, streamer, message);
        } catch (error) {
            Logger.warn(
                `[ice-candidate-monitor] Failed to record streamer ICE candidate: ${formatError(error)}.`
            );
        }
    }

    flushPlayer(playerId: string | undefined, reason: string): void {
        if (!this.enabled || !playerId) {
            return;
        }

        const record = this.records.get(playerId);
        if (!record) {
            return;
        }

        this.emitSummary(record, reason);
        this.deleteRecord(playerId);
    }

    private recordCandidate(
        endpoint: CandidateEndpoint,
        playerId: string,
        player: IPlayer | undefined,
        streamer: IStreamer | null | undefined,
        message: BaseMessage
    ): void {
        if (!playerId) {
            return;
        }

        const candidateText = readCandidateText(message);
        if (!candidateText) {
            return;
        }

        const candidate = parseIceCandidate(candidateText);
        if (!candidate) {
            return;
        }

        const nowMs = Date.now();
        const record = this.getOrCreateRecord(playerId, nowMs);
        record.lastSeenAtMs = nowMs;
        record.streamerId = streamer?.streamerId || record.streamerId;
        record.sessionId = readPlayerSessionValue(player, 'scaleWorldSessionId') ?? record.sessionId;
        record.sessionRequestId =
            readPlayerSessionValue(player, 'scaleWorldSessionRequestId') ?? record.sessionRequestId;

        recordCandidate(endpoint === 'player' ? record.player : record.streamer, candidate);

        if (!record.summaryEmitted) {
            this.scheduleSummary(record);
        }
    }

    private getOrCreateRecord(playerId: string, nowMs: number): CandidateRecord {
        const existing = this.records.get(playerId);
        if (existing) {
            return existing;
        }

        if (this.records.size >= this.maxTrackedPlayers) {
            const oldestPlayerId = this.records.keys().next().value;
            if (oldestPlayerId) {
                this.flushPlayer(oldestPlayerId, 'evicted');
            }
        }

        const record: CandidateRecord = {
            playerId,
            firstSeenAtMs: nowMs,
            lastSeenAtMs: nowMs,
            player: createEndpointStats(),
            streamer: createEndpointStats(),
            summaryTimer: null,
            summaryEmitted: false,
            warningEmitted: false
        };
        this.records.set(playerId, record);
        return record;
    }

    private scheduleSummary(record: CandidateRecord): void {
        if (record.summaryTimer) {
            clearTimeout(record.summaryTimer);
        }

        record.summaryTimer = setTimeout(() => {
            record.summaryTimer = null;
            this.emitSummary(record, 'quiet');
        }, this.summaryDelayMs);
        record.summaryTimer.unref();
    }

    private emitSummary(record: CandidateRecord, reason: string): void {
        if (record.summaryTimer) {
            clearTimeout(record.summaryTimer);
            record.summaryTimer = null;
        }

        if (record.summaryEmitted) {
            return;
        }

        record.summaryEmitted = true;
        const durationMs = Math.max(0, record.lastSeenAtMs - record.firstSeenAtMs);
        Logger.info(
            `[ice-candidate-summary] playerId=${record.playerId} streamerId=${record.streamerId ?? 'unknown'} sessionRequestId=${record.sessionRequestId ?? 'none'} sessionId=${record.sessionId ?? 'none'} reason=${reason} durationMs=${durationMs} playerTotal=${record.player.total} playerTypes=${formatCounts(record.player.types)} playerProtocols=${formatCounts(record.player.protocols)} playerRelayProtocols=${formatCounts(record.player.relayProtocols)} streamerTotal=${record.streamer.total} streamerTypes=${formatCounts(record.streamer.types)} streamerProtocols=${formatCounts(record.streamer.protocols)} streamerRelayProtocols=${formatCounts(record.streamer.relayProtocols)}`
        );

        if (!record.warningEmitted && hasOnlyHostCandidates(record.streamer)) {
            record.warningEmitted = true;
            Logger.warn(
                `[ice-candidate-warning] reason=streamer_host_only action=observe playerId=${record.playerId} streamerId=${record.streamerId ?? 'unknown'} sessionRequestId=${record.sessionRequestId ?? 'none'} playerTypes=${formatCounts(record.player.types)} streamerTypes=${formatCounts(record.streamer.types)}`
            );
        }
    }

    private deleteRecord(playerId: string): void {
        const record = this.records.get(playerId);
        if (record?.summaryTimer) {
            clearTimeout(record.summaryTimer);
            record.summaryTimer = null;
        }

        this.records.delete(playerId);
    }
}

function formatError(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
}
