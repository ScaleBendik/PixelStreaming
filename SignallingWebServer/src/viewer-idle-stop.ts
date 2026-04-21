// Copyright Epic Games, Inc. All Rights Reserved.
import { execFile, spawn } from 'child_process';
import { randomUUID } from 'crypto';
import fs from 'fs';
import path from 'path';
import { promisify } from 'util';
import { Logger, SignallingServer } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.7';
import { RuntimeStatusPublisher, SignallingRuntimeStatusController } from './runtime-status';
import {
    normalizeInstanceAgentDesiredStateSnapshot,
    readInstanceAgentDesiredStateSnapshot,
    type InstanceAgentDesiredStateSnapshot
} from './instance-agent-state';
import {
    clearInstanceAgentRecycleMarkerSnapshot,
    resolveInstanceAgentRecycleMarkerPath,
    writeInstanceAgentRecycleMarkerSnapshot
} from './instance-agent-recycle-state';

const execFileAsync = promisify(execFile);

const DEFAULT_IDLE_GRACE_MS = 5 * 60_000;
const DEFAULT_FIRST_VIEWER_GRACE_MS = 5 * 60_000;
const DEFAULT_FIRST_VIEWER_DELAY_MS = 0;
const DEFAULT_STOP_RETRY_MS = 60_000;
const DEFAULT_IDLE_STATUS_HEARTBEAT_MS = 60_000;
const DEFAULT_RESET_GRACE_MS = 15_000;
const DEFAULT_MAINTENANCE_REFRESH_MS = 60_000;
const DEFAULT_DESIRED_STATE_REFRESH_MS = 5_000;
const DEFAULT_RECYCLE_TERMINATE_DELAY_MS = 2_000;
const DEFAULT_RECYCLE_READY_TIMEOUT_SECONDS = 120;
const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_METADATA_BASE_URL = 'http://169.254.169.254/latest/meta-data';
const DEFAULT_MAINTENANCE_TAG_KEY = 'ScaleWorldMaintenanceMode';

export interface ViewerIdleOptions {
    enabled?: boolean;
    graceMs?: number;
    firstViewerGraceMs?: number;
    firstViewerDelayMs?: number;
    stopRetryMs?: number;
    idleStatusHeartbeatMs?: number;
    resetGraceMs?: number;
    maintenanceRefreshMs?: number;
    maintenanceTagKey?: string;
    desiredStatePath?: string;
    desiredStateRefreshMs?: number;
    awsCliPath?: string;
    dryRun?: boolean;
    logger?: (message: string) => void;
    runtimeStatusPublisher?: RuntimeStatusPublisher | null;
    runtimeStatusController?: SignallingRuntimeStatusController | null;
}

async function readCurrentInstanceIdentity(): Promise<{ instanceId: string; region: string }> {
    const token = await readImdsToken();
    const [instanceId, region] = await Promise.all([
        readImdsValue('instance-id', token),
        readImdsValue('placement/region', token)
    ]);
    return {
        instanceId: instanceId.trim(),
        region: region.trim()
    };
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
    const { instanceId, region } = await readCurrentInstanceIdentity();

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

async function readCurrentMaintenanceMode(
    awsCliPath: string,
    maintenanceTagKey: string
): Promise<string | null> {
    const { instanceId, region } = await readCurrentInstanceIdentity();
    const args = [
        'ec2',
        'describe-tags',
        '--region',
        region,
        '--filters',
        `Name=resource-id,Values=${instanceId}`,
        `Name=key,Values=${maintenanceTagKey}`,
        '--query',
        'Tags[0].Value',
        '--output',
        'text'
    ];
    const { stdout } = await execFileAsync(awsCliPath, args, { windowsHide: true });
    const normalized = stdout.trim();
    if (
        normalized.length === 0 ||
        normalized.toLowerCase() === 'none' ||
        normalized.toLowerCase() === 'null'
    ) {
        return null;
    }

    return normalized;
}

function mapPendingReason(reason: string): string {
    switch (reason) {
        case 'grace-after-last-viewer':
            return 'grace_after_last_viewer';
        case 'retry-after-failure':
            return 'retry_after_stop_failure';
        case 'no-viewer-ever-connected':
            return 'waiting_for_first_viewer_timeout';
        default:
            return reason.replace(/[^a-z0-9]+/gi, '_').toLowerCase();
    }
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
    const resetGraceMs = parseNonNegativeInteger(
        options.resetGraceMs ?? process.env.VIEWER_IDLE_RESET_GRACE_MS,
        DEFAULT_RESET_GRACE_MS,
        'VIEWER_IDLE_RESET_GRACE_MS',
        log
    );
    const maintenanceRefreshMs = parseNonNegativeInteger(
        options.maintenanceRefreshMs ?? process.env.VIEWER_IDLE_MAINTENANCE_REFRESH_MS,
        DEFAULT_MAINTENANCE_REFRESH_MS,
        'VIEWER_IDLE_MAINTENANCE_REFRESH_MS',
        log
    );
    const desiredStateRefreshMs = parseNonNegativeInteger(
        options.desiredStateRefreshMs ?? process.env.VIEWER_IDLE_DESIRED_STATE_REFRESH_MS,
        DEFAULT_DESIRED_STATE_REFRESH_MS,
        'VIEWER_IDLE_DESIRED_STATE_REFRESH_MS',
        log
    );
    const dryRun = parseBoolean(options.dryRun ?? process.env.VIEWER_IDLE_STOP_DRY_RUN ?? false, false);
    const awsCliPath = String(options.awsCliPath ?? process.env.VIEWER_IDLE_AWS_CLI_PATH ?? 'aws');
    const maintenanceTagKey = String(
        options.maintenanceTagKey ??
            process.env.VIEWER_IDLE_MAINTENANCE_TAG_KEY ??
            DEFAULT_MAINTENANCE_TAG_KEY
    ).trim();
    const desiredStatePath = String(
        options.desiredStatePath ?? process.env.VIEWER_IDLE_DESIRED_STATE_PATH ?? ''
    ).trim();
    const runtimeStatusPublisher = options.runtimeStatusPublisher ?? null;
    const runtimeStatusController = options.runtimeStatusController ?? null;
    const recycleMarkerPath = resolveInstanceAgentRecycleMarkerPath(desiredStatePath);
    const recycleHelperScriptPath = path.resolve(
        __dirname,
        '..',
        'platform_scripts',
        'powershell',
        'invoke_stack_recycle.ps1'
    );
    const recycleRepoRoot = path.resolve(__dirname, '..');
    const powershellPath =
        process.platform === 'win32' && process.env.WINDIR
            ? path.join(process.env.WINDIR, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
            : 'powershell';

    let zeroViewersTimer: NodeJS.Timeout | null = null;
    let firstViewerTimer: NodeJS.Timeout | null = null;
    let transientStatusHeartbeatTimer: NodeJS.Timeout | null = null;
    let reconnectGraceTimer: NodeJS.Timeout | null = null;
    let resetTimer: NodeJS.Timeout | null = null;
    let stopInFlight = false;
    let hasSeenViewer = server.playerRegistry.count() > 0;
    let currentMaintenanceMode: string | null = null;
    let maintenanceStateInitialized = false;
    let maintenanceRefreshInFlight = false;
    let lastMaintenanceReadFailure: string | null = null;
    let desiredStateRefreshTimer: NodeJS.Timeout | null = null;
    let currentDesiredState: InstanceAgentDesiredStateSnapshot =
        desiredStatePath.length > 0
            ? readInstanceAgentDesiredStateSnapshot(desiredStatePath, log)
            : normalizeInstanceAgentDesiredStateSnapshot(undefined);
    let pendingImmediateRecycleToken: string | null = null;
    let resetInFlight = false;

    if (server.playerRegistry.count() === 0 && currentDesiredState.recycleRequestedToken) {
        pendingImmediateRecycleToken = currentDesiredState.recycleRequestedToken;
        hasSeenViewer = true;
        log(
            `[idle-stop] Recycle request token ${currentDesiredState.recycleRequestedToken} was loaded on startup. Forcing post-session recycle before reuse.`
        );
    }

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
    const clearTransientStatusHeartbeat = (): void => {
        if (!transientStatusHeartbeatTimer) return;
        clearInterval(transientStatusHeartbeatTimer);
        transientStatusHeartbeatTimer = null;
    };
    const clearReconnectGraceTimer = (): void => {
        if (!reconnectGraceTimer) return;
        clearTimeout(reconnectGraceTimer);
        reconnectGraceTimer = null;
    };
    const clearResetTimer = (): void => {
        if (!resetTimer) return;
        clearTimeout(resetTimer);
        resetTimer = null;
    };
    const clearDesiredStateRefreshTimer = (): void => {
        if (!desiredStateRefreshTimer) return;
        clearInterval(desiredStateRefreshTimer);
        desiredStateRefreshTimer = null;
    };
    const startTransientStatusHeartbeat = (status: string, reason: string): void => {
        clearTransientStatusHeartbeat();
        if (idleStatusHeartbeatMs <= 0 || !runtimeStatusPublisher) {
            return;
        }
        transientStatusHeartbeatTimer = setInterval(() => {
            publishStatus(status, reason, { heartbeatOnly: true });
        }, idleStatusHeartbeatMs);
    };
    const isMaintenanceActive = (): boolean => (currentMaintenanceMode?.trim().length ?? 0) > 0;
    const canHoldWarmReadyWithoutShutdown = (): boolean =>
        currentDesiredState.warmHoldEnabled &&
        !currentDesiredState.drainEnabled &&
        !currentDesiredState.shutdownRequested;
    const hasPendingImmediateRecycle = (): boolean =>
        pendingImmediateRecycleToken !== null &&
        pendingImmediateRecycleToken === currentDesiredState.recycleRequestedToken;
    const isWarmHoldActive = (): boolean => canHoldWarmReadyWithoutShutdown() && !hasSeenViewer;
    const shouldResetIntoWarmReady = (): boolean => canHoldWarmReadyWithoutShutdown() && hasSeenViewer;
    const clearAllIdleStopTimers = (): void => {
        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();
        clearReconnectGraceTimer();
        clearResetTimer();
    };
    const ensureFirstViewerWindow = (): void => {
        if (!maintenanceStateInitialized || isMaintenanceActive() || isWarmHoldActive()) {
            clearFirstViewerTimer();
            return;
        }

        if (hasSeenViewer || server.playerRegistry.count() > 0 || firstViewerGraceMs <= 0) {
            clearFirstViewerTimer();
            return;
        }

        if (firstViewerTimer) {
            return;
        }

        firstViewerTimer = setTimeout(() => {
            firstViewerTimer = null;
            if (
                hasSeenViewer ||
                server.playerRegistry.count() > 0 ||
                isMaintenanceActive() ||
                isWarmHoldActive()
            ) {
                return;
            }
            void requestStop('no-viewer-ever-connected');
        }, firstViewerDelayMs + firstViewerGraceMs);

        log(
            `[idle-stop] First-viewer window active (delay=${firstViewerDelayMs} ms, grace=${firstViewerGraceMs} ms).`
        );
    };
    const refreshMaintenanceMode = async (): Promise<void> => {
        if (maintenanceRefreshInFlight || maintenanceTagKey.length === 0) {
            return;
        }

        maintenanceRefreshInFlight = true;
        try {
            const nextMaintenanceMode = await readCurrentMaintenanceMode(awsCliPath, maintenanceTagKey);
            maintenanceStateInitialized = true;
            if (nextMaintenanceMode !== currentMaintenanceMode) {
                currentMaintenanceMode = nextMaintenanceMode;
                if (currentMaintenanceMode) {
                    log(
                        `[idle-stop] Maintenance mode '${currentMaintenanceMode}' detected. Suspending idle-stop timers.`
                    );
                    clearAllIdleStopTimers();
                } else {
                    log('[idle-stop] Maintenance mode cleared. Re-evaluating idle-stop timers.');
                    if (!resetInFlight && server.playerRegistry.count() === 0 && shouldResetIntoWarmReady()) {
                        scheduleResetAfterLastViewer(graceMs);
                    } else {
                        ensureFirstViewerWindow();
                    }
                }
            } else if (!currentMaintenanceMode) {
                if (!resetInFlight && server.playerRegistry.count() === 0 && shouldResetIntoWarmReady()) {
                    scheduleResetAfterLastViewer(graceMs);
                } else {
                    ensureFirstViewerWindow();
                }
            }

            lastMaintenanceReadFailure = null;
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            if (message !== lastMaintenanceReadFailure) {
                log(`[idle-stop] Failed to read maintenance mode: ${message}`);
                lastMaintenanceReadFailure = message;
            }
        } finally {
            maintenanceRefreshInFlight = false;
        }
    };
    const refreshDesiredState = (): void => {
        if (desiredStatePath.length === 0) {
            return;
        }

        const nextDesiredState = readInstanceAgentDesiredStateSnapshot(desiredStatePath, log);
        const recycleRequestedTokenChanged =
            nextDesiredState.recycleRequestedToken !== currentDesiredState.recycleRequestedToken;
        const changed =
            nextDesiredState.warmHoldEnabled !== currentDesiredState.warmHoldEnabled ||
            nextDesiredState.drainEnabled !== currentDesiredState.drainEnabled ||
            nextDesiredState.shutdownRequested !== currentDesiredState.shutdownRequested ||
            recycleRequestedTokenChanged ||
            nextDesiredState.policyVersion !== currentDesiredState.policyVersion ||
            nextDesiredState.message !== currentDesiredState.message;
        currentDesiredState = nextDesiredState;

        if (!changed) {
            return;
        }

        if (recycleRequestedTokenChanged && currentDesiredState.recycleRequestedToken) {
            pendingImmediateRecycleToken = currentDesiredState.recycleRequestedToken;
            log(
                `[idle-stop] Immediate recycle requested by desired state token ${currentDesiredState.recycleRequestedToken}.`
            );
        }

        log(
            `[idle-stop] Desired state updated: warmHold=${currentDesiredState.warmHoldEnabled}, drain=${currentDesiredState.drainEnabled}, shutdown=${currentDesiredState.shutdownRequested}, recycleRequested=${currentDesiredState.recycleRequestedToken ? 'true' : 'false'}, policy=${currentDesiredState.policyVersion}.`
        );

        if (isWarmHoldActive()) {
            clearAllIdleStopTimers();
            runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
            return;
        }

        if (reconnectGraceTimer && !shouldResetIntoWarmReady()) {
            clearReconnectGraceTimer();
            if (!maintenanceStateInitialized || isMaintenanceActive() || server.playerRegistry.count() > 0) {
                return;
            }

            if (currentDesiredState.shutdownRequested) {
                void requestStop('agent_shutdown_requested');
                return;
            }

            if (canHoldWarmReadyWithoutShutdown()) {
                runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            scheduleStop('grace-after-last-viewer', 0);
            return;
        }

        if (resetTimer && !shouldResetIntoWarmReady()) {
            clearResetTimer();
            if (!maintenanceStateInitialized || isMaintenanceActive() || server.playerRegistry.count() > 0) {
                return;
            }

            if (currentDesiredState.shutdownRequested) {
                void requestStop('agent_shutdown_requested');
                return;
            }

            if (canHoldWarmReadyWithoutShutdown()) {
                runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            scheduleStop('grace-after-last-viewer', 0);
            return;
        }

        if (
            hasPendingImmediateRecycle() &&
            server.playerRegistry.count() === 0 &&
            maintenanceStateInitialized &&
            !isMaintenanceActive() &&
            shouldResetIntoWarmReady()
        ) {
            startResetWindow(true);
            return;
        }

        if (
            server.playerRegistry.count() === 0 &&
            maintenanceStateInitialized &&
            !isMaintenanceActive() &&
            shouldResetIntoWarmReady()
        ) {
            if (!resetInFlight) {
                scheduleResetAfterLastViewer(graceMs);
            }
            return;
        }

        ensureFirstViewerWindow();
        if (currentDesiredState.shutdownRequested && server.playerRegistry.count() === 0) {
            void requestStop('agent_shutdown_requested');
        }
    };

    const scheduleStop = (reason: string, delayMs: number): void => {
        if (!maintenanceStateInitialized || isMaintenanceActive()) {
            return;
        }

        clearReconnectGraceTimer();
        if (!hasSeenViewer && isWarmHoldActive()) {
            clearAllIdleStopTimers();
            return;
        }

        clearZeroTimer();
        const mappedPendingReason = mapPendingReason(reason);
        publishStatus('idle_shutdown_pending', mappedPendingReason);
        startTransientStatusHeartbeat('idle_shutdown_pending', mappedPendingReason);
        zeroViewersTimer = setTimeout(() => {
            void requestStop(reason);
        }, delayMs);
        log(
            `[idle-stop] Scheduled stop in ${delayMs} ms (reason=${reason}, pendingReason=${mappedPendingReason}).`
        );
    };

    const scheduleResetAfterLastViewer = (delayMs: number): void => {
        if (!maintenanceStateInitialized || isMaintenanceActive()) {
            return;
        }

        if (resetInFlight) {
            return;
        }

        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();

        if (!shouldResetIntoWarmReady()) {
            return;
        }

        if (hasPendingImmediateRecycle()) {
            startResetWindow(true);
            return;
        }

        publishStatus('reconnect_grace', 'waiting_for_viewer_reconnect');
        startTransientStatusHeartbeat('reconnect_grace', 'waiting_for_viewer_reconnect');

        if (delayMs <= 0) {
            startResetWindow();
            return;
        }

        if (reconnectGraceTimer) {
            return;
        }

        reconnectGraceTimer = setTimeout(() => {
            reconnectGraceTimer = null;

            if (!maintenanceStateInitialized || isMaintenanceActive()) {
                return;
            }

            if (server.playerRegistry.count() > 0) {
                runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            if (currentDesiredState.shutdownRequested) {
                void requestStop('agent_shutdown_requested');
                return;
            }

            if (!shouldResetIntoWarmReady()) {
                if (canHoldWarmReadyWithoutShutdown()) {
                    runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
                    return;
                }

                scheduleStop('grace-after-last-viewer', 0);
                return;
            }

            startResetWindow();
        }, delayMs);

        log(`[idle-stop] Viewer reconnect window active for ${delayMs} ms before warm recycle.`);
    };

    const scheduleRetryIfStillIdle = (): void => {
        if (
            stopRetryMs <= 0 ||
            server.playerRegistry.count() > 0 ||
            !maintenanceStateInitialized ||
            isMaintenanceActive()
        ) {
            return;
        }

        publishStatus('idle_shutdown_pending', 'retry_after_stop_failure');
        scheduleStop('retry-after-failure', stopRetryMs);
    };

    const restoreAfterReset = (): void => {
        resetInFlight = false;
        clearReconnectGraceTimer();
        clearResetTimer();
        if (server.playerRegistry.count() > 0 || !maintenanceStateInitialized || isMaintenanceActive()) {
            runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
            return;
        }

        hasSeenViewer = false;
        if (currentDesiredState.shutdownRequested) {
            void requestStop('agent_shutdown_requested');
            return;
        }

        if (!canHoldWarmReadyWithoutShutdown()) {
            scheduleStop('grace-after-last-viewer', 0);
            return;
        }

        runtimeStatusController?.restoreDerivedStatus();
    };

    const requestStackRecycle = (): void => {
        if (!maintenanceStateInitialized || isMaintenanceActive() || server.playerRegistry.count() > 0) {
            runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
            return;
        }

        if (!shouldResetIntoWarmReady()) {
            if (canHoldWarmReadyWithoutShutdown()) {
                runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
                return;
            }

            if (currentDesiredState.shutdownRequested) {
                void requestStop('agent_shutdown_requested');
                return;
            }

            scheduleStop('grace-after-last-viewer', 0);
            return;
        }

        try {
            pendingImmediateRecycleToken = null;
            if (!fs.existsSync(recycleHelperScriptPath)) {
                throw new Error(`Recycle helper script '${recycleHelperScriptPath}' was not found.`);
            }
            const recycleMarker = writeInstanceAgentRecycleMarkerSnapshot(
                recycleMarkerPath,
                {
                    requestedAtUtc: new Date().toISOString(),
                    reason: 'post_session_cleanup',
                    recycleId: randomUUID(),
                    sourcePid: process.pid
                },
                log
            );
            const recycleProcess = spawn(
                powershellPath,
                [
                    '-NoProfile',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-File',
                    recycleHelperScriptPath,
                    '-RepoRoot',
                    recycleRepoRoot,
                    '-RecycleMarkerPath',
                    recycleMarkerPath,
                    '-WaitBeforeTerminateMilliseconds',
                    String(DEFAULT_RECYCLE_TERMINATE_DELAY_MS),
                    '-WaitForWilburTimeoutSeconds',
                    String(DEFAULT_RECYCLE_READY_TIMEOUT_SECONDS)
                ],
                {
                    detached: true,
                    stdio: 'ignore',
                    windowsHide: true
                }
            );
            recycleProcess.on('error', (error) => {
                clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
                log(
                    `[idle-stop] Recycle helper process failed to start: ${error.message}. Falling back to logical warm restore.`
                );
                restoreAfterReset();
            });
            recycleProcess.unref();
            log(
                `[idle-stop] Requested full stack recycle (${recycleMarker.recycleId ?? 'unknown'}) via '${recycleHelperScriptPath}'.`
            );
        } catch (error) {
            clearInstanceAgentRecycleMarkerSnapshot(recycleMarkerPath, log);
            const message = error instanceof Error ? error.message : String(error);
            log(
                `[idle-stop] Failed to request full stack recycle: ${message}. Falling back to logical warm restore.`
            );
            restoreAfterReset();
        }
    };

    const startResetWindow = (skipGrace: boolean = false): void => {
        if (!maintenanceStateInitialized || isMaintenanceActive() || server.playerRegistry.count() > 0) {
            return;
        }

        clearReconnectGraceTimer();
        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();

        if (!shouldResetIntoWarmReady()) {
            return;
        }

        resetInFlight = true;
        pendingImmediateRecycleToken = null;
        publishStatus('resetting', 'post_session_cleanup');
        if (skipGrace || resetGraceMs <= 0) {
            requestStackRecycle();
            return;
        }

        if (resetTimer) {
            return;
        }

        resetTimer = setTimeout(() => {
            resetTimer = null;
            requestStackRecycle();
        }, resetGraceMs);

        log(
            skipGrace
                ? '[idle-stop] Entered immediate warm reset path with no reconnect grace.'
                : `[idle-stop] Entered warm reset window for ${resetGraceMs} ms before full stack recycle.`
        );
    };

    const requestStop = async (reason: string): Promise<void> => {
        if (stopInFlight) return;
        resetInFlight = false;
        clearTransientStatusHeartbeat();
        clearReconnectGraceTimer();
        clearResetTimer();
        if (!maintenanceStateInitialized || isMaintenanceActive()) {
            return;
        }

        if (server.playerRegistry.count() > 0) {
            log('[idle-stop] Stop request aborted because viewers are connected.');
            runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
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
        resetInFlight = false;
        clearZeroTimer();
        clearFirstViewerTimer();
        clearTransientStatusHeartbeat();
        clearReconnectGraceTimer();
        clearResetTimer();
        runtimeStatusController?.restoreDerivedStatus({ preserveStatusAtUtc: true });
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
        if (effectiveCount !== 0) {
            return;
        }

        if (maintenanceStateInitialized && !isMaintenanceActive() && shouldResetIntoWarmReady()) {
            if (hasPendingImmediateRecycle()) {
                startResetWindow(true);
                return;
            }

            scheduleResetAfterLastViewer(graceMs);
            return;
        }

        scheduleStop('grace-after-last-viewer', graceMs);
    };

    server.playerRegistry.on('added', onViewerAdded);
    server.playerRegistry.on('removed', onViewerRemoved);
    log('[idle-stop] Wired to player registry events.');

    if (maintenanceRefreshMs > 0 && maintenanceTagKey.length > 0) {
        void refreshMaintenanceMode();
        setInterval(() => {
            void refreshMaintenanceMode();
        }, maintenanceRefreshMs);
    } else {
        maintenanceStateInitialized = true;
        ensureFirstViewerWindow();
    }

    if (desiredStatePath.length > 0 && desiredStateRefreshMs > 0) {
        refreshDesiredState();
        clearDesiredStateRefreshTimer();
        desiredStateRefreshTimer = setInterval(() => {
            refreshDesiredState();
        }, desiredStateRefreshMs);
    }
}
