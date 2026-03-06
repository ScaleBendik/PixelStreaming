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
                const args = [
                    'ec2',
                    'create-tags',
                    '--region',
                    region,
                    '--resources',
                    instanceId,
                    '--tags',
                    `Key=ScaleWorldRuntimeStatus,Value=${normalizeTagValue(update.status)}`,
                    `Key=ScaleWorldRuntimeStatusAtUtc,Value=${new Date().toISOString()}`,
                    `Key=ScaleWorldRuntimeStatusSource,Value=${normalizeTagValue(update.source ?? defaultSource)}`,
                    `Key=ScaleWorldRuntimeStatusReason,Value=${normalizeTagValue(update.reason)}`,
                    `Key=ScaleWorldRuntimeStatusVersion,Value=${normalizeTagValue(update.version ?? defaultVersion)}`
                ];
                await execFileAsync(awsCliPath, args, { windowsHide: true });
                log(
                    `[runtime-status] Published status='${normalizeTagValue(update.status)}' for ${instanceId} (${region}).`
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
    const publish = (status: string, reason: string): void => {
        void publisher.publish({ status, reason, source: options.source ?? 'signalling-server' });
    };
    const syncFromStreamerCount = (readyReason: string, waitingReason: string): void => {
        if (server.streamerRegistry.count() > 0) {
            publish('ready', readyReason);
            return;
        }
        publish('waiting_for_streamer', waitingReason);
    };

    syncFromStreamerCount('streamer_present_on_startup', 'signalling_server_started');

    server.streamerRegistry.on('added', (streamerId: string) => {
        log(`[runtime-status] Streamer connected (${streamerId}).`);
        publish('ready', 'streamer_connected');
    });

    server.streamerRegistry.on('removed', (streamerId: string) => {
        log(
            `[runtime-status] Streamer disconnected (${streamerId}). remaining=${server.streamerRegistry.count()}.`
        );
        syncFromStreamerCount('another_streamer_still_connected', 'streamer_disconnected');
    });
}
