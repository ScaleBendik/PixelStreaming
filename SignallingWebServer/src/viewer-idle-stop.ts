// Copyright Epic Games, Inc. All Rights Reserved.
import { execFile } from 'child_process';
import { promisify } from 'util';
import { Logger, SignallingServer } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import { RuntimeStatusPublisher } from './runtime-status';

const execFileAsync = promisify(execFile);

const DEFAULT_IDLE_GRACE_MS = 15 * 60_000;
const DEFAULT_FIRST_VIEWER_GRACE_MS = 60 * 60_000;
const DEFAULT_FIRST_VIEWER_DELAY_MS = 0;
const DEFAULT_STOP_RETRY_MS = 60_000;
const DEFAULT_IDLE_STATUS_HEARTBEAT_MS = 60_000;
const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_METADATA_BASE_URL = 'http://169.254.169.254/latest/meta-data';

export interface ViewerIdleOptions {
    enabled?: boolean;
    graceMs?: number;
    firstViewerGraceMs?: number;
    firstViewerDelayMs?: number;
    stopRetryMs?: number;
    idleStatusHeartbeatMs?: number;
    awsCliPath?: string;
    dryRun?: boolean;
    logger?: (message: string) => void;
    runtimeStatusPublisher?: RuntimeStatusPublisher | null;
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

function parseNonNegativeInteger(
    rawValue: unknown,
    fallback: number,
    label: string,
    log: (message: string) => void
): number {
    if (rawValue === undefined || rawValue === null || rawValue === '') return fallback;
    const rawValueText =
        typeof rawValue === 'string' ||
        typeof rawValue === 'number' ||
        typeof rawValue === 'boolean' ||
        typeof rawValue === 'bigint'
            ? String(rawValue)
            : Object.prototype.toString.call(rawValue);
    const parsed = Number.parseInt(rawValueText, 10);
    if (Number.isNaN(parsed) || parsed < 0) {
        log(`[idle-stop] Invalid ${label} value '${rawValueText}'. Using fallback ${fallback}.`);
        return fallback;
    }
    return parsed;
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

async function stopCurrentInstance(
    awsCliPath: string,
    dryRun: boolean,
    log: (message: string) => void
): Promise<void> {
    const token = await readImdsToken();
    const [instanceId, region] = await Promise.all([
        readImdsValue('instance-id', token),
        readImdsValue('placement/region', token)
    ]);

    if (dryRun) {
        log(`[idle-stop] DRY RUN: would stop instance ${instanceId} in region ${region}.`);
        return;
    }

    const args = ['ec2', 'stop-instances', '--region', region, '--instance-ids', instanceId];
    const { stdout, stderr } = await execFileAsync(awsCliPath, args, { windowsHide: true });
    if (stdout && stdout.trim().length > 0) log(`[idle-stop] StopInstances output: ${stdout.trim()}`);
    if (stderr && stderr.trim().length > 0) log(`[idle-stop] StopInstances stderr: ${stderr.trim()}`);
    log(`[idle-stop] StopInstances requested for ${instanceId} (${region}).`);
}

function mapStopReason(reason: string): string {
    switch (reason) {
        case 'grace-after-last-viewer':
            return 'idle_timeout';
        case 'retry-after-failure':
            return 'retry_after_stop_failure';
        case 'no-viewer-ever-connected':
            return 'no_viewer_ever_connected';
        default:
            return reason.replace(/[^a-z0-9]+/gi, '_').toLowerCase();
    }
}

export function wireViewerIdleStop(server: SignallingServer, options: ViewerIdleOptions = {}): void {
    const log = options.logger ?? ((message: string) => Logger.info(message));
    const enabled = parseBoolean(options.enabled ?? process.env.VIEWER_IDLE_STOP_ENABLED ?? true, true);
    if (!enabled) {
        log('[idle-stop] Disabled.');
        return;
    }

    const graceMs = parseNonNegativeInteger(
        options.graceMs ?? process.env.VIEWER_IDLE_GRACE_MS,
        DEFAULT_IDLE_GRACE_MS,
        'VIEWER_IDLE_GRACE_MS',
        log
    );
    const firstViewerGraceMs = parseNonNegativeInteger(
        options.firstViewerGraceMs ?? process.env.VIEWER_IDLE_FIRST_VIEWER_GRACE_MS,
        DEFAULT_FIRST_VIEWER_GRACE_MS,
        'VIEWER_IDLE_FIRST_VIEWER_GRACE_MS',
        log
    );
    const firstViewerDelayMs = parseNonNegativeInteger(
        options.firstViewerDelayMs ?? process.env.VIEWER_IDLE_FIRST_VIEWER_DELAY_MS,
        DEFAULT_FIRST_VIEWER_DELAY_MS,
        'VIEWER_IDLE_FIRST_VIEWER_DELAY_MS',
        log
    );
    const stopRetryMs = parseNonNegativeInteger(
        options.stopRetryMs ?? process.env.VIEWER_IDLE_STOP_RETRY_MS,
        DEFAULT_STOP_RETRY_MS,
        'VIEWER_IDLE_STOP_RETRY_MS',
        log
    );
    const idleStatusHeartbeatMs = parseNonNegativeInteger(
        options.idleStatusHeartbeatMs ?? process.env.VIEWER_IDLE_STATUS_HEARTBEAT_MS,
        DEFAULT_IDLE_STATUS_HEARTBEAT_MS,
        'VIEWER_IDLE_STATUS_HEARTBEAT_MS',
        log
    );
    const dryRun = parseBoolean(options.dryRun ?? process.env.VIEWER_IDLE_STOP_DRY_RUN ?? false, false);
    const awsCliPath = String(options.awsCliPath ?? process.env.VIEWER_IDLE_AWS_CLI_PATH ?? 'aws');
    const runtimeStatusPublisher = options.runtimeStatusPublisher ?? null;

    let zeroViewersTimer: NodeJS.Timeout | null = null;
    let firstViewerTimer: NodeJS.Timeout | null = null;
    let idleStatusHeartbeatTimer: NodeJS.Timeout | null = null;
    let stopInFlight = false;
    let hasSeenViewer = server.playerRegistry.count() > 0;

    const publishStatus = (
        status: string,
        reason: string,
        options: { heartbeatOnly?: boolean; preserveStatusAtUtc?: boolean } = {}
    ): void => {
        if (!runtimeStatusPublisher) return;
        void runtimeStatusPublisher.publish({
            status,
            reason,
            source: 'viewer-idle-stop',
            heartbeatOnly: options.heartbeatOnly,
            preserveStatusAtUtc: options.preserveStatusAtUtc
        });
    };

    const clearZeroTimer = (): void => {
        if (zeroViewersTimer) {
            clearTimeout(zeroViewersTimer);
            zeroViewersTimer = null;
        }
    };
    const clearFirstViewerTimer = (): void => {
        if (firstViewerTimer) {
            clearTimeout(firstViewerTimer);
            firstViewerTimer = null;
        }
    };
    const clearIdleStatusHeartbeat = (): void => {
        if (!idleStatusHeartbeatTimer) return;
        clearInterval(idleStatusHeartbeatTimer);
        idleStatusHeartbeatTimer = null;
    };
    const startIdleStatusHeartbeat = (reason: string): void => {
        clearIdleStatusHeartbeat();
        if (idleStatusHeartbeatMs <= 0 || !runtimeStatusPublisher) {
            return;
        }
        idleStatusHeartbeatTimer = setInterval(() => {
            publishStatus('idle_shutdown_pending', reason, { heartbeatOnly: true });
        }, idleStatusHeartbeatMs);
    };

    const scheduleStop = (reason: string, delayMs: number): void => {
        clearZeroTimer();
        const mappedReason = mapStopReason(reason);
        publishStatus('idle_shutdown_pending', mappedReason);
        startIdleStatusHeartbeat(mappedReason);
        zeroViewersTimer = setTimeout(() => {
            void requestStop(reason);
        }, delayMs);
        log(`[idle-stop] Scheduled stop in ${delayMs} ms (reason=${reason}).`);
    };

    const scheduleRetryIfStillIdle = (): void => {
        if (stopRetryMs <= 0 || server.playerRegistry.count() > 0) return;
        publishStatus('idle_shutdown_pending', 'retry_after_stop_failure');
        scheduleStop('retry-after-failure', stopRetryMs);
    };

    const requestStop = async (reason: string): Promise<void> => {
        if (stopInFlight) return;
        clearIdleStatusHeartbeat();
        if (server.playerRegistry.count() > 0) {
            log('[idle-stop] Stop request aborted because viewers are connected.');
            publishStatus('ready', 'viewer_connected_during_idle_shutdown', { preserveStatusAtUtc: true });
            return;
        }

        stopInFlight = true;
        try {
            publishStatus('stopping', mapStopReason(reason));
            log(`[idle-stop] Triggering stop (reason=${reason}).`);
            await stopCurrentInstance(awsCliPath, dryRun, log);
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            log(`[idle-stop] Stop request failed: ${message}`);
            publishStatus('idle_shutdown_pending', 'stop_request_failed');
            scheduleRetryIfStillIdle();
        } finally {
            stopInFlight = false;
        }
    };

    const onViewerAdded = (): void => {
        hasSeenViewer = true;
        clearZeroTimer();
        clearFirstViewerTimer();
        clearIdleStatusHeartbeat();
        publishStatus('ready', 'viewer_connected', { preserveStatusAtUtc: true });
        log(`[idle-stop] Viewer connected (count=${server.playerRegistry.count()}).`);
    };

    const onViewerRemoved = (removedPlayerId?: string): void => {
        const rawCount = server.playerRegistry.count();
        const removedEntryStillPresent =
            typeof removedPlayerId === 'string' && removedPlayerId.length > 0
                ? server.playerRegistry.has(removedPlayerId)
                : false;
        const effectiveCount = Math.max(0, rawCount - (removedEntryStillPresent ? 1 : 0));
        log(
            `[idle-stop] Viewer disconnected (count=${effectiveCount}, rawCount=${rawCount}, removedEntryStillPresent=${removedEntryStillPresent}).`
        );
        if (effectiveCount === 0) scheduleStop('grace-after-last-viewer', graceMs);
    };

    server.playerRegistry.on('added', onViewerAdded);
    server.playerRegistry.on('removed', onViewerRemoved);
    log('[idle-stop] Wired to player registry events.');

    if (!hasSeenViewer && firstViewerGraceMs > 0) {
        firstViewerTimer = setTimeout(() => {
            firstViewerTimer = null;
            if (hasSeenViewer || server.playerRegistry.count() > 0) return;
            void requestStop('no-viewer-ever-connected');
        }, firstViewerDelayMs + firstViewerGraceMs);

        log(
            `[idle-stop] First-viewer window active (delay=${firstViewerDelayMs} ms, grace=${firstViewerGraceMs} ms).`
        );
    }
}
