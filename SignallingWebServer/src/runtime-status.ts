// Copyright Epic Games, Inc. All Rights Reserved.
import { execFile } from 'child_process';
import { promisify } from 'util';
import { Logger, SignallingServer } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';

const execFileAsync = promisify(execFile);
const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_METADATA_BASE_URL = 'http://169.254.169.254/latest/meta-data';

export interface RuntimeStatusUpdate {
    status: string;
    reason?: string;
    source?: string;
    version?: string;
    heartbeatOnly?: boolean;
}
export interface RuntimeStatusPublisher {
    publish(update: RuntimeStatusUpdate): Promise<boolean>;
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
}

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
            try {
                const { instanceId, region } = await resolveIdentity();
                const nowIso = new Date().toISOString();
                const tags = [
                    `Key=ScaleWorldRuntimeStatus,Value=${normalizeTagValue(update.status)}`,
                    `Key=ScaleWorldRuntimeStatusHeartbeatAtUtc,Value=${nowIso}`,
                    `Key=ScaleWorldRuntimeStatusSource,Value=${normalizeTagValue(update.source ?? defaultSource)}`,
                    `Key=ScaleWorldRuntimeStatusReason,Value=${normalizeTagValue(update.reason)}`,
                    `Key=ScaleWorldRuntimeStatusVersion,Value=${normalizeTagValue(update.version ?? defaultVersion)}`
                ];
                if (!update.heartbeatOnly) {
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
                log(
                    `[runtime-status] Published status='${normalizeTagValue(update.status)}'${
                        update.heartbeatOnly ? ' heartbeat' : ''
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
): void {
    if (!publisher) return;
    const log = options.logger ?? ((message: string) => Logger.info(message));
    const heartbeatMs = parseNonNegativeInteger(
        options.heartbeatMs ?? process.env.RUNTIME_STATUS_HEARTBEAT_MS,
        60_000
    );
    const source = options.source ?? 'signalling-server';
    let currentStatus: string | null = null;
    let currentReason: string | null = null;
    let heartbeatTimer: NodeJS.Timeout | null = null;

    const clearHeartbeat = (): void => {
        if (!heartbeatTimer) return;
        clearInterval(heartbeatTimer);
        heartbeatTimer = null;
    };

    const publishTransition = (status: string, reason: string): void => {
        currentStatus = status;
        currentReason = reason;
        void publisher.publish({ status, reason, source });
    };

    const publishHeartbeat = (): void => {
        if (!currentStatus) return;
        void publisher.publish({
            status: currentStatus,
            reason: currentReason ?? undefined,
            source,
            heartbeatOnly: true
        });
    };

    const startHeartbeat = (): void => {
        clearHeartbeat();
        if (heartbeatMs <= 0) return;
        heartbeatTimer = setInterval(() => {
            publishHeartbeat();
        }, heartbeatMs);
    };

    const syncFromStreamerCount = (readyReason: string, waitingReason: string): void => {
        if (server.streamerRegistry.count() > 0) {
            publishTransition('ready', readyReason);
            startHeartbeat();
            return;
        }
        publishTransition('waiting_for_streamer', waitingReason);
        startHeartbeat();
    };

    syncFromStreamerCount('streamer_present_on_startup', 'signalling_server_started');

    server.streamerRegistry.on('added', (streamerId: string) => {
        log(`[runtime-status] Streamer connected (${streamerId}).`);
        publishTransition('ready', 'streamer_connected');
        startHeartbeat();
    });

    server.streamerRegistry.on('removed', (streamerId: string) => {
        log(
            `[runtime-status] Streamer disconnected (${streamerId}). remaining=${server.streamerRegistry.count()}.`
        );
        syncFromStreamerCount('another_streamer_still_connected', 'streamer_disconnected');
    });
}
