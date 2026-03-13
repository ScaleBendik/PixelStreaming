// Copyright Epic Games, Inc. All Rights Reserved.
import fs from 'fs';
import path from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { Logger, SignallingServer } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import { Messages } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.7';

const execFileAsync = promisify(execFile);
const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_METADATA_BASE_URL = 'http://169.254.169.254/latest/meta-data';

export interface RuntimeStatusUpdate {
    status: string;
    reason?: string;
    source?: string;
    version?: string;
    heartbeatOnly?: boolean;
    preserveStatusAtUtc?: boolean;
}
export interface RuntimeStatusPublisher {
    publish(update: RuntimeStatusUpdate): Promise<boolean>;
}
export interface SignallingRuntimeStatusController {
    restoreDerivedStatus(options?: { preserveStatusAtUtc?: boolean }): void;
}
export interface RuntimeStatusPublisherOptions {
    enabled?: boolean;
    awsCliPath?: string;
    source?: string;
    version?: string;
    logger?: (message: string) => void;
}
export interface SignallingRuntimeStatusOptions {
    logger?: (message: string) => void;
    source?: string;
    heartbeatMs?: number;
    readySoakMs?: number;
    streamerHealthEnabled?: boolean;
    streamerHealthPath?: string;
    streamerPingFreshMs?: number;
    streamerHealthWriteMs?: number;
}

interface LocalStreamerHealthSnapshot {
    status: string;
    reason: string;
    healthy: boolean;
    streamerCount: number;
    streamerId?: string;
    statusAtUtc?: string;
    lastStreamerPingAtUtc?: string;
    lastHealthyAtUtc?: string;
    updatedAtUtc: string;
    pingFreshMs: number;
}

const RUNTIME_STATUS_WAITING_FOR_STREAMER = 'waiting_for_streamer';
const RUNTIME_STATUS_WARMING_UP_ASSETS = 'warming_up_assets';
const RUNTIME_STATUS_STABILIZING_STREAM = 'stabilizing_stream';
const RUNTIME_STATUS_READY = 'ready';

function parseBoolean(rawValue: unknown, fallback: boolean): boolean {
    if (typeof rawValue === 'boolean') return rawValue;
    if (typeof rawValue !== 'string') return fallback;
    switch (rawValue.trim().toLowerCase()) {
        case '1':
        case 'true':
        case 'yes':
        case 'on':
            return true;
        case '0':
        case 'false':
        case 'no':
        case 'off':
            return false;
        default:
            return fallback;
    }
}

function parseNonNegativeInteger(rawValue: unknown, fallback: number): number {
    if (rawValue === undefined || rawValue === null || rawValue === '') return fallback;
    const rawValueText =
        typeof rawValue === 'string' ||
        typeof rawValue === 'number' ||
        typeof rawValue === 'boolean' ||
        typeof rawValue === 'bigint'
            ? String(rawValue)
            : '';
    const parsed = Number.parseInt(rawValueText, 10);
    return Number.isNaN(parsed) || parsed < 0 ? fallback : parsed;
}

function normalizeTagValue(value: unknown): string {
    if (value === undefined || value === null) return '';

    let text = '';
    switch (typeof value) {
        case 'string':
            text = value;
            break;
        case 'number':
        case 'boolean':
        case 'bigint':
            text = String(value);
            break;
        default:
            text = '';
            break;
    }

    const normalized = text.replace(/\s+/g, ' ').trim();
    return normalized.length <= 256 ? normalized : normalized.slice(0, 256);
}

async function readImdsToken(): Promise<string> {
    const response = await fetch(IMDS_TOKEN_URL, {
        method: 'PUT',
        headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '21600' }
    });
    if (!response.ok) throw new Error(`IMDSv2 token request failed with status ${response.status}.`);
    return response.text();
}

async function readImdsValue(pathSuffix: string, token: string): Promise<string> {
    const response = await fetch(`${IMDS_METADATA_BASE_URL}/${pathSuffix}`, {
        headers: { 'X-aws-ec2-metadata-token': token }
    });
    if (!response.ok) throw new Error(`IMDS read for '${pathSuffix}' failed with status ${response.status}.`);
    return response.text();
}

export function createRuntimeStatusPublisher(
    options: RuntimeStatusPublisherOptions = {}
): RuntimeStatusPublisher | null {
    const log = options.logger ?? ((message: string) => Logger.info(message));
    const enabled = parseBoolean(options.enabled ?? process.env.RUNTIME_STATUS_ENABLED ?? true, true);
    if (!enabled) {
        log('[runtime-status] Disabled.');
        return null;
    }

    const awsCliPath = String(options.awsCliPath ?? process.env.RUNTIME_STATUS_AWS_CLI_PATH ?? 'aws');
    const defaultSource = normalizeTagValue(
        options.source ?? process.env.RUNTIME_STATUS_SOURCE ?? 'signalling-server'
    );
    const defaultVersion = normalizeTagValue(options.version ?? process.env.RUNTIME_STATUS_VERSION ?? '');
    let identityPromise: Promise<{ instanceId: string; region: string }> | null = null;
    let lastPublishedStatus: string | null = null;

    const resolveIdentity = async (): Promise<{ instanceId: string; region: string }> => {
        if (!identityPromise) {
            identityPromise = (async () => {
                const token = await readImdsToken();
                const [instanceId, region] = await Promise.all([
                    readImdsValue('instance-id', token),
                    readImdsValue('placement/region', token)
                ]);
                return { instanceId: instanceId.trim(), region: region.trim() };
            })().catch((error) => {
                identityPromise = null;
                throw error;
            });
        }

        return identityPromise;
    };

    return {
        async publish(update: RuntimeStatusUpdate): Promise<boolean> {
            const normalizedStatus = normalizeTagValue(update.status);
            const heartbeatOnly = update.heartbeatOnly === true;
            const preserveStatusAtUtc = update.preserveStatusAtUtc === true;
            const preservesCurrentStatusTimestamp = preserveStatusAtUtc && !heartbeatOnly;

            if (heartbeatOnly && lastPublishedStatus && normalizedStatus !== lastPublishedStatus) {
                log(
                    `[runtime-status] Ignoring stale heartbeat for status='${normalizedStatus}' while current status='${lastPublishedStatus}'.`
                );
                return false;
            }

            try {
                const { instanceId, region } = await resolveIdentity();
                const nowIso = new Date().toISOString();
                const tags = [
                    `Key=ScaleWorldRuntimeStatus,Value=${normalizedStatus}`,
                    `Key=ScaleWorldRuntimeStatusHeartbeatAtUtc,Value=${nowIso}`,
                    `Key=ScaleWorldRuntimeStatusSource,Value=${normalizeTagValue(update.source ?? defaultSource)}`,
                    `Key=ScaleWorldRuntimeStatusReason,Value=${normalizeTagValue(update.reason)}`,
                    `Key=ScaleWorldRuntimeStatusVersion,Value=${normalizeTagValue(update.version ?? defaultVersion)}`
                ];
                if (!heartbeatOnly && !preservesCurrentStatusTimestamp) {
                    tags.splice(1, 0, `Key=ScaleWorldRuntimeStatusAtUtc,Value=${nowIso}`);
                }
                const args = [
                    'ec2',
                    'create-tags',
                    '--region',
                    region,
                    '--resources',
                    instanceId,
                    '--tags',
                    ...tags
                ];
                await execFileAsync(awsCliPath, args, { windowsHide: true });
                if (!heartbeatOnly || preservesCurrentStatusTimestamp) {
                    lastPublishedStatus = normalizedStatus;
                }
                log(
                    `[runtime-status] Published status='${normalizedStatus}'${
                        heartbeatOnly
                            ? ' heartbeat'
                            : preservesCurrentStatusTimestamp
                              ? ' (preserved status timestamp)'
                              : ''
                    } for ${instanceId} (${region}).`
                );
                return true;
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                log(`[runtime-status] Failed to publish status '${update.status}': ${message}`);
                return false;
            }
        }
    };
}

export function wireSignallingRuntimeStatus(
    server: SignallingServer,
    publisher: RuntimeStatusPublisher | null,
    options: SignallingRuntimeStatusOptions = {}
): SignallingRuntimeStatusController {
    const log = options.logger ?? ((message: string) => Logger.info(message));
    const heartbeatMs = parseNonNegativeInteger(
        options.heartbeatMs ?? process.env.RUNTIME_STATUS_HEARTBEAT_MS,
        60_000
    );
    const readySoakMs = parseNonNegativeInteger(
        options.readySoakMs ?? process.env.RUNTIME_STATUS_READY_SOAK_MS,
        45_000
    );
    const source = options.source ?? 'signalling-server';
    const defaultStreamerHealthPath = path.resolve(__dirname, '..', 'state', 'streamer-health.json');
    const streamerHealthEnabled = parseBoolean(
        options.streamerHealthEnabled ?? process.env.RUNTIME_STATUS_STREAMER_HEALTH_ENABLED ?? true,
        true
    );
    const streamerPingFreshMs = parseNonNegativeInteger(
        options.streamerPingFreshMs ?? process.env.RUNTIME_STATUS_STREAMER_PING_FRESH_MS,
        75_000
    );
    const streamerHealthWriteMs = parseNonNegativeInteger(
        options.streamerHealthWriteMs ?? process.env.RUNTIME_STATUS_STREAMER_HEALTH_WRITE_MS,
        5_000
    );
    const streamerHealthPath = String(
        options.streamerHealthPath ??
            process.env.RUNTIME_STATUS_STREAMER_HEALTH_PATH ??
            defaultStreamerHealthPath
    );
    let currentStatus: string | null = null;
    let currentReason: string | null = null;
    let heartbeatTimer: NodeJS.Timeout | null = null;
    let streamerHealthTimer: NodeJS.Timeout | null = null;
    let lastStatusAtUtc: string | null = null;
    let lastStreamerPingAtMs: number | null = null;
    let lastHealthyAtMs: number | null = null;
    let lastStreamerId: string | null = null;
    let lastStreamerHealthWriteFailure: string | null = null;
    let readySoakStartedAtMs: number | null = null;
    let readySoakTimer: NodeJS.Timeout | null = null;
    const attachedStreamers = new WeakSet<object>();

    const clearHeartbeat = (): void => {
        if (!heartbeatTimer) return;
        clearInterval(heartbeatTimer);
        heartbeatTimer = null;
    };

    const clearStreamerHealthTimer = (): void => {
        if (!streamerHealthTimer) return;
        clearInterval(streamerHealthTimer);
        streamerHealthTimer = null;
    };
    const clearReadySoakTimer = (): void => {
        if (!readySoakTimer) return;
        clearTimeout(readySoakTimer);
        readySoakTimer = null;
    };
    const resetReadySoak = (): void => {
        readySoakStartedAtMs = null;
        clearReadySoakTimer();
    };

    const getPlayerVisibleStreamers = () =>
        server.streamerRegistry.streamers.filter((streamer) => streamer.streaming);

    const writeStreamerHealthSnapshot = (): void => {
        if (!streamerHealthEnabled) return;

        const nowMs = Date.now();
        const streamerCount = server.streamerRegistry.count();
        const playerVisibleStreamerCount = getPlayerVisibleStreamers().length;
        let reason = currentReason ?? 'runtime_status_unavailable';
        let healthy = false;

        if (currentStatus === RUNTIME_STATUS_READY) {
            if (playerVisibleStreamerCount > 0) {
                healthy = true;
                reason = currentReason ?? 'stream_player_visible';
                lastHealthyAtMs = nowMs;
            } else if (lastStreamerPingAtMs !== null && nowMs - lastStreamerPingAtMs > streamerPingFreshMs) {
                reason = 'streamer_ping_stale';
            } else {
                reason = 'streamer_not_player_visible';
            }
        } else if (currentStatus === RUNTIME_STATUS_STABILIZING_STREAM) {
            if (playerVisibleStreamerCount > 0) {
                healthy = true;
                reason = currentReason ?? 'verifying_stream_stability';
                lastHealthyAtMs = nowMs;
            } else {
                reason = currentReason ?? 'streamer_not_player_visible';
            }
        } else if (currentStatus === RUNTIME_STATUS_WARMING_UP_ASSETS) {
            reason = currentReason ?? 'initial_unreal_asset_warmup';
        } else if (currentStatus === RUNTIME_STATUS_WAITING_FOR_STREAMER) {
            reason = 'waiting_for_streamer';
        }

        const snapshot: LocalStreamerHealthSnapshot = {
            status: currentStatus ?? 'unknown',
            reason,
            healthy,
            streamerCount,
            updatedAtUtc: new Date(nowMs).toISOString(),
            pingFreshMs: streamerPingFreshMs
        };

        if (lastStreamerId) snapshot.streamerId = lastStreamerId;
        if (lastStatusAtUtc) snapshot.statusAtUtc = lastStatusAtUtc;
        if (lastStreamerPingAtMs !== null) {
            snapshot.lastStreamerPingAtUtc = new Date(lastStreamerPingAtMs).toISOString();
        }
        if (lastHealthyAtMs !== null) {
            snapshot.lastHealthyAtUtc = new Date(lastHealthyAtMs).toISOString();
        }

        try {
            fs.mkdirSync(path.dirname(streamerHealthPath), { recursive: true });
            fs.writeFileSync(streamerHealthPath, JSON.stringify(snapshot, null, 2), 'utf8');
            lastStreamerHealthWriteFailure = null;
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            if (message !== lastStreamerHealthWriteFailure) {
                log(
                    `[runtime-status] Failed to write streamer health file '${streamerHealthPath}': ${message}`
                );
                lastStreamerHealthWriteFailure = message;
            }
        }
    };

    const publishTransition = (
        status: string,
        reason: string,
        transitionOptions: { force?: boolean; preserveStatusAtUtc?: boolean } = {}
    ): void => {
        const statusChanged = currentStatus !== status || currentReason !== reason;
        const shouldPreserveStatusAtUtc = transitionOptions.preserveStatusAtUtc === true && !statusChanged;
        currentStatus = status;
        currentReason = reason;
        if (statusChanged) {
            lastStatusAtUtc = new Date().toISOString();
        }
        if (publisher && (statusChanged || transitionOptions.force || shouldPreserveStatusAtUtc)) {
            void publisher.publish({
                status,
                reason,
                source,
                preserveStatusAtUtc: shouldPreserveStatusAtUtc
            });
        }
        writeStreamerHealthSnapshot();
    };

    const scheduleReadySoakEvaluation = (remainingMs: number): void => {
        clearReadySoakTimer();
        if (remainingMs <= 0) return;
        readySoakTimer = setTimeout(() => {
            readySoakTimer = null;
            evaluateDerivedStatus({ force: true });
        }, remainingMs);
    };

    const evaluateDerivedStatus = (
        transitionOptions: { force?: boolean; preserveStatusAtUtc?: boolean } = {}
    ): void => {
        const nowMs = Date.now();
        const streamers = server.streamerRegistry.streamers;
        if (streamers.length === 0) {
            lastStreamerPingAtMs = null;
            lastStreamerId = null;
            resetReadySoak();
            publishTransition(
                RUNTIME_STATUS_WAITING_FOR_STREAMER,
                'signalling_server_started',
                transitionOptions
            );
            startHeartbeat();
            return;
        }

        const playerVisibleStreamers = getPlayerVisibleStreamers();
        if (playerVisibleStreamers.length === 0) {
            lastStreamerPingAtMs = null;
            lastStreamerId = null;
            resetReadySoak();
            publishTransition(
                RUNTIME_STATUS_WARMING_UP_ASSETS,
                'initial_unreal_asset_warmup',
                transitionOptions
            );
            startHeartbeat();
            return;
        }

        const visibleStreamerIds = new Set(
            playerVisibleStreamers.map((streamer) => streamer.streamerId).filter(Boolean)
        );

        if (lastStreamerId && !visibleStreamerIds.has(lastStreamerId)) {
            lastStreamerPingAtMs = null;
            lastStreamerId = null;
        }

        if (currentStatus === RUNTIME_STATUS_READY) {
            resetReadySoak();
            lastHealthyAtMs = nowMs;
            writeStreamerHealthSnapshot();
            startHeartbeat();
            return;
        }

        if (readySoakMs > 0) {
            if (readySoakStartedAtMs === null) {
                readySoakStartedAtMs = nowMs;
            }

            const remainingReadySoakMs = readySoakMs - Math.max(0, nowMs - readySoakStartedAtMs);
            if (remainingReadySoakMs > 0) {
                scheduleReadySoakEvaluation(remainingReadySoakMs);
                publishTransition(
                    RUNTIME_STATUS_STABILIZING_STREAM,
                    'verifying_stream_stability',
                    transitionOptions
                );
                startHeartbeat();
                return;
            }
        }

        resetReadySoak();
        lastHealthyAtMs = nowMs;
        publishTransition(RUNTIME_STATUS_READY, 'stream_stable', transitionOptions);
        startHeartbeat();
    };

    const markStreamerPing = (streamerId: string): void => {
        lastStreamerPingAtMs = Date.now();
        lastStreamerId = streamerId;
        evaluateDerivedStatus();
    };

    const attachStreamerHealthListeners = (streamerId: string): void => {
        const streamer = server.streamerRegistry.find(streamerId);
        if (!streamer || attachedStreamers.has(streamer)) return;

        attachedStreamers.add(streamer);
        const attachedStreamerId = streamerId;
        streamer.protocol.on(Messages.endpointId.typeName, () => {
            evaluateDerivedStatus({ force: true });
        });
        streamer.protocol.on(Messages.ping.typeName, () => {
            if (streamer.streaming) {
                markStreamerPing(streamer.streamerId || attachedStreamerId);
            } else {
                evaluateDerivedStatus({ force: true });
            }
        });
        streamer.on('disconnect', () => {
            if (
                lastStreamerId &&
                (lastStreamerId === streamer.streamerId || lastStreamerId === attachedStreamerId)
            ) {
                lastStreamerPingAtMs = null;
                lastStreamerId = null;
            }
            evaluateDerivedStatus({ force: true });
        });
        streamer.on('id_changed', (newId: string) => {
            if (
                lastStreamerId &&
                (lastStreamerId === attachedStreamerId || lastStreamerId === streamer.streamerId)
            ) {
                lastStreamerId = newId;
            }
            evaluateDerivedStatus({ force: true });
        });
    };

    const publishHeartbeat = (): void => {
        if (!currentStatus) return;
        if (publisher) {
            void publisher.publish({
                status: currentStatus,
                reason: currentReason ?? undefined,
                source,
                heartbeatOnly: true
            });
        }
        writeStreamerHealthSnapshot();
    };

    const startHeartbeat = (): void => {
        clearHeartbeat();
        if (heartbeatMs <= 0) return;
        heartbeatTimer = setInterval(() => {
            publishHeartbeat();
        }, heartbeatMs);
    };

    const startStreamerHealthTimer = (): void => {
        clearStreamerHealthTimer();
        if (!streamerHealthEnabled || streamerHealthWriteMs <= 0) return;
        streamerHealthTimer = setInterval(() => {
            writeStreamerHealthSnapshot();
        }, streamerHealthWriteMs);
    };

    evaluateDerivedStatus({ force: true });
    startStreamerHealthTimer();

    server.streamerRegistry.streamers.forEach((streamer) => {
        attachStreamerHealthListeners(streamer.streamerId);
    });

    server.streamerRegistry.on('added', (streamerId: string) => {
        log(`[runtime-status] Streamer connected (${streamerId}).`);
        attachStreamerHealthListeners(streamerId);
        evaluateDerivedStatus({ force: true });
    });

    server.streamerRegistry.on('removed', (streamerId: string) => {
        log(
            `[runtime-status] Streamer disconnected (${streamerId}). remaining=${server.streamerRegistry.count()}.`
        );
        evaluateDerivedStatus({ force: true });
    });

    return {
        restoreDerivedStatus(restoreOptions = {}) {
            evaluateDerivedStatus({
                force: true,
                preserveStatusAtUtc: restoreOptions.preserveStatusAtUtc === true
            });
        }
    };
}
